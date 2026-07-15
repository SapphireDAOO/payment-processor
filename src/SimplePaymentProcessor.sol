// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Escrow, IEscrow } from "./Escrow.sol";

import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";
import { IERC165, IReceiver } from "./interface/IReceiver.sol";
import { ISimplePaymentProcessor } from "./interface/ISimplePaymentProcessor.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { TaskQueueLib } from "src/libraries/TaskQueueLib.sol";
import { INotes } from "./interface/INotes.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";

import {
    CREATED,
    PAID,
    ACCEPTED,
    REJECTED,
    CANCELED,
    REFUNDED,
    RELEASED,
    LOCKED,
    BASIS_POINTS,
    SELLER_DEFAULT_DECISION_WINDOW,
    MAX_WITHDRAWAL_RETRIES
} from "./constants/Simple.sol";

/**
 * @title SimplePaymentProcessor
 * @notice Lightweight payment processor for single-invoice flows with native payments.
 * @dev Implements basic escrow release and refund. Compliant with ISimplePaymentProcessor.
 */
contract SimplePaymentProcessor is ISimplePaymentProcessor, IReceiver, ReentrancyGuard {
    using SafeCastLib for uint256;
    using TaskQueueLib for TaskQueueLib.Heap;

    /// @notice Notes contract used for encrypted invoice notes.
    INotes private immutable notes;

    /// @notice Internal min-heap used to efficiently manage scheduled invoice tasks by release time.
    TaskQueueLib.Heap private heap;

    /// @notice Reference to the external Payment Processor storage contract.
    IPaymentProcessorStorage public immutable ppStorage;

    /// @notice The minimum allowed value (in wei) required to create a new invoice.
    uint256 private minimumInvoiceValue;

    /// @notice The window of time allowed for accepting a transaction after creation.
    uint256 public decisionWindow;

    /// @notice Address of the CRE (Keystone) forwarder contract responsible for delivering workflow reports via `onReport`.
    address private forwarder;

    /// @notice Owner address of the CRE workflow authorized to trigger `onReport`, as reported in the report metadata.
    address private workflowOwner;

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
        decisionWindow = SELLER_DEFAULT_DECISION_WINDOW;
        // Assigned directly rather than via setMinimumInvoiceValue: this contract is deployed against a
        // predicted storage address before the storage contract exists, so the setter's owner check
        // (which calls into ppStorage) would revert here.
        minimumInvoiceValue = _minimumInvoicePrice;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function createInvoice(uint256 _price, bytes memory _storageRef, bool _share) public returns (uint216 invoiceId) {
        if (_price < minimumInvoiceValue) revert ValueIsTooLow();
        uint216 newNonce = ppStorage.updateInvoiceNonce(1);
        invoiceId = _computeInvoiceId(msg.sender, newNonce);
        if (invoices[invoiceId].state != 0) revert InvoiceAlreadyExists();

        Invoice memory i;
        i.seller = msg.sender;
        i.createdAt = (block.timestamp).toUint40();
        i.price = _price;
        i.state = CREATED;
        i.invoiceNonce = newNonce;
        i.feeRate = (ppStorage.getFeeRate()).toUint16();
        i.invalidateAt = (block.timestamp + ppStorage.getPaymentValidityDuration()).toUint40();

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

        invoices[_invoiceId] = i;

        emit InvoiceAccepted(_invoiceId);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function rejectPayment(uint216 _invoiceId) public {
        Invoice memory i = invoices[_invoiceId];
        _validateInvoiceStateForPaymentDecision(i);

        invoices[_invoiceId].state = REJECTED;
        invoices[_invoiceId].balance = 0;
        heap.removeAt(index[_invoiceId] - 1, index);

        if (!IEscrow(i.escrow).withdraw(address(0), i.buyer, i.price)) revert EscrowWithdrawFailed();

        emit InvoiceRejected(_invoiceId, i.balance);
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

        uint256 fee = _calculateFee(i.price, i.feeRate);
        invoices[_invoiceId].state = RELEASED;
        invoices[_invoiceId].balance = 0;

        heap.removeAt(index[_invoiceId] - 1, index);

        if (!IEscrow(i.escrow).withdraw(address(0), msg.sender, i.price - fee)) revert EscrowWithdrawFailed();
        if (!IEscrow(i.escrow).withdraw(address(0), ppStorage.getFeeReceiver(), fee)) revert EscrowWithdrawFailed();
        emit InvoiceReleased(_invoiceId, i.price - fee, fee);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function refundBuyer(uint216 _invoiceId) public nonReentrant {
        Invoice memory i = invoices[_invoiceId];
        if (i.state != PAID || block.timestamp < i.expiresAt) {
            revert InvoiceNotEligibleForRefund();
        }

        if (i.withdrawalRetries + 1 > MAX_WITHDRAWAL_RETRIES) {
            uint256 pos = index[_invoiceId];
            if (pos > 0 && pos <= heap.data.length) heap.removeAt(pos - 1, index);
            invoices[_invoiceId].state = LOCKED;
            return;
        }

        bool success = IEscrow(i.escrow).withdraw(address(0), i.buyer, i.price);

        if (!success) {
            invoices[_invoiceId].state = PAID;
            invoices[_invoiceId].balance = i.price;
            invoices[_invoiceId].withdrawalRetries += 1;
        } else {
            uint256 pos = index[_invoiceId];
            if (pos == 0 || pos > heap.data.length) revert InvalidHeapPosition();
            heap.removeAt(pos - 1, index);
            invoices[_invoiceId].state = REFUNDED;
            invoices[_invoiceId].balance = 0;
            emit InvoiceRefunded(_invoiceId, i.balance);
        }
    }

    /// @inheritdoc ISimplePaymentProcessor
    function releaseLocked(uint216 _invoiceId, address _recipient, uint256 _amount) external onlyAuthorized {
        Invoice memory i = invoices[_invoiceId];
        if (i.state != LOCKED) revert InvalidInvoiceState(i.state);

        if (i.balance == _amount) {
            i.state = RELEASED;
        }

        invoices[_invoiceId].balance -= _amount;

        if (!IEscrow(i.escrow).withdraw(address(0), _recipient, _amount)) revert EscrowWithdrawFailed();

        emit LockedPaymentRecovered(_invoiceId, _recipient, _amount);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function hasDueTasks() external view returns (bool dueTasksExist) {
        dueTasksExist = heap.due();
    }

    /**
     * @notice Handles a verified report delivered by the CRE forwarder and processes due invoice tasks.
     * @dev The report payload is ignored; delivery of a verified report is itself the trigger.
     *      Reverts with NotAuthorized if the caller is not the configured forwarder, and with
     *      UnauthorizedWorkflowOwner if the metadata does not carry the authorized workflow owner.
     * @inheritdoc IReceiver
     */
    function onReport(bytes calldata _metadata, bytes calldata) external nonReentrant {
        if (msg.sender != forwarder) {
            revert NotAuthorized();
        }

        address reportedWorkflowOwner = _decodeWorkflowOwner(_metadata);
        if (reportedWorkflowOwner != workflowOwner) {
            revert UnauthorizedWorkflowOwner(reportedWorkflowOwner);
        }

        _processDueTasks();
    }

    /// @inheritdoc ISimplePaymentProcessor
    function processDueTasks() external nonReentrant {
        if (msg.sender != _owner()) {
            revert NotAuthorized();
        }

        _processDueTasks();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 _interfaceId) external pure returns (bool supported) {
        return _interfaceId == type(IReceiver).interfaceId || _interfaceId == type(IERC165).interfaceId;
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
     *      Only PAID or ACCEPTED invoices are ever placed on the heap, so no other states are handled.
     *      PAID path: retries buyer refund up to MAX_WITHDRAWAL_RETRIES times. On each failure the retry
     *        counter is incremented and the invoice remains on the heap for the next upkeep cycle.
     *        Transitions to REFUNDED on success or LOCKED once the ceiling is reached.
     *      ACCEPTED path: retries seller release up to MAX_WITHDRAWAL_RETRIES times, then falls back to
     *        buyer refund for another MAX_WITHDRAWAL_RETRIES attempts, using the same counter across both
     *        phases. Buyer fallback begins once the counter reaches MAX_WITHDRAWAL_RETRIES.
     *        Transitions to RELEASED, REFUNDED, or LOCKED accordingly.
     *      Invalid heap position: returns ERROR.
     * @param _invoiceId The ID of the invoice to release.
     * @return status `SUCCESSFUL` or `ERROR`.
     */
    function _release(uint216 _invoiceId) internal returns (uint256 status) {
        Invoice memory i = invoices[_invoiceId];

        uint256 pos = index[_invoiceId];
        if (pos == 0 || pos > heap.data.length) return TaskQueueLib.ERROR;

        if (i.state == PAID) return _autoRefund(_invoiceId, pos, i, MAX_WITHDRAWAL_RETRIES);
        if (i.withdrawalRetries < MAX_WITHDRAWAL_RETRIES) {
            return _autoRelease(_invoiceId, pos, i);
        }
        return _autoRefund(_invoiceId, pos, i, 2 * MAX_WITHDRAWAL_RETRIES);
    }

    /**
     * @notice Executes an automated buyer refund with retry logic.
     * @dev Attempts to withdraw `_i.price` to `_i.buyer`. On failure the retry counter is incremented
     *      and the invoice remains on the heap for the next upkeep cycle. Transitions to REFUNDED on
     *      success or LOCKED once `withdrawalRetries` reaches `_withdrawRetries`.
     * @param _invoiceId The invoice to refund.
     * @param _pos The invoice's 1-based heap position.
     * @param _i In-memory snapshot of the invoice.
     * @param _withdrawRetries Retry ceiling; invoice is LOCKED when `withdrawalRetries` reaches this value.
     * @return status `SUCCESSFUL`.
     */
    function _autoRefund(uint216 _invoiceId, uint256 _pos, Invoice memory _i, uint8 _withdrawRetries)
        internal
        returns (uint256 status)
    {
        if (!IEscrow(_i.escrow).withdraw(address(0), _i.buyer, _i.price)) {
            if (_i.withdrawalRetries < _withdrawRetries) {
                invoices[_invoiceId].withdrawalRetries = _i.withdrawalRetries + 1;
                emit WithdrawalRetried(_invoiceId, _i.buyer, _i.price, _i.withdrawalRetries + 1);
                return TaskQueueLib.SUCCESSFUL;
            }
            // Max retries exhausted: lock the invoice, funds remain in escrow.
            heap.removeAt(_pos - 1, index);
            invoices[_invoiceId].state = LOCKED;
            invoices[_invoiceId].balance = 0;
            emit TransferFailed(_invoiceId, _i.buyer, _i.price);
            return TaskQueueLib.SUCCESSFUL;
        }

        heap.removeAt(_pos - 1, index);
        invoices[_invoiceId].state = REFUNDED;
        invoices[_invoiceId].balance = 0;
        emit InvoiceRefunded(_invoiceId, _i.balance);
        return TaskQueueLib.SUCCESSFUL;
    }

    /**
     * @notice Executes an automated seller release with retry logic.
     * @dev Computes the platform fee, then attempts to withdraw the net seller amount from escrow.
     *      On failure the retry counter is incremented and the invoice remains on the heap for the
     *      next upkeep cycle. On success, the fee is collected best-effort (failure emits TransferFailed).
     *      Transitions to RELEASED on success. Once `withdrawalRetries` reaches MAX_WITHDRAWAL_RETRIES,
     *      `_release` routes to `_autoRefund` for buyer fallback instead of calling this function again.
     * @param _invoiceId The invoice to release.
     * @param _pos The invoice's 1-based heap position.
     * @param _i In-memory snapshot of the invoice.
     * @return status `SUCCESSFUL`.
     */
    function _autoRelease(uint216 _invoiceId, uint256 _pos, Invoice memory _i) internal returns (uint256 status) {
        uint256 fee = _calculateFee(_i.price, _i.feeRate);
        uint256 sellerAmount = _i.price - fee;
        if (!IEscrow(_i.escrow).withdraw(address(0), _i.seller, sellerAmount)) {
            invoices[_invoiceId].withdrawalRetries = _i.withdrawalRetries + 1;
            emit WithdrawalRetried(_invoiceId, _i.seller, sellerAmount, _i.withdrawalRetries + 1);
            return TaskQueueLib.SUCCESSFUL;
        }
        invoices[_invoiceId].state = RELEASED;
        invoices[_invoiceId].balance = 0;
        heap.removeAt(_pos - 1, index);
        if (!IEscrow(_i.escrow).withdraw(address(0), ppStorage.getFeeReceiver(), fee)) {
            emit TransferFailed(_invoiceId, ppStorage.getFeeReceiver(), fee);
        }

        emit InvoiceReleased(_invoiceId, sellerAmount, fee);
        return TaskQueueLib.SUCCESSFUL;
    }

    /**
     * @notice Processes due invoice tasks from the heap within the configured gas threshold.
     * @dev Shared by `onReport` (CRE forwarder path) and `processDueTasks` (owner fallback path).
     */
    function _processDueTasks() internal {
        uint256 gasThreshold = ppStorage.getGasThreshold();

        heap.processDueTask(index, _release, gasThreshold);
    }

    /**
     * @notice Extracts the workflow owner address from CRE report metadata.
     * @dev Metadata layout (tightly packed): workflowId (32 bytes), workflowName (10 bytes),
     *      workflowOwner (20 bytes), reportId (2 bytes). Reads past the end of short metadata
     *      yield zero bytes, so malformed metadata decodes to an address that fails the
     *      `onReport` owner check rather than reverting here.
     * @param _metadata The report metadata delivered by the forwarder.
     * @return reportedWorkflowOwner The workflow owner address carried in the metadata.
     */
    function _decodeWorkflowOwner(bytes calldata _metadata) internal pure returns (address reportedWorkflowOwner) {
        assembly {
            // workflowOwner starts at byte 42 (after 32-byte workflowId and 10-byte workflowName);
            // load 32 bytes and shift right so the 20-byte address occupies the low bits.
            reportedWorkflowOwner := shr(96, calldataload(add(_metadata.offset, 42)))
        }
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

        if (i.state != ACCEPTED) {
            revert InvalidInvoiceState(i.state);
        }

        uint256 newReleaseTime = block.timestamp + _holdPeriod;

        invoices[_invoiceId].releaseAt = newReleaseTime.toUint40();
        heap.reschedule(_invoiceId, newReleaseTime.toUint40(), index);

        emit UpdateHoldPeriod(_invoiceId, newReleaseTime);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function calculateFee(uint256 _amount) public view returns (uint256 feeValue) {
        return _calculateFee(_amount, ppStorage.getFeeRate());
    }

    /**
     * @notice Calculates the fee for an amount at a specific fee rate.
     * @dev Used by release paths with the fee rate snapshotted on the invoice at creation,
     *      so global fee rate changes never affect already-created invoices.
     * @param _amount The amount to calculate the fee from.
     * @param _feeRate The fee rate in basis points (1% = 100).
     * @return feeValue The calculated fee amount.
     */
    function _calculateFee(uint256 _amount, uint256 _feeRate) internal pure returns (uint256 feeValue) {
        return (_amount * _feeRate) / BASIS_POINTS;
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
    function setWorkflowOwner(address _workflowOwner) external onlyAuthorized {
        workflowOwner = _workflowOwner;
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
    function getWorkflowOwner() external view returns (address workflowOwnerAddress) {
        return workflowOwner;
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
