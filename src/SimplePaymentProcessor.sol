// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Escrow, IEscrow } from "./Escrow.sol";

import { IPaymentProcessorStorage } from "./interface/IPaymentProcessorStorage.sol";
import { ISimplePaymentProcessor } from "./interface/ISimplePaymentProcessor.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";

contract SimplePaymentProcessor is ISimplePaymentProcessor, Ownable {
    using SafeCastLib for uint256;

    IPaymentProcessorStorage public immutable ppStorage;

    /// @notice The default hold period for funds in escrow, measured in seconds.
    uint256 private defaultHoldPeriod;

    /// @notice The minimum allowed value (in wei) required to create a new invoice.
    uint256 private minimumInvoiceValue;

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
    uint256 public constant BASIS_POINTS = 10000;

    /**
     * @notice Stores the `Invoice` structs, keyed by a unique invoice ID.
     * @dev The key is an unsigned integer representing the invoice ID, and the value
     *      is an `Invoice` struct that contains detailed information such as the
     *      creator, payer, status, amount, escrow address, timestamps, etc.
     */
    mapping(bytes32 invoiceKey => Invoice invoice) private invoiceData;

    /**
     * @notice Initializes the payment processor with owner, fee settings, and default hold period.
     * @dev Sets the fee receiver address, the fee rate (in basis points), and the default escrow hold time.
     * @param paymentProcessorStorageAddress The address of the shared payment processor storage contract.
     * @param initialDefaultHoldPeriod The default period (in seconds) to hold funds in escrow after acceptance.
     * * @param minimumInvoicePrice The new minimum default invoice value to set (in wei).
     */
    constructor(address paymentProcessorStorageAddress, uint256 initialDefaultHoldPeriod, uint256 minimumInvoicePrice) {
        ppStorage = IPaymentProcessorStorage(paymentProcessorStorageAddress);
        _initializeOwner(msg.sender);
        setDefaultHoldPeriod(initialDefaultHoldPeriod);
        setMinimumInvoiceValue(minimumInvoicePrice);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function createInvoice(uint256 invoicePrice) external returns (bytes32) {
        if (invoicePrice < minimumInvoiceValue) revert ValueIsTooLow();
        Invoice memory invoice;
        invoice.seller = msg.sender;
        invoice.createdAt = (block.timestamp).toUint32();
        invoice.price = invoicePrice;
        invoice.status = CREATED;
        invoice.invoiceId = ppStorage.updateInvoiceId(1);

        bytes32 invoiceKey = _computeInvoiceKey(msg.sender, invoice.invoiceId);

        invoiceData[invoiceKey] = invoice;

        emit InvoiceCreated(invoiceKey, invoice);

        return invoiceKey;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function makeInvoicePayment(bytes32 invoiceKey) external payable returns (address) {
        Invoice memory invoice = invoiceData[invoiceKey];

        if (invoice.status != CREATED) {
            revert InvalidInvoiceState(invoice.status);
        }

        if (invoice.seller == msg.sender) {
            revert SellerCannotPayOwnedInvoice();
        }

        if (msg.value != invoice.price) {
            revert IncorrectPaymentAmount(msg.value, invoice.price);
        }

        if (block.timestamp > invoice.createdAt + VALID_PERIOD) {
            revert InvoiceIsNoLongerValid();
        }

        address escrow = address(new Escrow{ value: msg.value }(invoiceKey, invoice.seller, msg.sender, address(this)));

        invoice.escrow = escrow;
        invoice.buyer = msg.sender;
        invoice.status = PAID;
        invoice.amountPaid = msg.value;
        invoice.paymentTime = (block.timestamp).toUint32();
        invoiceData[invoiceKey] = invoice;

        emit InvoicePaid(invoiceKey, msg.sender, msg.value);
        return escrow;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function sellerAction(bytes32 invoiceKey, bool state) external {
        Invoice memory invoice = invoiceData[invoiceKey];
        if (block.timestamp > invoice.paymentTime + ACCEPTANCE_WINDOW) {
            revert AcceptanceWindowExceeded();
        }
        if (invoice.seller != msg.sender) {
            revert Unauthorized();
        }
        if (invoice.status != PAID) {
            revert InvoiceNotPaid();
        }
        state ? _acceptInvoice(invoiceKey) : _rejectInvoice(invoiceKey, invoice);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function cancelInvoice(bytes32 invoiceKey) external {
        Invoice memory invoice = invoiceData[invoiceKey];
        if (invoice.seller != msg.sender) {
            revert Unauthorized();
        }
        if (invoice.status != CREATED) {
            revert InvalidInvoiceState(invoice.status);
        }
        invoiceData[invoiceKey].status = CANCELLED;
        emit InvoiceCanceled(invoiceKey);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function releaseInvoice(bytes32 invoiceKey) external {
        Invoice memory invoice = invoiceData[invoiceKey];

        if (invoice.status == RELEASED) revert InvoiceHasAlreadyBeenReleased();
        if (invoice.status != ACCEPTED) {
            revert InvalidInvoiceState(invoice.status);
        }
        if (invoice.seller != msg.sender) {
            revert Unauthorized();
        }
        if (block.timestamp < invoice.releaseAt) {
            revert HoldPeriodHasNotBeenExceeded();
        }

        uint256 feeValue = calculateFee(invoice.price);

        invoiceData[invoiceKey].status = RELEASED;
        IEscrow(invoice.escrow).withdraw(address(0), msg.sender, invoice.price - feeValue);
        emit InvoiceReleased(invoiceKey);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function refundBuyerAfterWindow(bytes32 invoiceKey) external {
        Invoice memory invoice = invoiceData[invoiceKey];
        if (invoice.status != PAID || block.timestamp < invoice.paymentTime + ACCEPTANCE_WINDOW) {
            revert InvoiceNotEligibleForRefund();
        }

        invoiceData[invoiceKey].status = REFUNDED;
        IEscrow(invoice.escrow).withdraw(address(0), invoice.buyer, invoice.price);

        emit InvoiceRefunded(invoiceKey);
    }

    /**
     * @notice Marks the specified invoice as accepted.
     * @dev This function updates the status of the invoice to `ACCEPTED` and emits the `InvoiceAccepted` event.
     *      It is expected that the creator is approving the payment for the invoice.
     * @param invoiceKey The key of the invoice being accepted.
     */
    function _acceptInvoice(bytes32 invoiceKey) internal {
        Invoice memory invoice = invoiceData[invoiceKey];
        invoice.status = ACCEPTED;
        uint256 holdPeriod = invoice.releaseAt == 0 ? defaultHoldPeriod : invoice.releaseAt;
        invoice.releaseAt = (holdPeriod + block.timestamp).toUint32();
        invoiceData[invoiceKey] = invoice;

        uint256 feeValue = calculateFee(invoice.price);
        IEscrow(invoice.escrow).withdraw(address(0), ppStorage.getFeeReceiver(), feeValue);

        emit InvoiceAccepted(invoiceKey);
    }

    /**
     * @notice Marks the specified invoice as rejected and refunds the payer.
     * @dev This function updates the invoice status to `REJECTED`, refunds the payer via the escrow contract,
     *      and emits the `InvoiceRejected` event.
     * @param invoiceKey The key of the invoice being rejected.
     * @param invoice The `Invoice` struct containing details of the invoice to be rejected, including the escrow
     * address and payer.
     */
    function _rejectInvoice(bytes32 invoiceKey, Invoice memory invoice) internal {
        invoiceData[invoiceKey].status = REJECTED;
        IEscrow(invoice.escrow).withdraw(address(0), invoice.buyer, invoice.price);

        emit InvoiceRejected(invoiceKey);
    }

    /**
     * @notice Computes a unique hash for an invoice based on buyer, issuer, and invoice ID.
     * @dev Assumes the invoiceId is uniquely assigned by the contract.
     * @param buyer The address of the invoice buyer.
     * @param invoiceId The unique identifier for the invoice.
     * @return The keccak256 hash representing the invoice ID.
     */
    function _computeInvoiceKey(address buyer, uint256 invoiceId) internal view returns (bytes32) {
        return keccak256(abi.encode(buyer, invoiceId, block.timestamp, address(this)));
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setInvoiceReleaseTime(bytes32 invoiceKey, uint32 holdPeriod) external onlyOwner {
        Invoice memory invoice = invoiceData[invoiceKey];

        uint256 newReleaseTime = invoice.releaseAt + holdPeriod;

        if (invoice.status < ACCEPTED) {
            revert InvoiceHasNotBeenAccepted();
        }

        if (newReleaseTime > type(uint32).max) revert ReleaseTimeOverflow();

        invoiceData[invoiceKey].releaseAt = newReleaseTime.toUint32();

        emit UpdateHoldPeriod(invoiceKey, newReleaseTime);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function calculateFee(uint256 amount) public view returns (uint256) {
        return (amount * ppStorage.getFeeRate()) / BASIS_POINTS;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setDefaultHoldPeriod(uint256 newDefaultHoldPeriod) public onlyOwner {
        if (newDefaultHoldPeriod == 0) revert HoldPeriodCanNotBeZero();
        defaultHoldPeriod = newDefaultHoldPeriod;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setMinimumInvoiceValue(uint256 newMinimumInvoiceValue) public onlyOwner {
        minimumInvoiceValue = newMinimumInvoiceValue;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getNextInvoiceId() external view returns (uint256) {
        return ppStorage.getNextInvoiceId();
    }

    /// @inheritdoc ISimplePaymentProcessor
    function totalInvoiceCreated() external view returns (uint256) {
        return ppStorage.totalInvoiceCreated();
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getDefaultHoldPeriod() external view returns (uint256) {
        return defaultHoldPeriod;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getInvoiceData(bytes32 invoiceKey) external view returns (Invoice memory) {
        return invoiceData[invoiceKey];
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getMinimumInvoiceValue() external view returns (uint256) {
        return minimumInvoiceValue;
    }
}
