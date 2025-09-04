// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Escrow, IEscrow } from "./Escrow.sol";

import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";
import { ISimplePaymentProcessor } from "./interface/ISimplePaymentProcessor.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { TaskQueueLib } from "src/libraries/TaskQueueLib.sol";

/**
 * @title SimplePaymentProcessor
 * @notice Lightweight payment processor for single-invoice flows with native or ERC20 payments.
 * @dev Implements basic escrow release, refund, and dispute resolution. Compliant with ISimplePaymentProcessor.
 */
contract SimplePaymentProcessor is ISimplePaymentProcessor {
    using SafeCastLib for uint256;
    using TaskQueueLib for TaskQueueLib.Heap;
    using { TaskQueueLib.getId } for uint256;

    TaskQueueLib.Heap private heap;

    IPaymentProcessorStorage public immutable ppStorage;

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

    address public forwarder;

    /**
     * @notice Stores the `Invoice` structs, keyed by a unique invoice ID.
     * @dev The key is an unsigned integer representing the invoice ID, and the value
     *      is an `Invoice` struct that contains detailed information such as the
     *      creator, payer, status, amount, escrow address, timestamps, etc.
     */
    mapping(uint216 orderId => Invoice invoice) private invoiceData;

    mapping(uint216 => uint256) private index;

    /**
     * @notice Initializes the payment processor with owner, fee settings, and default hold period.
     * @dev Sets the fee receiver address, the fee rate (in basis points), and the default escrow hold time.
     * @param paymentProcessorStorageAddress The address of the shared payment processor storage contract.
     * @param minimumInvoicePrice The new minimum default invoice value to set (in wei).
     */
    constructor(address paymentProcessorStorageAddress, uint256 minimumInvoicePrice) {
        ppStorage = IPaymentProcessorStorage(paymentProcessorStorageAddress);
        setMinimumInvoiceValue(minimumInvoicePrice);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function createInvoice(uint256 invoicePrice) external returns (uint216) {
        if (invoicePrice < minimumInvoiceValue) revert ValueIsTooLow();
        Invoice memory invoice;
        invoice.seller = msg.sender;
        invoice.createdAt = (block.timestamp).toUint32();
        invoice.price = invoicePrice;
        invoice.status = CREATED;
        invoice.invoiceId = ppStorage.updateInvoiceId(1);

        uint216 orderId = _computeOrderId(msg.sender, invoice.invoiceId);

        if (invoiceData[orderId].status != 0) revert InvoiceAlreadyExists();

        invoiceData[orderId] = invoice;

        emit InvoiceCreated(orderId, invoice);

        return orderId;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function makeInvoicePayment(uint216 orderId) external payable returns (address) {
        Invoice memory invoice = invoiceData[orderId];

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

        address escrow = address(new Escrow{ value: msg.value }(orderId, invoice.seller, msg.sender, address(this)));

        invoice.escrow = escrow;
        invoice.buyer = msg.sender;
        invoice.status = PAID;
        invoice.amountPaid = msg.value;
        invoice.paymentTime = (block.timestamp).toUint32();
        invoiceData[orderId] = invoice;

        emit InvoicePaid(orderId, msg.sender, msg.value);
        return escrow;
    }

    function _validateInvoiceStateForPaymentDecision(Invoice memory invoice) internal view {
        if (block.timestamp > invoice.paymentTime + ACCEPTANCE_WINDOW) {
            revert AcceptanceWindowExceeded();
        }
        if (invoice.seller != msg.sender) {
            revert NotAuthorized();
        }
        if (invoice.status != PAID) {
            revert InvoiceNotPaid();
        }
    }

    /// @inheritdoc ISimplePaymentProcessor
    function cancelInvoice(uint216 orderId) external {
        Invoice memory invoice = invoiceData[orderId];
        if (invoice.seller != msg.sender) {
            revert NotAuthorized();
        }
        if (invoice.status != CREATED) {
            revert InvalidInvoiceState(invoice.status);
        }
        invoiceData[orderId].status = CANCELLED;
        emit InvoiceCanceled(orderId);
    }

    function _release(uint216 orderId) internal returns (uint256) {
        Invoice memory invoice = invoiceData[orderId];

        if (invoice.status == RELEASED || invoice.status != ACCEPTED || block.timestamp < invoice.releaseAt) {
            return TaskQueueLib.NOT_ELIGIBLE_FOR_RELEASE;
        }

        uint256 feeValue = calculateFee(invoice.price);

        invoiceData[orderId].status = RELEASED;

        uint256 pos = index[orderId];
        if (pos == 0 || pos > heap.data.length) return TaskQueueLib.ERROR;

        heap.removeAt(pos - 1, index);

        IEscrow(invoice.escrow).withdraw(address(0), invoice.seller, invoice.price - feeValue);
        emit InvoiceReleased(orderId);
        return TaskQueueLib.SUCCESSFUL;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function releaseInvoice(uint216 orderId) public {
        Invoice memory invoice = invoiceData[orderId];

        if (invoice.status == RELEASED) revert InvoiceHasAlreadyBeenReleased();
        if (invoice.status != ACCEPTED) {
            revert InvalidInvoiceState(invoice.status);
        }
        if (invoice.seller != msg.sender) {
            revert NotAuthorized();
        }
        if (block.timestamp < invoice.releaseAt) {
            revert HoldPeriodHasNotBeenExceeded();
        }

        uint256 feeValue = calculateFee(invoice.price);

        invoiceData[orderId].status = RELEASED;

        heap.removeAt(index[orderId] - 1, index);

        IEscrow(invoice.escrow).withdraw(address(0), msg.sender, invoice.price - feeValue);
        emit InvoiceReleased(orderId);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function refundBuyer(uint216 orderId) external {
        Invoice memory invoice = invoiceData[orderId];
        if (invoice.status != PAID || block.timestamp < invoice.paymentTime + ACCEPTANCE_WINDOW) {
            revert InvoiceNotEligibleForRefund();
        }

        invoiceData[orderId].status = REFUNDED;
        IEscrow(invoice.escrow).withdraw(address(0), invoice.buyer, invoice.price);

        emit InvoiceRefunded(orderId);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function acceptPayment(uint216 orderId) external {
        Invoice memory invoice = invoiceData[orderId];
        _validateInvoiceStateForPaymentDecision(invoice);
        invoice.status = ACCEPTED;
        uint256 holdPeriod = invoice.releaseAt == 0 ? ppStorage.getDefaultHoldPeriod() : invoice.releaseAt;
        invoice.releaseAt = (holdPeriod + block.timestamp).toUint32();
        invoiceData[orderId] = invoice;

        heap.insert(orderId, uint40(invoice.releaseAt), index);
        uint256 feeValue = calculateFee(invoice.price);
        IEscrow(invoice.escrow).withdraw(address(0), ppStorage.getFeeReceiver(), feeValue);

        emit InvoiceAccepted(orderId);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function rejectPayment(uint216 orderId) public {
        Invoice memory invoice = invoiceData[orderId];
        _validateInvoiceStateForPaymentDecision(invoice);
        invoiceData[orderId].status = REJECTED;
        IEscrow(invoice.escrow).withdraw(address(0), invoice.buyer, invoice.price);

        emit InvoiceRejected(orderId);
    }

    function checkUpkeep(bytes calldata) external view returns (bool, bytes memory) {
        return (heap.due(), bytes(""));
    }

    function performUpkeep(bytes calldata) external {
        if (msg.sender != PaymentProcessorStorage(address(ppStorage)).owner() && msg.sender != forwarder) {
            revert NotAuthorized();
        }

        uint256 gasThresold = ppStorage.getGasThresold();

        heap.processDueTask(index, _release, gasThresold);
    }

    /**
     * @notice Computes a unique order ID for an invoice using buyer, invoice ID, timestamp, and contract address.
     * @dev This function ensures the order ID is non-deterministic, even for repeated inputs.
     * @param buyer The address of the buyer.
     * @param invoiceId The invoice identifier provided during creation.
     * @return The keccak256 hash representing the unique order ID.
     */
    function _computeOrderId(address buyer, uint256 invoiceId) internal view returns (uint216) {
        return (uint256(keccak256(abi.encode(address(this), buyer, invoiceId))) & ((1 << 216) - 1)).toUint216();
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setInvoiceReleaseTime(uint216 orderId, uint32 holdPeriod) external {
        if (msg.sender != address(ppStorage)) revert NotAuthorized();
        Invoice memory invoice = invoiceData[orderId];

        if (invoice.status < ACCEPTED) {
            revert InvoiceHasNotBeenAccepted();
        }

        uint256 newReleaseTime = block.timestamp + holdPeriod;

        if (newReleaseTime > type(uint32).max) revert ReleaseTimeOverflow();

        invoiceData[orderId].releaseAt = newReleaseTime.toUint32();
        heap.reschedule(orderId, uint40(newReleaseTime), index);

        emit UpdateHoldPeriod(orderId, newReleaseTime);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function calculateFee(uint256 amount) public view returns (uint256) {
        return (amount * ppStorage.getFeeRate()) / BASIS_POINTS;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setMinimumInvoiceValue(uint256 newMinimumInvoiceValue) public {
        if (msg.sender != PaymentProcessorStorage(address(ppStorage)).owner()) revert NotAuthorized();
        minimumInvoiceValue = newMinimumInvoiceValue;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setForwarderAddress(address forwarderAddress) external {
        if (msg.sender != address(ppStorage)) revert NotAuthorized();
        forwarder = forwarderAddress;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getForwarder() external view returns (address) {
        return forwarder;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getNextInvoiceId() external view returns (uint216) {
        return ppStorage.getNextInvoiceId();
    }

    /// @inheritdoc ISimplePaymentProcessor
    function totalInvoiceCreated() external view returns (uint216) {
        return ppStorage.totalInvoiceCreated();
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getInvoiceData(uint216 orderId) external view returns (Invoice memory) {
        return invoiceData[orderId];
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getMinimumInvoiceValue() external view returns (uint256) {
        return minimumInvoiceValue;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getItems() external view returns (uint216[] memory) {
        return heap.getItems();
    }
}
