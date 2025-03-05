// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "solady/auth/Ownable.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { IEscrow, Escrow } from "./Escrow.sol";
import { Invoice, IPaymentProcessorV1 } from "./interface/IPaymentProcessorV1.sol";
import {
    CREATED,
    ACCEPTED,
    REJECTED,
    PAID,
    CANCELLED,
    REFUNDED,
    RELEASED,
    VALID_PERIOD,
    ACCEPTANCE_WINDOW
} from "./utils/Constants.sol";

contract PaymentProcessorV1 is Ownable, IPaymentProcessorV1 {
    using SafeCastLib for uint256;

    /// @notice The fee amount charged for using this service, denominated in wei.
    uint256 private fee;

    /// @notice The address that receives the fees collected for creating invoices.
    address private feeReceiver;

    /// @notice The current invoice ID counter used to assign unique IDs to newly created invoices.s
    uint256 private currentInvoiceId;

    /// @notice The default hold period for funds in escrow, measured in seconds.
    uint256 private defaultHoldPeriod;

    /**
     * @notice Stores the `Invoice` structs, keyed by a unique invoice ID.
     * @dev The key is an unsigned integer representing the invoice ID, and the value
     *      is an `Invoice` struct that contains detailed information such as the
     *      creator, payer, status, amount, escrow address, timestamps, etc.
     */
    mapping(uint256 invoiceId => Invoice invoice) private invoiceData;

    constructor(address _receiversAddress, uint256 _fee, uint256 _defaultHoldPeriod) {
        currentInvoiceId = 1;
        _initializeOwner(msg.sender);
        setFee(_fee);
        setDefaultHoldPeriod(_defaultHoldPeriod);
        setFeeReceiversAddress(_receiversAddress);
    }

    /// inheritdoc IPaymentProcessor
    function createInvoice(uint256 _invoicePrice) external returns (uint256) {
        if (_invoicePrice <= fee) {
            revert InvoicePriceIsTooLow();
        }

        uint256 thisInvoiceId = currentInvoiceId;
        Invoice memory invoice = invoiceData[thisInvoiceId];
        invoice.creator = msg.sender;
        invoice.createdAt = (block.timestamp).toUint32();
        invoice.price = _invoicePrice;
        invoice.status = CREATED;
        invoiceData[thisInvoiceId] = invoice;
        currentInvoiceId++;

        emit InvoiceCreated(thisInvoiceId, msg.sender, _invoicePrice);

        return thisInvoiceId;
    }

    /// inheritdoc IPaymentProcessor
    function makeInvoicePayment(uint256 _invoiceId) external payable returns (address) {
        Invoice memory invoice = invoiceData[_invoiceId];
        uint256 bhFee = fee;

        if (invoice.status != CREATED) {
            revert InvalidInvoiceState(invoice.status);
        }

        if (invoice.creator == msg.sender) {
            revert CreatorCannotPayOwnedInvoice();
        }

        if (msg.value > invoice.price) {
            revert ExcessivePayment();
        }

        if (block.timestamp > invoice.createdAt + VALID_PERIOD) {
            revert InvoiceIsNoLongerValid();
        }

        if (msg.value <= bhFee) {
            revert ValueIsTooLow();
        }

        uint256 amountPaid = msg.value - bhFee;

        address escrow = address(
            new Escrow{ value: amountPaid }(_invoiceId, invoice.creator, msg.sender, address(this))
        );

        invoice.escrow = escrow;
        invoice.payer = msg.sender;
        invoice.status = PAID;
        invoice.amountPaid = amountPaid;
        invoice.paymentTime = (block.timestamp).toUint32();
        invoiceData[_invoiceId] = invoice;

        emit InvoicePaid(_invoiceId, msg.sender, msg.value);
        return escrow;
    }

    /// inheritdoc IPaymentProcessor
    function creatorsAction(uint256 _invoiceId, bool _state) external {
        Invoice memory invoice = invoiceData[_invoiceId];
        if (block.timestamp > invoice.paymentTime + ACCEPTANCE_WINDOW) {
            revert AcceptanceWindowExceeded();
        }
        if (invoice.creator != msg.sender) {
            revert Unauthorized();
        }
        if (invoice.status != PAID) {
            revert InvoiceNotPaid();
        }
        _state ? _acceptInvoice(_invoiceId) : _rejectInvoice(_invoiceId, invoice);
    }

    /// inheritdoc IPaymentProcessor
    function cancelInvoice(uint256 _invoiceId) external {
        Invoice memory invoice = invoiceData[_invoiceId];
        if (invoice.creator != msg.sender) {
            revert Unauthorized();
        }
        if (invoice.status != CREATED) {
            revert InvalidInvoiceState(invoice.status);
        }
        invoiceData[_invoiceId].status = CANCELLED;
        emit InvoiceCanceled(_invoiceId);
    }

    /// inheritdoc IPaymentProcessor
    function releaseInvoice(uint256 _invoiceId) external {
        Invoice memory invoice = invoiceData[_invoiceId];

        if (invoice.status == RELEASED) revert InvoiceHasAlreadyBeenReleased();
        if (invoice.status != ACCEPTED) revert InvalidInvoiceState(invoice.status);
        if (invoice.creator != msg.sender) {
            revert Unauthorized();
        }
        if (block.timestamp < invoice.holdPeriod) {
            revert HoldPeriodHasNotBeenExceeded();
        }

        invoiceData[_invoiceId].status = RELEASED;
        IEscrow(invoice.escrow).withdrawToCreator(msg.sender);
        emit InvoiceReleased(_invoiceId);
    }

    /// inheritdoc IPaymentProcessor
    function refundPayerAfterWindow(uint256 _invoiceId) external {
        Invoice memory invoice = invoiceData[_invoiceId];
        if (invoice.status != PAID || block.timestamp < invoice.paymentTime + ACCEPTANCE_WINDOW) {
            revert InvoiceNotEligibleForRefund();
        }

        invoiceData[_invoiceId].status = REFUNDED;
        IEscrow(invoice.escrow).refundToPayer(invoice.payer);
        emit InvoiceRefunded(_invoiceId);
    }

    /**
     * @notice Marks the specified invoice as accepted.
     * @dev This function updates the status of the invoice to `ACCEPTED` and emits the `InvoiceAccepted` event.
     *      It is expected that the creator is approving the payment for the invoice.
     * @param _invoiceId The ID of the invoice being accepted.
     */
    function _acceptInvoice(uint256 _invoiceId) internal {
        Invoice memory invoice = invoiceData[_invoiceId];
        invoice.status = ACCEPTED;
        uint256 holdPeriod = invoice.holdPeriod == 0 ? defaultHoldPeriod : invoice.holdPeriod;
        invoice.holdPeriod = (holdPeriod + block.timestamp).toUint32();
        invoiceData[_invoiceId] = invoice;
        emit InvoiceAccepted(_invoiceId);
    }

    /**
     * @notice Marks the specified invoice as rejected and refunds the payer.
     * @dev This function updates the invoice status to `REJECTED`, refunds the payer via the escrow contract,
     *      and emits the `InvoiceRejected` event.
     * @param _invoiceId The ID of the invoice being rejected.
     * @param invoice The `Invoice` struct containing details of the invoice to be rejected, including the escrow
     * address and payer.
     */
    function _rejectInvoice(uint256 _invoiceId, Invoice memory invoice) internal {
        invoiceData[_invoiceId].status = REJECTED;
        IEscrow(invoice.escrow).refundToPayer(invoice.payer);
        emit InvoiceRejected(_invoiceId);
    }

    /// inheritdoc IPaymentProcessor
    function setInvoiceHoldPeriod(uint256 _invoiceId, uint32 _holdPeriod) external onlyOwner {
        Invoice memory invoice = invoiceData[_invoiceId];

        uint32 holdPeriod = (_holdPeriod + block.timestamp).toUint32();

        if (invoice.status < CREATED) {
            revert InvoiceDoesNotExist();
        }

        if (holdPeriod < invoice.holdPeriod) {
            revert HoldPeriodShouldBeGreaterThanDefault();
        }
        invoiceData[_invoiceId].holdPeriod = holdPeriod;
        emit UpdateHoldPeriod(_invoiceId, holdPeriod);
    }

    /// inheritdoc IPaymentProcessor
    function withdrawFees() external {
        if (owner() != msg.sender && msg.sender != feeReceiver) {
            revert Unauthorized();
        }
        uint256 balance = address(this).balance;
        (bool success,) = feeReceiver.call{ value: balance }("");
        if (!success) {
            revert TransferFailed();
        }
    }

    /// inheritdoc IPaymentProcessor
    function setFeeReceiversAddress(address _newFeeReceiver) public onlyOwner {
        if (_newFeeReceiver == address(0)) revert ZeroAddressIsNotAllowed();
        feeReceiver = _newFeeReceiver;
    }

    /// inheritdoc IPaymentProcessor
    function setDefaultHoldPeriod(uint256 _newDefaultHoldPeriod) public onlyOwner {
        if (_newDefaultHoldPeriod == 0) revert HoldPeriodCanNotBeZero();
        defaultHoldPeriod = _newDefaultHoldPeriod;
    }

    /// inheritdoc IPaymentProcessor
    function setFee(uint256 _newFee) public onlyOwner {
        if (_newFee == 0) revert FeeValueCanNotBeZero();
        fee = _newFee;
    }

    /// inheritdoc IPaymentProcessor
    function getFee() external view returns (uint256) {
        return fee;
    }

    /// inheritdoc IPaymentProcessor
    function getFeeReceiver() external view returns (address) {
        return feeReceiver;
    }

    /// inheritdoc IPaymentProcessor
    function getNextInvoiceId() external view returns (uint256) {
        // change total invoice created
        return currentInvoiceId;
    }

    /// inheritdoc IPaymentProcessor
    function totalInvoiceCreated() external view returns (uint256) {
        return currentInvoiceId - 1;
    }

    /// inheritdoc IPaymentProcessor
    function getDefaultHoldPeriod() external view returns (uint256) {
        return defaultHoldPeriod;
    }

    /// inheritdoc IPaymentProcessor
    function getInvoiceData(uint256 _invoiceId) external view returns (Invoice memory) {
        return invoiceData[_invoiceId];
    }
}
