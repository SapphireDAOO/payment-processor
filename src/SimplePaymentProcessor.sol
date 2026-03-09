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
 * @dev Implements basic escrow release and refund. Compliant with ISimplePaymentProcessor.
 */
contract SimplePaymentProcessor is ISimplePaymentProcessor, AutomationCompatibleInterface {
    using SafeCastLib for uint256;
    using TaskQueueLib for TaskQueueLib.Heap;

    /// @notice Notes contract used for encrypted invoice notes.
    INotes private immutable notes;

    /// @notice Status code representing that an invoice has been created and is awaiting payment.
    uint8 public constant CREATED = 1;

    /// @notice Status code representing that an invoice has been paid by the buyer.
    uint8 public constant PAID = CREATED + 1;

    /// @notice Status code representing that a payment has been accepted by the seller.
    uint8 public constant ACCEPTED = PAID + 1;

    /// @notice Status code representing that a payment has been rejected by the seller.
    uint8 public constant REJECTED = ACCEPTED + 1;

    /// @notice Status code representing that an invoice has been canceled by the seller.
    uint8 public constant CANCELED = REJECTED + 1;

    /// @notice Status code representing that a payment has been refunded to the payer.
    uint8 public constant REFUNDED = CANCELED + 1;

    /// @notice Status code representing that a payment has been successfully released to the seller.
    uint8 public constant RELEASED = REFUNDED + 1;

    /// @notice Basis points denominator used for percentage calculations (1% = 100).
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Default decision period for the seller after an invoice is paid.
    uint256 public constant DEFAULT_SELLER_DECISION_WINDOW = 6 hours;

    /// @notice Internal min-heap used to efficiently manage scheduled invoice tasks by release time.
    TaskQueueLib.Heap private heap;

    /// @notice Reference to the external Payment Processor storage contract.
    IPaymentProcessorStorage public immutable ppStorage;

    /// @notice The minimum allowed value (in wei) required to create a new invoice.
    uint256 private minimumInvoiceValue;

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
    mapping(uint216 invoiceId => Invoice data) private invoices;

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
     * @param _paymentProcessorStorageAddress The address of the shared payment processor storage contract.
     * @param _minimumInvoicePrice The new minimum default invoice value to set (in wei).
     * @param _notesAddress Address of the notes contract used for invoice notes.
     */
    constructor(address _paymentProcessorStorageAddress, uint256 _minimumInvoicePrice, address _notesAddress) {
        ppStorage = IPaymentProcessorStorage(_paymentProcessorStorageAddress);
        notes = INotes(_notesAddress);
        decisionWindow = DEFAULT_SELLER_DECISION_WINDOW;
        setMinimumInvoiceValue(_minimumInvoicePrice);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function createInvoice(uint256 _price, bytes memory _storageRef, bool _share) public returns (uint216 invoiceId) {
        if (_price < minimumInvoiceValue) revert ValueIsTooLow();
        Invoice memory i;
        i.seller = msg.sender;
        i.createdAt = (block.timestamp).toUint40();
        i.price = _price;
        i.state = CREATED;
        i.invoiceNonce = ppStorage.updateInvoiceNonce(1);
        i.invalidateAt = (block.timestamp + ppStorage.getPaymentValidityDuration()).toUint40();

        invoiceId = _computeInvoiceId(msg.sender, i.invoiceNonce);

        if (invoices[invoiceId].state != 0) revert InvoiceAlreadyExists();

        invoices[invoiceId] = i;

        if (_storageRef.length != 0) notes.createNote(invoiceId, msg.sender, _storageRef, _share);

        emit InvoiceCreated(invoiceId, i);

        return invoiceId;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function pay(uint216 _invoiceId, bytes memory _storageRef, bool _share)
        public
        payable
        returns (address escrowAddress)
    {
        return _payWithValue(_invoiceId, _storageRef, _share, msg.value);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function acceptPayment(uint216 _invoiceId) public {
        Invoice memory i = invoices[_invoiceId];
        _validateInvoiceStateForPaymentDecision(i);
        i.state = ACCEPTED;

        if (i.releaseAt == 0) {
            i.releaseAt = (ppStorage.getDefaultHoldPeriod() + block.timestamp).toUint40();
            heap.reschedule(_invoiceId, i.releaseAt, index);
        }

        uint256 feeValue = calculateFee(i.price);
        i.balance -= feeValue;

        invoices[_invoiceId] = i;

        IEscrow(i.escrow).withdraw(address(0), ppStorage.getFeeReceiver(), feeValue);

        emit InvoiceAccepted(_invoiceId);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function rejectPayment(uint216 _invoiceId) public {
        Invoice memory i = invoices[_invoiceId];
        _validateInvoiceStateForPaymentDecision(i);

        invoices[_invoiceId].state = REJECTED;
        invoices[_invoiceId].balance = 0;
        heap.removeAt(index[_invoiceId] - 1, index);

        IEscrow(i.escrow).withdraw(address(0), i.buyer, i.price);

        emit InvoiceRejected(_invoiceId);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function cancelInvoice(uint216 _invoiceId) external {
        Invoice memory i = invoices[_invoiceId];
        if (i.seller != msg.sender) {
            revert NotAuthorized();
        }
        if (i.state != CREATED) {
            revert InvalidInvoiceState(i.state);
        }
        invoices[_invoiceId].state = CANCELED;
        emit InvoiceCanceled(_invoiceId);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function release(uint216 _invoiceId) public {
        Invoice memory i = invoices[_invoiceId];

        if (i.state == RELEASED) revert InvalidInvoiceState(i.state);
        if (i.state != ACCEPTED) {
            revert InvalidInvoiceState(i.state);
        }
        if (i.seller != msg.sender) {
            revert NotAuthorized();
        }
        if (block.timestamp < i.releaseAt) {
            revert HoldPeriodHasNotBeenExceeded();
        }

        invoices[_invoiceId].state = RELEASED;
        invoices[_invoiceId].balance = 0;

        heap.removeAt(index[_invoiceId] - 1, index);

        IEscrow(i.escrow).withdraw(address(0), msg.sender, i.balance);
        emit InvoiceReleased(_invoiceId);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function refundBuyer(uint216 _invoiceId) public {
        Invoice memory i = invoices[_invoiceId];
        if (i.state != PAID || block.timestamp < i.expiresAt) {
            revert InvoiceNotEligibleForRefund();
        }

        uint256 pos = index[_invoiceId];

        if (pos == 0 || pos > heap.data.length) revert InvalidHeapPosition();

        heap.removeAt(pos - 1, index);

        invoices[_invoiceId].state = REFUNDED;
        invoices[_invoiceId].balance = 0;
        IEscrow(i.escrow).withdraw(address(0), i.buyer, i.price);

        emit InvoiceRefunded(_invoiceId);
    }

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        upkeepNeeded = heap.due();
        performData = bytes("");
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata) external {
        if (msg.sender != _owner() && msg.sender != forwarder) {
            revert NotAuthorized();
        }

        uint256 gasThreshold = ppStorage.getGasThreshold();

        heap.processDueTask(_release, gasThreshold);
    }

    /**
     * @notice Internal payment helper that allows specifying the ETH value.
     * @param _invoiceId The ID of the invoice being paid.
     * @param _storageRef A bytes-encoded reference to the caller's notes.
     * @param _share Whether the note is shared with non-authors.
     * @param _value The amount of ETH to use for payment.
     * @return escrowAddress The address of the escrow contract created.
     */
    function _payWithValue(uint216 _invoiceId, bytes memory _storageRef, bool _share, uint256 _value)
        internal
        returns (address escrowAddress)
    {
        Invoice memory i = invoices[_invoiceId];

        if (i.state != CREATED) {
            revert InvalidInvoiceState(i.state);
        }

        if (i.seller == msg.sender) {
            revert SellerCannotPayOwnedInvoice();
        }

        if (_value != i.price) {
            revert IncorrectPaymentAmount(_value, i.price);
        }

        if (block.timestamp > i.invalidateAt) {
            revert InvoiceIsNoLongerValid();
        }

        escrowAddress = address(new Escrow{ value: _value }(_invoiceId, address(this)));
        uint40 expiresAt = (block.timestamp + decisionWindow).toUint40();

        i.escrow = escrowAddress;
        i.buyer = msg.sender;
        i.state = PAID;
        i.balance = _value;
        i.paidAt = (block.timestamp).toUint40();
        i.expiresAt = expiresAt;
        invoices[_invoiceId] = i;

        heap.insert(_invoiceId, expiresAt, index);
        if (_storageRef.length != 0) notes.createNote(_invoiceId, msg.sender, _storageRef, _share);

        emit InvoicePaid(_invoiceId, msg.sender, _value, expiresAt);
        return escrowAddress;
    }

    /**
     * @notice Validates that the caller can accept or reject a payment.
     * @dev Ensures caller is the seller and invoice is within the decision window.
     * @param _i The invoice data to validate.
     */
    function _validateInvoiceStateForPaymentDecision(Invoice memory _i) internal view {
        if (_i.seller != msg.sender) {
            revert NotAuthorized();
        }

        if (_i.state != PAID) {
            revert InvalidInvoiceState(_i.state);
        }

        if (block.timestamp > _i.expiresAt) {
            revert AcceptanceWindowExceeded();
        }
    }

    /**
     * @notice Attempts to automatically release or refund the specified invoice when its heap task is due.
     * @dev Called by `performUpkeep` via `processDueTask`. Returns a status code rather than reverting.
     *      - If state is PAID (decision window elapsed): calls `refundBuyer` and returns SUCCESSFUL.
     *      - If state is ACCEPTED (hold period elapsed): transitions to RELEASED, removes from heap,
     *        and transfers funds to the seller.
     *      - If state is anything else: returns NOT_ELIGIBLE_FOR_RELEASE.
     *      - If heap position is invalid: returns ERROR.
     * @param _invoiceId The ID of the invoice to release.
     * @return status `SUCCESSFUL`, `NOT_ELIGIBLE_FOR_RELEASE`, or `ERROR`.
     */
    function _release(uint216 _invoiceId) internal returns (uint256 status) {
        Invoice memory i = invoices[_invoiceId];

        if (i.state == PAID) {
            refundBuyer(_invoiceId);
            return TaskQueueLib.SUCCESSFUL;
        }

        if (i.state != ACCEPTED) return TaskQueueLib.NOT_ELIGIBLE_FOR_RELEASE;

        uint256 pos = index[_invoiceId];
        if (pos == 0 || pos > heap.data.length) return TaskQueueLib.ERROR;

        invoices[_invoiceId].state = RELEASED;
        invoices[_invoiceId].balance = 0;

        heap.removeAt(pos - 1, index);

        IEscrow(i.escrow).withdraw(address(0), i.seller, i.balance);
        emit InvoiceReleased(_invoiceId);
        return TaskQueueLib.SUCCESSFUL;
    }

    /**
     * @notice Computes a unique invoice ID from the contract address, seller, and nonce.
     * @param _seller The address of the invoice creator (seller).
     * @param _invoiceNonce The unique nonce assigned to this invoice.
     * @return invoiceId The 216-bit invoice ID.
     */
    function _computeInvoiceId(address _seller, uint256 _invoiceNonce) internal view returns (uint216 invoiceId) {
        invoiceId =
            (uint256(keccak256(abi.encode(address(this), _seller, _invoiceNonce))) & ((1 << 216) - 1)).toUint216();
    }

    /**
     * @notice Returns the owner of the PaymentProcessorStorage contract.
     * @dev This helper reads the owner directly from the linked PaymentProcessorStorage instance.
     * @return ownerAddress The address that currently owns the PaymentProcessorStorage contract.
     */
    function _owner() internal view returns (address ownerAddress) {
        ownerAddress = PaymentProcessorStorage(address(ppStorage)).owner();
    }

    /**
     * @notice Validates that the caller is the contract owner or the PaymentProcessorStorage contract.
     * @dev Reverts with NotAuthorized if neither condition is met.
     */
    function _isAuthorized() internal view {
        if (msg.sender != _owner() && msg.sender != address(ppStorage)) {
            revert NotAuthorized();
        }
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setInvoiceReleaseTime(uint216 _invoiceId, uint40 _holdPeriod) external {
        if (msg.sender != _owner()) revert NotAuthorized();
        Invoice memory i = invoices[_invoiceId];

        if (i.state != ACCEPTED && i.state != CREATED) {
            revert InvalidInvoiceState(i.state);
        }

        uint256 newReleaseTime = block.timestamp + _holdPeriod;

        invoices[_invoiceId].releaseAt = newReleaseTime.toUint40();
        heap.reschedule(_invoiceId, newReleaseTime.toUint40(), index);

        emit UpdateHoldPeriod(_invoiceId, newReleaseTime);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function calculateFee(uint256 _amount) public view returns (uint256 feeValue) {
        return (_amount * ppStorage.getFeeRate()) / BASIS_POINTS;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setMinimumInvoiceValue(uint256 _newMinimumInvoiceValue) public onlyAuthorized {
        minimumInvoiceValue = _newMinimumInvoiceValue;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setForwarderAddress(address _forwarderAddress) external onlyAuthorized {
        forwarder = _forwarderAddress;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setDecisionWindow(uint256 _newDecisionWindow) external onlyAuthorized {
        if (_newDecisionWindow == 0) revert InvalidDecisionWindow();
        decisionWindow = _newDecisionWindow;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getForwarder() external view returns (address forwarderAddress) {
        return forwarder;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getNextInvoiceNonce() external view returns (uint216 nextInvoiceNonceValue) {
        return ppStorage.getNextInvoiceNonce();
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getInvoiceData(uint216 _invoiceId) public view returns (Invoice memory i) {
        return invoices[_invoiceId];
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getMinimumInvoiceValue() external view returns (uint256 minimumValue) {
        return minimumInvoiceValue;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getItems() external view returns (uint216[] memory items) {
        return heap.getItems();
    }
}
