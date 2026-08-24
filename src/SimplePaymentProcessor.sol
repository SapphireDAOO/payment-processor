// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Escrow, IEscrow } from "./Escrow.sol";

import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";
import { ISimplePaymentProcessor } from "./interface/ISimplePaymentProcessor.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { TaskQueueLib } from "src/libraries/TaskQueueLib.sol";
import { FeeAuthorizationLib } from "src/libraries/FeeAuthorizationLib.sol";
import { INotes } from "./interface/INotes.sol";
import { IWETH } from "./interface/IWETH.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";

import {
    CREATED,
    PAID,
    ACCEPTED,
    REJECTED,
    CANCELED,
    REFUNDED,
    RELEASED,
    BURNED,
    BASIS_POINTS,
    SELLER_DEFAULT_DECISION_WINDOW,
    MAX_WITHDRAWAL_RETRIES
} from "./constants/Simple.sol";

/**
 * @title SimplePaymentProcessor
 * @notice Lightweight payment processor for single-invoice flows with native payments.
 * @dev Scheduled invoices sit in an internal min-heap drained by `processDueTasks`, which only the owner
 *      and the registered {PaymentAutomation} adapter may call.
 */
contract SimplePaymentProcessor is ISimplePaymentProcessor, ReentrancyGuard {
    using SafeCastLib for uint256;
    using TaskQueueLib for TaskQueueLib.Heap;

    /// @notice Notes contract used for encrypted invoice notes.
    INotes private immutable notes;

    /// @notice Internal min-heap used to efficiently manage scheduled invoice tasks by release time.
    TaskQueueLib.Heap private heap;

    /// @notice Reference to the external Payment Processor storage contract.
    IPaymentProcessorStorage public immutable ppStorage;

    /// @notice Wrapped native token the platform fee is paid in.
    IWETH public immutable weth;

    /// @notice The minimum allowed value (in wei) required to create a new invoice.
    uint256 private minimumInvoiceValue;

    /// @notice The window of time allowed for accepting a transaction after creation.
    uint256 private decisionWindow;

    /// @notice Address of the {PaymentAutomation} adapter allowed to drain due tasks on a keeper's behalf.
    address private automation;

    /// @dev True only while a fee is in flight from escrow to `weth`, so `receive` accepts nothing else.
    bool transient wrappingFee;

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
     * @notice Blocks the call while the system is paused.
     * @dev Reverts with ContractPaused. `cancelInvoice` is exempt: it moves no funds.
     */
    modifier whenNotPaused() {
        _whenNotPaused();
        _;
    }

    /**
     * @notice Initializes the payment processor with its storage, notes contract, and minimum invoice value.
     * @param _paymentProcessorStorageAddress The address of the shared payment processor storage contract.
     * @param _minimumInvoicePrice The new minimum default invoice value to set (in wei).
     * @param _notesAddress Address of the notes contract used for invoice notes.
     */
    constructor(
        address _paymentProcessorStorageAddress,
        uint256 _minimumInvoicePrice,
        address _notesAddress,
        address _wethAddress
    ) {
        ppStorage = IPaymentProcessorStorage(_paymentProcessorStorageAddress);
        notes = INotes(_notesAddress);
        weth = IWETH(_wethAddress);
        decisionWindow = SELLER_DEFAULT_DECISION_WINDOW;
        // Assigned directly rather than via setMinimumInvoiceValue: this contract is deployed against a
        // predicted storage address before the storage contract exists, so the setter's owner check
        // (which calls into ppStorage) would revert here.
        minimumInvoiceValue = _minimumInvoicePrice;
    }

    /**
     * @notice Accepts the native fee pulled out of an escrow on its way to being wrapped.
     * @dev Reverts on every other transfer, so native currency cannot be stranded here.
     */
    receive() external payable {
        if (!wrappingFee) revert UnexpectedNativeTransfer();
    }

    /// @inheritdoc ISimplePaymentProcessor
    function createInvoice(uint256 _price, uint32 _holdPeriod, bytes memory _storageRef, bool _share)
        public
        whenNotPaused
        returns (uint216 invoiceId)
    {
        if (_price < minimumInvoiceValue) revert ValueIsTooLow();
        uint216 newNonce = ppStorage.updateInvoiceNonce(1);
        invoiceId = _computeInvoiceId(msg.sender, newNonce);

        Invoice storage i = invoices[invoiceId];
        if (i.state != 0) revert InvoiceAlreadyExists();

        i.seller = msg.sender;
        i.createdAt = (block.timestamp).toUint40();
        i.price = _price;
        i.escrowHoldPeriod = _holdPeriod;
        i.state = CREATED;
        i.invoiceNonce = newNonce;
        i.feeRate = (ppStorage.getFeeRate()).toUint16();
        i.expiresAt = (block.timestamp + ppStorage.getPaymentValidityDuration()).toUint40();

        if (_storageRef.length != 0) notes.createNote(invoiceId, msg.sender, _storageRef, _share);

        emit InvoiceCreated(invoiceId, i);

        return invoiceId;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function pay(uint216 _invoiceId, bytes memory _storageRef, bool _share)
        public
        payable
        whenNotPaused
        returns (address escrowAddress)
    {
        return _payWithValue(_invoiceId, _storageRef, _share, msg.value);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function acceptPayment(uint216 _invoiceId, address _feeReceiver, bytes memory _data) public whenNotPaused {
        Invoice memory i = invoices[_invoiceId];
        _validateInvoiceStateForPaymentDecision(i);
        _validateFeeAuthorization(_invoiceId, _feeReceiver, _data);
        i.state = ACCEPTED;
        i.feeReceiver = _feeReceiver;

        i.releaseAt = (block.timestamp + i.escrowHoldPeriod).toUint40();
        heap.reschedule(_invoiceId, i.releaseAt, index);

        invoices[_invoiceId] = i;

        emit InvoiceAccepted(_invoiceId, _feeReceiver, i.releaseAt);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function rejectPayment(uint216 _invoiceId) public whenNotPaused {
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
    function release(uint216 _invoiceId) public whenNotPaused {
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
        address feeReceiver = _feeReceiverFor(i.feeReceiver);
        if (!_payFeeInWeth(i.escrow, feeReceiver, fee)) revert EscrowWithdrawFailed();
        emit InvoiceReleased(_invoiceId, i.price - fee, fee);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function refundBuyer(uint216 _invoiceId) public nonReentrant whenNotPaused {
        Invoice memory i = invoices[_invoiceId];
        if (i.state != PAID || block.timestamp < i.sellerActionDeadline) {
            revert InvoiceNotEligibleForRefund();
        }

        if (i.withdrawalRetries + 1 > MAX_WITHDRAWAL_RETRIES) {
            _burn(_invoiceId, i);
            return;
        }

        bool success = IEscrow(i.escrow).withdraw(address(0), i.buyer, i.price);

        if (!success) {
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
    function hasDueTasks() external view returns (bool dueTasksExist) {
        dueTasksExist = heap.due();
    }

    /// @inheritdoc ISimplePaymentProcessor
    function processDueTasks() external nonReentrant whenNotPaused {
        if (msg.sender != _owner() && msg.sender != automation) {
            revert NotAuthorized();
        }

        heap.processDueTask(index, _release, ppStorage.getGasThreshold());
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

        if (block.timestamp > i.expiresAt) {
            revert InvoiceIsNoLongerValid();
        }

        escrowAddress = address(new Escrow{ value: _value }(_invoiceId, address(this)));
        // do not use expires at here
        // variable name should match decision window
        uint40 sellerActionDeadline = (block.timestamp + decisionWindow).toUint40();

        i.escrow = escrowAddress;
        i.buyer = msg.sender;
        i.state = PAID;
        i.balance = _value;
        i.paidAt = (block.timestamp).toUint40();
        i.sellerActionDeadline = sellerActionDeadline;
        invoices[_invoiceId] = i;

        heap.insert(_invoiceId, sellerActionDeadline, index);
        if (_storageRef.length != 0) notes.createNote(_invoiceId, msg.sender, _storageRef, _share);

        emit InvoicePaid(_invoiceId, msg.sender, _value, sellerActionDeadline);
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

        if (block.timestamp > _i.sellerActionDeadline) {
            revert AcceptanceWindowExceeded();
        }
    }

    /**
     * @notice Attempts to automatically release or refund an invoice whose heap task is due.
     * @dev Returns a status code rather than reverting. Only PAID or ACCEPTED invoices reach the heap.
     *      `withdrawalRetries` is shared across both ACCEPTED phases, so the buyer fallback takes a
     *      cumulative ceiling of 2 * MAX_WITHDRAWAL_RETRIES.
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
     * @dev A failed withdrawal leaves the invoice on the heap for the next cycle.
     * @param _invoiceId The invoice to refund.
     * @param _pos The invoice's 1-based heap position.
     * @param _i In-memory snapshot of the invoice.
     * @param _withdrawRetries Cumulative retry ceiling; the funds are burned once reached.
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
            // Max retries exhausted: burn rather than strand the funds.
            emit TransferFailed(_invoiceId, _i.buyer, _i.price);
            _burn(_invoiceId, _i);
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
     * @dev Fee collection is best-effort: a failed fee transfer leaves the invoice RELEASED.
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
        address feeReceiver = _feeReceiverFor(_i.feeReceiver);
        if (!_payFeeInWeth(_i.escrow, feeReceiver, fee)) {
            emit TransferFailed(_invoiceId, feeReceiver, fee);
        }

        emit InvoiceReleased(_invoiceId, sellerAmount, fee);
        return TaskQueueLib.SUCCESSFUL;
    }

    /**
     * @notice Burns an invoice's escrowed funds to address(0) and transitions it to BURNED.
     * @dev Terminal and unrecoverable. Used once every withdrawal to the intended recipient has failed.
     * @param _invoiceId The invoice whose escrowed funds are burned.
     * @param _i In-memory snapshot of the invoice.
     */
    function _burn(uint216 _invoiceId, Invoice memory _i) internal {
        uint256 pos = index[_invoiceId];
        if (pos > 0 && pos <= heap.data.length) heap.removeAt(pos - 1, index);

        invoices[_invoiceId].state = BURNED;
        invoices[_invoiceId].balance = 0;

        if (!IEscrow(_i.escrow).withdraw(address(0), address(0), _i.price)) {
            emit TransferFailed(_invoiceId, address(0), _i.price);
            return;
        }

        emit PaymentBurned(_invoiceId, _i.price);
    }

    /**
     * @notice Computes a unique invoice ID from the contract address, seller, and nonce.
     * @param _seller The address of the invoice creator (seller).
     * @param _invoiceNonce The unique nonce assigned to this invoice.
     * @return invoiceId The 216-bit invoice ID.
     */
    /**
     * @notice Reverts unless `_feeReceiver` was authorized by the configured fee signer for this invoice.
     * @param _invoiceId The invoice the fee receiver is being attached to.
     * @param _feeReceiver The fee receiver supplied by the caller.
     * @param _data The fee signer's ECDSA signature over the authorization digest.
     */
    function _validateFeeAuthorization(uint216 _invoiceId, address _feeReceiver, bytes memory _data) internal view {
        if (_feeReceiver == address(0)) revert InvalidFeeReceiver();
        if (!FeeAuthorizationLib.isAuthorized(ppStorage.getFeeSigner(), _invoiceId, _feeReceiver, _data)) {
            revert InvalidFeeAuthorization();
        }
    }

    /**
     * @notice Resolves the address that should receive an invoice's platform fee.
     * @dev Falls back to the global fee receiver when the invoice carries none.
     * @param _feeReceiver The fee receiver stored on the invoice; zero when it has none.
     * @return feeReceiver The address to send the fee to.
     */
    /**
     * @notice Pulls the platform fee out of escrow, wraps it into WETH, and sends it to the fee receiver.
     * @dev Escrows hold native currency, so the fee lands here and is wrapped in the same call. Paying
     *      as an ERC20 means a receiver that rejects native transfers is still paid.
     * @param _escrow The escrow holding the invoice's funds.
     * @param _feeReceiver The address to pay the wrapped fee to.
     * @param _fee The fee amount, in native currency.
     * @return success True when the fee reached `_feeReceiver` as WETH.
     */
    function _payFeeInWeth(address _escrow, address _feeReceiver, uint256 _fee) internal returns (bool success) {
        wrappingFee = true;
        success = IEscrow(_escrow).withdraw(address(0), address(this), _fee);
        wrappingFee = false;

        if (!success) return false;

        weth.deposit{ value: _fee }();
        return weth.transfer(_feeReceiver, _fee);
    }

    function _feeReceiverFor(address _feeReceiver) internal view returns (address feeReceiver) {
        return _feeReceiver == address(0) ? ppStorage.getFeeReceiver() : _feeReceiver;
    }

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

    /// @dev Reverts with ContractPaused while the storage contract reports a pause.
    function _whenNotPaused() internal view {
        if (ppStorage.isPaused()) revert ContractPaused();
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
    function setAutomation(address _automationAddress) external onlyAuthorized {
        automation = _automationAddress;
        emit AutomationUpdated(_automationAddress);
    }

    /// @inheritdoc ISimplePaymentProcessor
    function setDecisionWindow(uint256 _newDecisionWindow) external onlyAuthorized {
        if (_newDecisionWindow == 0) revert InvalidDecisionWindow();
        decisionWindow = _newDecisionWindow;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getAutomation() external view returns (address automationAddress) {
        return automation;
    }

    /// @inheritdoc ISimplePaymentProcessor
    function getDecisionWindow() external view returns (uint256 decisionWindowValue) {
        return decisionWindow;
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
