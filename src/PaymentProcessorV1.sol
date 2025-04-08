// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "solady/auth/Ownable.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { IEscrow, Escrow } from "./Escrow.sol";
import { IPaymentProcessorV1 } from "./interface/IPaymentProcessorV1.sol";

contract PaymentProcessorV1 is IPaymentProcessorV1, Ownable {
    using SafeCastLib for uint256;

    /// @notice The address that receives the fees collected for creating invoices.
    address private feeReceiver;

    /// @notice Fee rate applied to transactions, expressed in basis points (1% = 100).
    uint256 private feeRate;

    /// @notice The current invoice ID counter used to assign unique IDs to newly created invoices.s
    uint256 private currentInvoiceId;

    /// @notice The default hold period for funds in escrow, measured in seconds.
    uint256 private defaultHoldPeriod;

    /// @notice Status code representing that a payment or transaction has been created.
    uint32 public constant CREATED = 1;

    /// @notice Status code representing that a payment or transaction has been accepted.
    uint32 public constant ACCEPTED = CREATED + 1;

    /// @notice Status code representing that a payment has been completed.
    uint32 public constant PAID = ACCEPTED + 1;

    /// @notice Status code representing that a payment or transaction has been rejected.
    uint32 public constant REJECTED = PAID + 1;

    /// @notice Status code representing that a payment or transaction has been cancelled.
    uint32 public constant CANCELLED = REJECTED + 1;

    /// @notice Status code representing that a payment has been refunded to the payer.
    uint32 public constant REFUNDED = CANCELLED + 1;

    /// @notice Status code representing that a payment has been successfully released to the payee.
    uint32 public constant RELEASED = REFUNDED + 1;

    /// @notice The valid period for a transaction, after which it is considered expired.
    uint256 public constant VALID_PERIOD = 180 days;

    /// @notice The window of time allowed for accepting a transaction after creation.
    uint256 public constant ACCEPTANCE_WINDOW = 3 days;

    /// @notice Basis points denominator used for percentage calculations (1% = 100).
    uint256 public constant BASIS_POINTS = 10_000;

    /**
     * @notice Stores the `Invoice` structs, keyed by a unique invoice ID.
     * @dev The key is an unsigned integer representing the invoice ID, and the value
     *      is an `Invoice` struct that contains detailed information such as the
     *      creator, payer, status, amount, escrow address, timestamps, etc.
     */
    mapping(uint256 invoiceId => Invoice invoice) private invoiceData;

    /**
     * @notice Initializes the payment processor with owner, fee settings, and default hold period.
     * @dev Sets the fee receiver address, the fee rate (in basis points), and the default escrow hold time.
     * @param _feeReceiversAddress The address that will receive collected fees.
     * @param _feeRate The initial fee rate to apply on invoice payments (in basis points, 1% = 100).
     * @param _defaultHoldPeriod The default period (in seconds) to hold funds in escrow after acceptance.
     */
    constructor(address _feeReceiversAddress, uint256 _feeRate, uint256 _defaultHoldPeriod) {
        currentInvoiceId = 1;
        _initializeOwner(msg.sender);
        setFeeRate(_feeRate);
        setDefaultHoldPeriod(_defaultHoldPeriod);
        setFeeReceiversAddress(_feeReceiversAddress);
    }

    /// @inheritdoc IPaymentProcessorV1
    function createInvoice(uint256 _invoicePrice) external returns (uint256) {
        if (_invoicePrice < 1 ether) revert ValueIsTooLow();
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

    /// @inheritdoc IPaymentProcessorV1
    function makeInvoicePayment(uint256 _invoiceId) external payable returns (address) {
        Invoice memory invoice = invoiceData[_invoiceId];

        if (invoice.status != CREATED) {
            revert InvalidInvoiceState(invoice.status);
        }

        if (invoice.creator == msg.sender) {
            revert CreatorCannotPayOwnedInvoice();
        }

        if (msg.value != invoice.price) {
            revert IncorrectPaymentAmount(msg.value, invoice.price);
        }

        if (block.timestamp > invoice.createdAt + VALID_PERIOD) {
            revert InvoiceIsNoLongerValid();
        }

        address escrow = address(
            new Escrow{ value: msg.value }(_invoiceId, invoice.creator, msg.sender, address(this))
        );

        invoice.escrow = escrow;
        invoice.payer = msg.sender;
        invoice.status = PAID;
        invoice.amountPaid = msg.value;
        invoice.paymentTime = (block.timestamp).toUint32();
        invoiceData[_invoiceId] = invoice;

        emit InvoicePaid(_invoiceId, msg.sender, msg.value);
        return escrow;
    }

    /// @inheritdoc IPaymentProcessorV1
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

    /// @inheritdoc IPaymentProcessorV1
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

    /// @inheritdoc IPaymentProcessorV1
    function releaseInvoice(uint256 _invoiceId) external {
        Invoice memory invoice = invoiceData[_invoiceId];

        if (invoice.status == RELEASED) revert InvoiceHasAlreadyBeenReleased();
        if (invoice.status != ACCEPTED) {
            revert InvalidInvoiceState(invoice.status);
        }
        if (invoice.creator != msg.sender) {
            revert Unauthorized();
        }
        if (block.timestamp < invoice.releaseAt) {
            revert HoldPeriodHasNotBeenExceeded();
        }

        invoiceData[_invoiceId].status = RELEASED;
        IEscrow(invoice.escrow).withdrawToCreator(msg.sender);
        emit InvoiceReleased(_invoiceId);
    }

    /// @inheritdoc IPaymentProcessorV1
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
        uint256 holdPeriod = invoice.releaseAt == 0 ? defaultHoldPeriod : invoice.releaseAt;
        invoice.releaseAt = (holdPeriod + block.timestamp).toUint32();
        invoiceData[_invoiceId] = invoice;

        uint256 feeValue = calculateFee(invoice.price);
        IEscrow(invoice.escrow).payFee(feeReceiver, _invoiceId, feeValue);

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

    /// @inheritdoc IPaymentProcessorV1
    function setInvoiceReleaseTime(uint256 _invoiceId, uint32 _holdPeriod) external onlyOwner {
        Invoice memory invoice = invoiceData[_invoiceId];

        uint256 newReleaseTime = invoice.releaseAt + _holdPeriod;

        if (invoice.status < ACCEPTED) {
            revert InvoiceHasNotBeenAccepted();
        }

        if (newReleaseTime > type(uint32).max) revert ReleaseTimeOverflow();

        invoiceData[_invoiceId].releaseAt = newReleaseTime.toUint32();

        emit UpdateHoldPeriod(_invoiceId, newReleaseTime);
    }

    /// @inheritdoc IPaymentProcessorV1
    function calculateFee(uint256 _amount) public view returns (uint256) {
        return (_amount * feeRate) / BASIS_POINTS;
    }

    /// @inheritdoc IPaymentProcessorV1
    function setFeeReceiversAddress(address _newFeeReceiver) public onlyOwner {
        if (_newFeeReceiver == address(0)) revert ZeroAddressIsNotAllowed();
        feeReceiver = _newFeeReceiver;
    }

    /// @inheritdoc IPaymentProcessorV1
    function setDefaultHoldPeriod(uint256 _newDefaultHoldPeriod) public onlyOwner {
        if (_newDefaultHoldPeriod == 0) revert HoldPeriodCanNotBeZero();
        defaultHoldPeriod = _newDefaultHoldPeriod;
    }

    /// @inheritdoc IPaymentProcessorV1
    function setFeeRate(uint256 _feeRate) public onlyOwner {
        if (_feeRate == 0) revert FeeValueCanNotBeZero();
        if (_feeRate > BASIS_POINTS) revert FeeTooHigh();
        feeRate = _feeRate;
    }

    /// @inheritdoc IPaymentProcessorV1
    function getFeeRate() external view returns (uint256) {
        return feeRate;
    }

    /// @inheritdoc IPaymentProcessorV1
    function getFeeReceiver() external view returns (address) {
        return feeReceiver;
    }

    /// @inheritdoc IPaymentProcessorV1
    function getNextInvoiceId() external view returns (uint256) {
        return currentInvoiceId;
    }

    /// @inheritdoc IPaymentProcessorV1
    function totalInvoiceCreated() external view returns (uint256) {
        return currentInvoiceId - 1;
    }

    /// @inheritdoc IPaymentProcessorV1
    function getDefaultHoldPeriod() external view returns (uint256) {
        return defaultHoldPeriod;
    }

    /// @inheritdoc IPaymentProcessorV1
    function getInvoiceData(uint256 _invoiceId) external view returns (Invoice memory) {
        return invoiceData[_invoiceId];
    }
}
