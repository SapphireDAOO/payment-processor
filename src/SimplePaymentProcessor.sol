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
 * @notice Lightweight payment processor for single-invoice flows with native payments.
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
    uint256 public constant BASIS_POINTS = 10_000;

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
    mapping(uint216 invoiceId => Invoice invoice) private invoiceData;

    /**
     *  @notice Maps task or invoice ID to its 1-based index position in the heap.
     * @dev A value of 0 means the task is not present in the heap
     */
    mapping(uint216 invoiceId => uint256 key) private index;

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
        invoice.invoiceNonce = ppStorage.updateInvoiceNonce(1);
        invoice.invalidateAt = (block.timestamp + validPeriod).toUint40();

        uint216 invoiceId = _computeInvoiceId(msg.sender, invoice.invoiceNonce);

        if (invoiceData[invoiceId].status != 0) revert InvoiceAlreadyExists();

        invoiceData[invoiceId] = invoice;

        if (storageRef.length != 0) notes.createNote(invoiceId, msg.sender, storageRef, share);

        emit InvoiceCreated(invoiceId, invoice.invalidateAt, invoice);

        return invoiceId;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function pay(uint216 invoiceId, bytes memory storageRef, bool share) external payable returns (address) {
        Invoice memory invoice = invoiceData[invoiceId];

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

        address escrow = address(new Escrow{ value: msg.value }(invoiceId, invoice.seller, msg.sender, address(this)));
        uint40 expiresAt = (block.timestamp + decisionWindow).toUint40();

        invoice.escrow = escrow;
        invoice.buyer = msg.sender;
        invoice.status = PAID;
        invoice.balance = msg.value;
        invoice.paidAt = (block.timestamp).toUint32();
        invoice.expiresAt = expiresAt;
        invoiceData[invoiceId] = invoice;

        heap.insert(invoiceId, expiresAt, index);
        if (storageRef.length != 0) notes.createNote(invoiceId, msg.sender, storageRef, share);

        emit InvoicePaid(invoiceId, msg.sender, msg.value, expiresAt);
        return escrow;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function acceptPayment(uint216 invoiceId) external {
        Invoice memory invoice = invoiceData[invoiceId];
        _validateInvoiceStateForPaymentDecision(invoice);
        invoice.status = ACCEPTED;

        if (invoice.releaseAt == 0) {
            invoice.releaseAt = (ppStorage.getDefaultHoldPeriod() + block.timestamp).toUint40();
            heap.reschedule(invoiceId, uint40(invoice.releaseAt), index);
        }

        uint256 feeValue = calculateFee(invoice.price);
        invoice.balance -= feeValue;

        invoiceData[invoiceId] = invoice;

        IEscrow(invoice.escrow).withdraw(address(0), ppStorage.getFeeReceiver(), feeValue);

        emit InvoiceAccepted(invoiceId);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function rejectPayment(uint216 invoiceId) public {
        Invoice memory invoice = invoiceData[invoiceId];
        _validateInvoiceStateForPaymentDecision(invoice);

        invoiceData[invoiceId].status = REJECTED;
        heap.removeAt(index[invoiceId] - 1, index);

        IEscrow(invoice.escrow).withdraw(address(0), invoice.buyer, invoice.price);

        emit InvoiceRejected(invoiceId);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function cancelInvoice(uint216 invoiceId) external {
        Invoice memory invoice = invoiceData[invoiceId];
        if (invoice.seller != msg.sender) {
            revert NotAuthorized();
        }
        if (invoice.status != CREATED) {
            revert InvalidInvoiceState(invoice.status);
        }
        invoiceData[invoiceId].status = CANCELLED;
        emit InvoiceCanceled(invoiceId);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function releaseInvoice(uint216 invoiceId) public {
        Invoice memory invoice = invoiceData[invoiceId];

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

        invoiceData[invoiceId].status = RELEASED;
        invoiceData[invoiceId].balance = 0;

        heap.removeAt(index[invoiceId] - 1, index);

        IEscrow(invoice.escrow).withdraw(address(0), msg.sender, invoice.balance);
        emit InvoiceReleased(invoiceId);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function refundBuyer(uint216 invoiceId) public {
        Invoice memory invoice = invoiceData[invoiceId];
        if (invoice.status != PAID || block.timestamp < invoice.expiresAt) {
            revert InvoiceNotEligibleForRefund();
        }

        uint256 pos = index[invoiceId];

        if (pos != 0 && pos <= heap.data.length) {
            heap.removeAt(pos - 1, index);
        }

        invoiceData[invoiceId].status = REFUNDED;
        invoiceData[invoiceId].balance = 0;
        IEscrow(invoice.escrow).withdraw(address(0), invoice.buyer, invoice.price);

        emit InvoiceRefunded(invoiceId);
    }

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes calldata) external view returns (bool, bytes memory) {
        return (heap.due(), bytes(""));
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata) external {
        if (msg.sender != _owner() && msg.sender != forwarder) {
            revert NotAuthorized();
        }

        uint256 gasThresold = ppStorage.getGasThreshold();

        heap.processDueTask(_release, gasThresold);
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

    /**
     * @notice Attempts to release the specified invoice if it is eligible.
     * @dev This function performs all the checks required to determine whether
     *      the invoice can be released, updates the invoice status, removes it
     *      from the scheduling heap, and triggers the escrow payout.
     * @param invoiceId The ID of the invoice to release.
     * @return status A status code from TaskQueueLib indicating the outcome:
     *         - SUCCESSFUL (3): Invoice was released and removed from heap.
     *         - NOT_ELIGIBLE_FOR_RELEASE (1): Invoice not accepted or not yet due.
     *         - ERROR (2): Invalid index or heap inconsistency.
     */
    function _release(uint216 invoiceId) internal returns (uint256) {
        Invoice memory invoice = invoiceData[invoiceId];

        if (invoice.status == PAID) {
            if (block.timestamp < invoice.expiresAt) {
                return TaskQueueLib.NOT_ELIGIBLE_FOR_RELEASE;
            }
            refundBuyer(invoiceId);
            return TaskQueueLib.SUCCESSFUL;
        }

        if (invoice.status == RELEASED || invoice.status != ACCEPTED || block.timestamp < invoice.releaseAt) {
            return TaskQueueLib.NOT_ELIGIBLE_FOR_RELEASE;
        }

        invoiceData[invoiceId].status = RELEASED;
        invoiceData[invoiceId].balance = 0;

        uint256 pos = index[invoiceId];
        if (pos == 0 || pos > heap.data.length) return TaskQueueLib.ERROR;

        heap.removeAt(pos - 1, index);

        IEscrow(invoice.escrow).withdraw(address(0), invoice.seller, invoice.balance);
        emit InvoiceReleased(invoiceId);
        return TaskQueueLib.SUCCESSFUL;
    }

    /**
     * @notice Computes a unique order ID for an invoice using buyer, invoice ID, timestamp, and contract address.
     * @dev This function ensures the order ID is non-deterministic, even for repeated inputs.
     * @param buyer The address of the buyer.
     * @param invoiceNonce The invoice identifier provided during creation.
     * @return The keccak256 hash representing the unique order ID.
     */
    function _computeInvoiceId(address buyer, uint256 invoiceNonce) internal view returns (uint216) {
        return (uint256(keccak256(abi.encode(address(this), buyer, invoiceNonce))) & ((1 << 216) - 1)).toUint216();
    }

    /**
     * @notice Returns the owner of the PaymentProcessorStorage contract.
     * @dev This helper reads the owner directly from the linked PaymentProcessorStorage instance.
     * @return owner The address that currently owns the PaymentProcessorStorage contract.
     */
    function _owner() internal view returns (address) {
        return PaymentProcessorStorage(address(ppStorage)).owner();
    }

    /**
     *  @notice Internal function to validate whether the caller is authorized.
     *  @dev Reverts if the caller is not the contract owner or the PaymentProcessorStorage contract itself.
     * Can only be called by either the owner of the PaymentProcessor contract or the storage contract address.
     */
    function _isAuthorized() internal view {
        if (msg.sender != _owner() && msg.sender != address(ppStorage)) {
            revert NotAuthorized();
        }
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setInvoiceReleaseTime(uint216 invoiceId, uint32 holdPeriod) external {
        if (msg.sender != address(ppStorage)) revert NotAuthorized();
        Invoice memory invoice = invoiceData[invoiceId];

        if (invoice.status < ACCEPTED) {
            revert InvoiceHasNotBeenAccepted();
        }

        uint256 newReleaseTime = block.timestamp + holdPeriod;

        if (newReleaseTime > type(uint32).max) revert ReleaseTimeOverflow();

        invoiceData[invoiceId].releaseAt = newReleaseTime.toUint32();
        heap.reschedule(invoiceId, newReleaseTime.toUint40(), index);

        emit UpdateHoldPeriod(invoiceId, newReleaseTime);
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
        if (msg.sender != _owner()) {
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
    function getNextInvoiceNonce() external view returns (uint216) {
        return ppStorage.getNextInvoiceNonce();
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getInvoiceData(uint216 invoiceId) external view returns (Invoice memory) {
        return invoiceData[invoiceId];
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
