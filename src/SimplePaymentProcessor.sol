// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Escrow, IEscrow } from "./Escrow.sol";

import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";
import { AutomationCompatibleInterface } from "./interface/AutomationCompatibleInterface.sol";
import { ISimplePaymentProcessor } from "./interface/ISimplePaymentProcessor.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { TaskQueueLib } from "src/libraries/TaskQueueLib.sol";
import { INotes } from "./interface/INotes.sol";

/**
 * @title SimplePaymentProcessor
 * @notice Lightweight payment processor for single-invoice flows with native or ERC20 payments.
 * @dev Implements basic escrow release, refund, and dispute resolution. Compliant with ISimplePaymentProcessor.
 */
contract SimplePaymentProcessor is ISimplePaymentProcessor, AutomationCompatibleInterface {
    using SafeCastLib for uint256;
    using TaskQueueLib for TaskQueueLib.Heap;

    /// @notice Notes contract used for encrypted invoice notes.
    INotes private notes;

    /// @notice Status code representing that a payment or transaction has been created.
    uint8 public constant CREATED = 1;

    /// @notice Status code representing that a payment or transaction has been accepted.
    uint8 public constant ACCEPTED = CREATED + 1;

    /// @notice Status code representing that a payment has been completed.
    uint8 public constant PAID = ACCEPTED + 1;

    /// @notice Status code representing that a payment or transaction has been rejected.
    uint8 public constant REJECTED = PAID + 1;

    /// @notice Status code representing that a payment or transaction has been cancelled.
    uint8 public constant CANCELLED = REJECTED + 1;

    /// @notice Status code representing that a payment has been refunded to the payer.
    uint8 public constant REFUNDED = CANCELLED + 1;

    /// @notice Status code representing that a payment has been successfully released to the payee.
    uint8 public constant RELEASED = REFUNDED + 1;

    /// @notice Basis points denominator used for percentage calculations (1% = 100).
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Default time window during which a created invoice remains valid for payment.
    uint256 public constant DEFAULT_PAYMENT_VALIDITY_PERIOD = 7 days;

    /// @notice Default decision period for the seller after an invoice is paid.
    uint256 public constant DEFAULT_SELLER_DECISION_WINDOW = 6 hours;

    /// @notice Internal min-heap used to efficiently manage scheduled invoice tasks by release time.
    TaskQueueLib.Heap private heap;

    /// @notice Reference to the external Payment Processor storage contract.
    IPaymentProcessorStorage public immutable ppStorage;

    /// @notice The minimum allowed value (in wei) required to create a new invoice.
    uint256 private minimumInvoiceValue;

    /// @notice The valid period for a transaction, after which it is considered expired.
    uint256 public validPeriod;

    /// @notice The window of time allowed for accepting a transaction after creation.
    uint256 public decisionWindow;

    /// @notice Address of the forwarder contract responsible for calling performUpkeep.
    address private forwarder;

    /**
     * @notice Stores the `Invoice` structs, keyed by a unique invoice ID.
     * @dev The key is an unsigned integer representing the invoice ID, and the value
     *      is an `Invoice` struct that contains detailed information such as the
     *      creator, payer, status, amount, escrow address, timestamps, etc.
     */
    mapping(uint216 orderId => Invoice invoice) private invoiceData;

    /**
     *  @notice Maps task or invoice ID to its 1-based index position in the heap.
     * @dev A value of 0 means the task is not present in the heap
     */
    mapping(uint216 orderId => uint256 key) private index;

    /**
     * @notice Restricts access to the payment processor owner or storage contract.
     * @dev Reverts with NotAuthorized if the caller is not permitted.
     */
    modifier onlyAuthorized() {
        _isAuthorized();
        _;
    }

    /**
     * @notice Initializes the payment processor with owner, fee settings, and default hold period.
     * @dev Sets the fee receiver address, the fee rate (in basis points), and the default escrow hold time.
     * @param paymentProcessorStorageAddress The address of the shared payment processor storage contract.
     * @param minimumInvoicePrice The new minimum default invoice value to set (in wei).
     * @param notesAddress Address of the notes contract used for invoice notes.
     */
    constructor(address paymentProcessorStorageAddress, uint256 minimumInvoicePrice, address notesAddress) {
        ppStorage = IPaymentProcessorStorage(paymentProcessorStorageAddress);
        notes = INotes(notesAddress);
        validPeriod = DEFAULT_PAYMENT_VALIDITY_PERIOD;
        decisionWindow = DEFAULT_SELLER_DECISION_WINDOW;
        setMinimumInvoiceValue(minimumInvoicePrice);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function createInvoice(uint256 invoicePrice, bytes memory storageRef, bool share) external returns (uint216) {
        if (invoicePrice < minimumInvoiceValue) revert ValueIsTooLow();
        Invoice memory invoice;
        invoice.seller = msg.sender;
        invoice.createdAt = (block.timestamp).toUint32();
        invoice.price = invoicePrice;
        invoice.status = CREATED;
        invoice.invoiceId = ppStorage.updateInvoiceId(1);
        invoice.invalidateAt = (block.timestamp + validPeriod).toUint40();

        uint216 orderId = _computeOrderId(msg.sender, invoice.invoiceId);

        if (invoiceData[orderId].status != 0) revert InvoiceAlreadyExists();

        invoiceData[orderId] = invoice;

        if (storageRef.length != 0) notes.createNote(orderId, msg.sender, storageRef, share);

        emit InvoiceCreated(orderId, invoice.invalidateAt, invoice);

        return orderId;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function pay(uint216 orderId, bytes memory storageRef, bool share) external payable returns (address) {
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

        if (block.timestamp > invoice.invalidateAt) {
            revert InvoiceIsNoLongerValid();
        }

        address escrow = address(new Escrow{ value: msg.value }(orderId, invoice.seller, msg.sender, address(this)));
        uint40 expiresAt = (block.timestamp + decisionWindow).toUint40();

        invoice.escrow = escrow;
        invoice.buyer = msg.sender;
        invoice.status = PAID;
        invoice.amountPaid = msg.value;
        invoice.paidAt = (block.timestamp).toUint32();
        invoice.expiresAt = expiresAt;
        invoiceData[orderId] = invoice;

        heap.insert(orderId, expiresAt, index);
        if (storageRef.length != 0) notes.createNote(orderId, msg.sender, storageRef, share);

        emit InvoicePaid(orderId, msg.sender, msg.value, expiresAt);
        return escrow;
    }

    /**
     * @notice Validates that the caller can accept or reject a payment.
     * @dev Ensures caller is the seller and invoice is within the decision window.
     * @param invoice The invoice data to validate.
     */
    function _validateInvoiceStateForPaymentDecision(Invoice memory invoice) internal view {
        if (invoice.seller != msg.sender) {
            revert NotAuthorized();
        }

        if (invoice.status != PAID) {
            revert InvoiceNotPaid();
        }

        if (block.timestamp > invoice.expiresAt) {
            revert AcceptanceWindowExceeded();
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
    function refundBuyer(uint216 orderId) public {
        Invoice memory invoice = invoiceData[orderId];
        if (invoice.status != PAID || block.timestamp < invoice.expiresAt) {
            revert InvoiceNotEligibleForRefund();
        }

        uint256 pos = index[orderId];

        if (pos != 0 && pos <= heap.data.length) {
            heap.removeAt(pos - 1, index);
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
        uint256 holdSeconds = invoice.releaseAt == 0 ? ppStorage.getDefaultHoldPeriod() : invoice.releaseAt;
        invoice.releaseAt = (holdSeconds + block.timestamp).toUint32();
        invoiceData[orderId] = invoice;

        heap.reschedule(orderId, uint40(invoice.releaseAt), index);
        uint256 feeValue = calculateFee(invoice.price);
        IEscrow(invoice.escrow).withdraw(address(0), ppStorage.getFeeReceiver(), feeValue);

        emit InvoiceAccepted(orderId);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function rejectPayment(uint216 orderId) public {
        Invoice memory invoice = invoiceData[orderId];
        _validateInvoiceStateForPaymentDecision(invoice);

        invoiceData[orderId].status = REJECTED;
        heap.removeAt(index[orderId] - 1, index);

        IEscrow(invoice.escrow).withdraw(address(0), invoice.buyer, invoice.price);

        emit InvoiceRejected(orderId);
    }

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes calldata) external view returns (bool, bytes memory) {
        return (heap.due(), bytes(""));
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata) external {
        if (msg.sender != PaymentProcessorStorage(address(ppStorage)).owner() && msg.sender != forwarder) {
            revert NotAuthorized();
        }

        uint256 gasThresold = ppStorage.getGasThreshold();

        heap.processDueTask(_release, gasThresold);
    }

    /**
     * @notice Attempts to release the specified invoice if it is eligible.
     * @dev This function performs all the checks required to determine whether
     *      the invoice can be released, updates the invoice status, removes it
     *      from the scheduling heap, and triggers the escrow payout.
     * @param orderId The ID of the invoice to release.
     * @return status A status code from TaskQueueLib indicating the outcome:
     *         - SUCCESSFUL (3): Invoice was released and removed from heap.
     *         - NOT_ELIGIBLE_FOR_RELEASE (1): Invoice not accepted or not yet due.
     *         - ERROR (2): Invalid index or heap inconsistency.
     */
    function _release(uint216 orderId) internal returns (uint256) {
        Invoice memory invoice = invoiceData[orderId];

        if (invoice.status == PAID) {
            if (block.timestamp < invoice.expiresAt) {
                return TaskQueueLib.NOT_ELIGIBLE_FOR_RELEASE;
            }
            refundBuyer(orderId);
            return TaskQueueLib.SUCCESSFUL;
        }

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

    /**
     *  @notice Internal function to validate whether the caller is authorized.
     *  @dev Reverts if the caller is not the contract owner or the PaymentProcessorStorage contract itself.
     * Can only be called by either the owner of the PaymentProcessor contract or the storage contract address.
     */
    function _isAuthorized() internal view {
        if (msg.sender != PaymentProcessorStorage(address(ppStorage)).owner() && msg.sender != address(ppStorage)) {
            revert NotAuthorized();
        }
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
        heap.reschedule(orderId, newReleaseTime.toUint40(), index);

        emit UpdateHoldPeriod(orderId, newReleaseTime);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function calculateFee(uint256 amount) public view returns (uint256) {
        return (amount * ppStorage.getFeeRate()) / BASIS_POINTS;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setMinimumInvoiceValue(uint256 newMinimumInvoiceValue) public onlyAuthorized {
        minimumInvoiceValue = newMinimumInvoiceValue;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setForwarderAddress(address forwarderAddress) external onlyAuthorized {
        forwarder = forwarderAddress;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setValidPeriod(uint256 newValidPeriod) external onlyAuthorized {
        if (msg.sender != PaymentProcessorStorage(address(ppStorage)).owner()) {
            revert NotAuthorized();
        }
        validPeriod = newValidPeriod;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setDecisionWindow(uint256 newDecisionWindow) external onlyAuthorized {
        decisionWindow = newDecisionWindow;
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
