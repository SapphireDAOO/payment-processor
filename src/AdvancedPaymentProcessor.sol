// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EscrowFactory } from "./EscrowFactory.sol";
import { IEscrow } from "./interface/IEscrow.sol";
import { IOracleManager } from "./interface/IOracleManager.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";
import { IAdvancedPaymentProcessor } from "./interface/IAdvancedPaymentProcessor.sol";
import { AutomationCompatibleInterface } from "./interface/AutomationCompatibleInterface.sol";

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TaskQueueLib } from "src/libraries/TaskQueueLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";

import {
    CREATED,
    PAID,
    REFUNDED,
    CANCELED,
    DISPUTED,
    DISPUTE_RESOLVED,
    DISPUTE_DISMISSED,
    DISPUTE_SETTLED,
    RELEASED,
    LOCKED,
    BASIS_POINTS,
    DEFAULT_DECIMAL,
    DEFAULT_MINIMUM_INVOICE_PRICE,
    MAX_WITHDRAWAL_RETRIES
} from "./constants/Advanced.sol";

/**
 * @title AdvancedPaymentProcessor
 * @notice Handles the creation, payment, and lifecycle management of single and meta invoices with escrow logic.
 * @dev Inherits interfaces for payment processing, Chainlink Automation compatibility, and escrow deployment.
 */
contract AdvancedPaymentProcessor is
    IAdvancedPaymentProcessor,
    AutomationCompatibleInterface,
    EscrowFactory,
    ReentrancyGuard
{
    using TaskQueueLib for TaskQueueLib.Heap;

    using { SafeTransferLib.safeTransferETH, SafeTransferLib.safeTransferFrom } for address;
    using { SafeCastLib.toUint40, SafeCastLib.toUint216 } for uint256;
    using { SafeCastLib.toUint256 } for int256;
    using { FixedPointMathLib.mulDiv, FixedPointMathLib.mulDivUp } for uint256;

    /// @notice Internal min-heap used to efficiently manage scheduled invoice tasks by release time.
    TaskQueueLib.Heap private heap;

    /// @notice Address of the forwarder contract responsible for calling performUpkeep.
    address private forwarder;

    /// @notice Minimum USD price (8 decimals) an invoice must meet to be accepted by the processor.
    uint256 private minimumPrice;

    /// @notice Reference to the external Payment Processor storage contract.
    IPaymentProcessorStorage public immutable ppStorage;

    IOracleManager public immutable oracle;

    /// @notice The next available meta-invoice ID to be assigned.
    uint216 private nextMetaInvoiceNonce;

    /**
     * @notice Mapping from unique invoice ID to its invoice data.
     * @dev Used for standalone invoices (not part of a meta-invoice).
     */
    mapping(uint216 invoiceId => Invoice invoice) private invoices;

    /**
     * @notice Mapping from meta-invoice ID to its aggregate meta-invoice data.
     * @dev Stores metadata for grouped payments consisting of multiple sub-invoices.
     *      Each MetaInvoice contains the total price and all associated sub-invoice IDs.
     */
    mapping(uint216 metaInvoiceId => MetaInvoice invoice) private metaInvoices;

    /**
     *  @notice Maps task or invoice ID to its 1-based index position in the heap.
     * @dev A value of 0 means the task is not present in the heap
     */
    mapping(uint216 invoiceId => uint256 key) private index;

    /**
     * @notice Restricts function access to the authorized marketplace address.
     * @dev Reverts with NotAuthorized() if the caller is not the marketplace.
     */
    modifier onlyMarketplace() {
        _onlyMarketplace();
        _;
    }

    /**
     * @notice Restricts function access to the owner of the PaymentProcessorStorage contract.
     * @dev Reverts with NotAuthorized() if the caller is not the owner.
     */
    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    /**
     * @notice Initializes the AdvancedPaymentProcessor contract with core configuration.
     * @param _paymentProcessorStorageAddress The address of the shared payment processor storage contract.
     * @param _oracle The address of the deployed OracleManager contract used for token price conversions.
     */
    constructor(address _paymentProcessorStorageAddress, address _oracle) {
        ppStorage = IPaymentProcessorStorage(_paymentProcessorStorageAddress);
        oracle = IOracleManager(_oracle);
        nextMetaInvoiceNonce = 1;
        minimumPrice = DEFAULT_MINIMUM_INVOICE_PRICE;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function createSingleInvoice(InvoiceCreationParam memory _param)
        external
        onlyMarketplace
        returns (uint216 invoiceId)
    {
        return _createInvoice(ppStorage.updateInvoiceNonce(1), 0, _param);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function createMetaInvoice(InvoiceCreationParam[] memory _param)
        external
        onlyMarketplace
        returns (uint216 metaInvoiceId)
    {
        uint256 length = _param.length;
        if (length == 0) revert EmptyMetaInvoice();

        uint256 totalPrice = 0;
        uint216 firstInvoiceNonce = ppStorage.getNextInvoiceNonce();

        uint256 lastInvoiceNonce = length + firstInvoiceNonce - 1;

        metaInvoiceId = _computeMetaInvoiceId(firstInvoiceNonce, lastInvoiceNonce, nextMetaInvoiceNonce);
        if (metaInvoices[metaInvoiceId].price != 0) revert MetaInvoiceAlreadyExists();

        for (uint216 j = 0; j < length; j++) {
            totalPrice += _param[j].price;
            metaInvoices[metaInvoiceId].subInvoiceIds
                .push(_createInvoice(firstInvoiceNonce + j, metaInvoiceId, _param[j]));
        }

        metaInvoices[metaInvoiceId].price = totalPrice;
        nextMetaInvoiceNonce++;
        ppStorage.updateInvoiceNonce(length.toUint216());

        emit MetaInvoiceCreated(metaInvoiceId, totalPrice);

        return metaInvoiceId;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function payInvoice(uint216 _invoiceId, address _paymentToken) external payable nonReentrant {
        Invoice memory i = invoices[_invoiceId];
        uint256 priceInToken = getTokenValueFromUsd(_paymentToken, i.price);

        if (_paymentToken == address(0)) {
            if (msg.value != priceInToken) revert InvalidNativePayment();
        } else {
            if (msg.value != 0) revert InvalidNativePayment();
        }

        _pay(i, _invoiceId, _paymentToken, priceInToken);
        invoices[_invoiceId] = i;
    }

    /**
     * @notice Pays all sub-invoices in a meta-invoice using native ETH.
     * @dev Caller must send exactly the oracle-converted total. Any dust from integer rounding is refunded.
     * @param _invoiceId The meta-invoice ID to pay.
     */
    function payMetaInvoiceWithValue(uint216 _invoiceId) external payable nonReentrant {
        MetaInvoice memory m = metaInvoices[_invoiceId];
        if (m.price == 0) revert InvoiceDoesNotExist();

        uint256 usdPerToken = _usdPerToken(address(0));
        uint256 priceInToken = m.price.mulDivUp(10 ** DEFAULT_DECIMAL, usdPerToken);

        if (priceInToken != msg.value) revert InvalidMetaInvoicePaymentAmount(msg.value, priceInToken);

        uint256 amountPaid = _paySubInvoices(m.subInvoiceIds, address(0), usdPerToken, DEFAULT_DECIMAL);
        if (amountPaid == 0) revert InvalidInvoiceState();

        uint256 refundableAmount = priceInToken - amountPaid;

        if (refundableAmount > 0) (msg.sender).safeTransferETH(refundableAmount);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function payMetaInvoice(uint216 _invoiceId, address _paymentToken) external nonReentrant {
        MetaInvoice memory m = metaInvoices[_invoiceId];
        if (m.price == 0) revert InvoiceDoesNotExist();

        uint256 usdPerToken = _usdPerToken(_paymentToken);
        uint8 decimals = _getDecimals(_paymentToken);

        _paySubInvoices(m.subInvoiceIds, _paymentToken, usdPerToken, decimals);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function createDispute(uint216 _invoiceId) external onlyMarketplace {
        Invoice memory i = invoices[_invoiceId];
        if (i.state != PAID) revert InvalidInvoiceState();

        i.state = DISPUTED;
        invoices[_invoiceId] = i;
        heap.removeAt(index[_invoiceId] - 1, index);
        emit DisputeCreated(_invoiceId);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function handleDispute(uint216 _invoiceId, uint8 _resolution, uint256 _sellerShare) external onlyMarketplace {
        Invoice memory i = invoices[_invoiceId];

        if (i.state != DISPUTED) revert InvalidInvoiceState();
        if (_sellerShare > BASIS_POINTS) revert InvalidSellersPayoutShare();
        if (_resolution != DISPUTE_DISMISSED && _resolution != DISPUTE_SETTLED) {
            revert InvalidDisputeResolution();
        }

        i.state = _resolution;
        invoices[_invoiceId] = i;

        if (_resolution == DISPUTE_DISMISSED) {
            heap.insert(_invoiceId, i.releaseAt, index);
            emit DisputeDismissed(_invoiceId);
        }

        if (_resolution == DISPUTE_SETTLED) {
            invoices[_invoiceId].balance = 0;
            (uint256 sellerReceivingValue, uint256 buyerReceivingValue) = _distributeFunds(i, _sellerShare);
            emit DisputeSettled(_invoiceId, sellerReceivingValue, buyerReceivingValue);
        }
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function release(uint216 _invoiceId) external onlyMarketplace {
        if (_release(_invoiceId) != TaskQueueLib.SUCCESSFUL) revert InvalidInvoiceState();
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function releaseLocked(uint216 _invoiceId, address _recipient, uint256 _amount) external onlyOwner {
        Invoice memory i = invoices[_invoiceId];
        if (i.state != LOCKED) revert InvalidInvoiceState();
        if (_amount > i.balance) revert InsufficientBalance();

        if (i.balance == _amount) {
            i.state = RELEASED;
        }

        invoices[_invoiceId].balance -= _amount;

        if (!IEscrow(i.escrow).withdraw(i.paymentToken, _recipient, _amount)) revert EscrowWithdrawFailed();

        emit LockedPaymentRecovered(_invoiceId, _recipient, _amount);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function refund(uint216 _invoiceId, uint256 _refundShare) external onlyMarketplace {
        Invoice memory i = invoices[_invoiceId];
        if (i.state != PAID) revert InvalidInvoiceState();
        if (_refundShare == 0 || _refundShare > BASIS_POINTS) revert InvalidSellersPayoutShare();

        uint256 amount = _applyBasisPoints(i.balance, _refundShare);

        if (amount > i.balance) revert InsufficientBalance();

        if (_refundShare == BASIS_POINTS) {
            heap.removeAt(index[_invoiceId] - 1, index);
            i.state = REFUNDED;
        }

        i.balance -= amount;
        invoices[_invoiceId] = i;

        if (!IEscrow(i.escrow).withdraw(i.paymentToken, i.buyer, amount)) revert EscrowWithdrawFailed();

        emit Refunded(_invoiceId, amount);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function cancelInvoice(uint216 _invoiceId) public onlyMarketplace {
        Invoice memory i = invoices[_invoiceId];
        if (i.state != CREATED) revert InvalidInvoiceState();
        invoices[_invoiceId].state = CANCELED;
        if (i.metaInvoiceId != 0) {
            metaInvoices[i.metaInvoiceId].price -= i.price;
        }
        emit InvoiceCanceled(_invoiceId);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function resolveDispute(uint216 _invoiceId) external onlyMarketplace {
        Invoice memory i = invoices[_invoiceId];
        if (i.state != DISPUTED) revert InvalidInvoiceState();
        i.state = DISPUTE_RESOLVED;
        heap.insert(_invoiceId, i.releaseAt, index);

        invoices[_invoiceId] = i;
        emit DisputeResolved(_invoiceId);
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
        heap.processDueTask(index, _release, gasThreshold);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function setInvoiceReleaseTime(uint216 _invoiceId, uint256 _holdPeriod) external onlyOwner {
        Invoice memory i = invoices[_invoiceId];

        if (i.state != PAID && i.state != DISPUTE_RESOLVED && i.state != DISPUTE_DISMISSED) {
            revert InvalidInvoiceState();
        }

        i.releaseAt = (block.timestamp + _holdPeriod).toUint40();
        invoices[_invoiceId] = i;

        heap.reschedule(_invoiceId, i.releaseAt, index);

        emit UpdateReleaseTime(_invoiceId, _holdPeriod);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function setForwarderAddress(address _forwarderAddress) external onlyOwner {
        forwarder = _forwarderAddress;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function setMinimumPrice(uint256 _newMinimumPrice) external onlyOwner {
        minimumPrice = _newMinimumPrice;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getForwarder() external view returns (address forwarderAddress) {
        return forwarder;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getTokenValueFromUsd(address _paymentToken, uint256 _usdAmount) public view returns (uint256 tokenValue) {
        uint256 usdPerToken = _usdPerToken(_paymentToken);
        uint8 tokenDecimals = _paymentToken == address(0) ? DEFAULT_DECIMAL : _getDecimals(_paymentToken);

        tokenValue = _usdAmount.mulDivUp(10 ** tokenDecimals, usdPerToken);
    }

    /**
     * @notice Fetches the Chainlink USD price for a payment token and validates feed freshness.
     * @dev Performs three layers of validation before returning the price:
     *      1. Sequencer uptime: if `sequencerUptimeFeed` is set, checks that the L2 sequencer is up
     *         (answer == 0) and that `SEQUENCER_GRACE_PERIOD` has elapsed since it last restarted.
     *         A reverting or unavailable feed also reverts with `SequencerDown`.
     *         Skipped when `sequencerUptimeFeed == address(0)` (L1 or local testnets).
     *      2. Round completeness: reverts with `StalePrice` if `answeredInRound < roundId`.
     *      3. Heartbeat: reverts with `StalePriceFeed` if the update is older than `config.heartbeat`.
     * @param _paymentToken The token address (address(0) for native ETH).
     * @return The token's USD price with 8 decimals as returned by the Chainlink aggregator.
     */
    function _usdPerToken(address _paymentToken) internal view returns (uint256) {
        return oracle.getUsdPerToken(_paymentToken);
    }

    /**
     * @notice Checks whether an invoice is currently eligible to be released to the seller.
     * @dev An invoice is releasable if it is in the PAID, DISPUTE_RESOLVED, or DISPUTE_DISMISSED state
     *      and its `releaseAt` timestamp has been reached or passed.
     * @param _i The in-memory invoice struct to evaluate.
     * @return isReleasable True if the invoice can be released.
     */
    function _isReleasable(Invoice memory _i) internal view returns (bool isReleasable) {
        isReleasable = (_i.state == PAID || _i.state == DISPUTE_RESOLVED || _i.state == DISPUTE_DISMISSED)
            && block.timestamp >= _i.releaseAt;
    }

    /**
     * @notice Dispatches automation release for a due invoice.
     * @dev Called by `performUpkeep` via `processDueTask`. Returns a status code rather than reverting.
     *      Only PAID, DISPUTE_RESOLVED, and DISPUTE_DISMISSED invoices are ever on the heap.
     *      Seller release is retried up to MAX_WITHDRAWAL_RETRIES times, then falls back to buyer
     *      refund for another MAX_WITHDRAWAL_RETRIES attempts. Transitions to RELEASED, REFUNDED,
     *      or LOCKED accordingly. Invalid heap position returns ERROR.
     * @param _invoiceId The ID of the invoice to release.
     * @return status `SUCCESSFUL`, `NOT_ELIGIBLE_FOR_RELEASE`, or `ERROR`.
     */
    function _release(uint216 _invoiceId) internal returns (uint256 status) {
        Invoice memory i = invoices[_invoiceId];
        if (!_isReleasable(i)) return TaskQueueLib.NOT_ELIGIBLE_FOR_RELEASE;

        uint256 pos = index[_invoiceId];
        if (pos == 0 || pos > heap.data.length) return TaskQueueLib.ERROR;

        if (i.withdrawalRetries < MAX_WITHDRAWAL_RETRIES) return _autoRelease(_invoiceId, pos, i);

        return _autoRefund(_invoiceId, pos, i, 2 * MAX_WITHDRAWAL_RETRIES);
    }

    /**
     * @notice Executes automated seller release with retry logic.
     * @dev Computes fee from current balance and attempts seller withdrawal. On failure the retry
     *      counter is incremented and the invoice remains on the heap for the next upkeep cycle.
     *      On success fee is collected best-effort (failure emits TransferFailed).
     *      Once `withdrawalRetries` reaches MAX_WITHDRAWAL_RETRIES, `_release` routes to buyer fallback.
     * @param _invoiceId The invoice to release.
     * @param _pos The invoice's 1-based heap position.
     * @param _i In-memory snapshot of the invoice.
     * @return status `SUCCESSFUL`.
     */
    function _autoRelease(uint216 _invoiceId, uint256 _pos, Invoice memory _i) internal returns (uint256 status) {
        uint256 fee = _applyBasisPoints(_i.balance, ppStorage.getFeeRate());
        uint256 sellerNetAmount = _i.balance - fee;
        if (!IEscrow(_i.escrow).withdraw(_i.paymentToken, _i.seller, sellerNetAmount)) {
            invoices[_invoiceId].withdrawalRetries = _i.withdrawalRetries + 1;
            emit WithdrawalRetried(_invoiceId, _i.seller, sellerNetAmount, _i.withdrawalRetries + 1);
            return TaskQueueLib.SUCCESSFUL;
        }
        invoices[_invoiceId].state = RELEASED;
        invoices[_invoiceId].balance = 0;
        heap.removeAt(_pos - 1, index);
        if (!IEscrow(_i.escrow).withdraw(_i.paymentToken, ppStorage.getFeeReceiver(), fee)) {
            emit TransferFailed(_invoiceId, ppStorage.getFeeReceiver(), fee);
        }

        emit PaymentReleased(_invoiceId, _i.seller, _i.paymentToken, sellerNetAmount);
        return TaskQueueLib.SUCCESSFUL;
    }

    /**
     * @notice Executes automated buyer refund with retry logic.
     * @dev Attempts to withdraw `_i.balance` to `_i.buyer`. On failure the retry counter is
     *      incremented and the invoice remains on the heap for the next upkeep cycle.
     *      Transitions to REFUNDED on success or LOCKED once `withdrawalRetries` reaches `_withdrawRetries`.
     * @param _invoiceId The invoice to refund.
     * @param _pos The invoice's 1-based heap position.
     * @param _i In-memory snapshot of the invoice.
     * @param _withdrawRetries Retry ceiling; LOCKED when `withdrawalRetries` reaches this value.
     * @return status `SUCCESSFUL`.
     */
    function _autoRefund(uint216 _invoiceId, uint256 _pos, Invoice memory _i, uint8 _withdrawRetries)
        internal
        returns (uint256 status)
    {
        if (!IEscrow(_i.escrow).withdraw(_i.paymentToken, _i.buyer, _i.balance)) {
            if (_i.withdrawalRetries < _withdrawRetries) {
                invoices[_invoiceId].withdrawalRetries = _i.withdrawalRetries + 1;
                emit WithdrawalRetried(_invoiceId, _i.buyer, _i.balance, _i.withdrawalRetries + 1);
                return TaskQueueLib.SUCCESSFUL;
            }

            heap.removeAt(_pos - 1, index);
            invoices[_invoiceId].state = LOCKED;
            return TaskQueueLib.SUCCESSFUL;
        }

        heap.removeAt(_pos - 1, index);
        invoices[_invoiceId].state = REFUNDED;
        invoices[_invoiceId].balance = 0;
        emit Refunded(_invoiceId, _i.balance);
        return TaskQueueLib.SUCCESSFUL;
    }

    /**
     * @notice Shared base for all invoice payment paths.
     * @dev For native ETH payments, the caller must have already validated `msg.value == _tokenPrice`.
     *      For ERC20 payments, tokens are pulled from the caller via safeTransferFrom.
     * @param _i The invoice memory struct to be updated in-place.
     * @param _invoiceId The ID of the invoice being paid.
     * @param _paymentToken The token address (address(0) for native ETH).
     * @param _tokenPrice The oracle-converted price in the payment token's units.
     */
    function _pay(Invoice memory _i, uint216 _invoiceId, address _paymentToken, uint256 _tokenPrice)
        internal
        returns (uint256 amountPaid)
    {
        if (block.timestamp > _i.expiresAt) revert InvoiceExpired();
        if (msg.sender == _i.seller) revert BuyerCannotBeSeller();
        if (_i.state != CREATED) revert InvalidInvoiceState();

        uint256 nativeValue = _paymentToken == address(0) ? _tokenPrice : 0;
        address escrowAddress = _create(
            EscrowCreationParams({
                seller: _i.seller,
                buyer: msg.sender,
                invoiceId: _invoiceId,
                value: nativeValue,
                paymentToken: _paymentToken
            })
        );

        _i.buyer = msg.sender;
        _i.state = PAID;
        _i.escrow = escrowAddress;
        _i.paidAt = (block.timestamp).toUint40();
        _i.balance = _tokenPrice;
        _i.amountPaid = _tokenPrice;
        _i.paymentToken = _paymentToken;

        if (_paymentToken != address(0)) {
            _paymentToken.safeTransferFrom(msg.sender, escrowAddress, _tokenPrice);
        }

        if (_i.releaseAt == 0) {
            uint256 holdPeriod =
                _i.escrowHoldPeriod != 0 ? uint256(_i.escrowHoldPeriod) : ppStorage.getDefaultHoldPeriod();
            _i.releaseAt = (block.timestamp + holdPeriod).toUint40();
            heap.insert(_invoiceId, _i.releaseAt, index);
        }

        emit InvoicePaid(_invoiceId, _paymentToken, escrowAddress, _tokenPrice, _i.releaseAt);
        return _i.amountPaid;
    }

    /**
     * @notice Iterates sub-invoices and pays each one that is still in the CREATED state.
     * @dev Computes each sub-invoice's token price from a single cached oracle price to avoid
     *      multiple Chainlink calls and to ensure consistent rounding across the batch.
     * @param _subInvoiceIds The array of sub-invoice IDs to process.
     * @param _paymentToken The token address (address(0) for native ETH).
     * @param _tokenUsdPrice The oracle USD price per token unit (8 decimals), fetched once by the caller.
     * @param _decimals The token's decimal precision.
     * @return amountPaid Total token amount paid across all processed sub-invoices.
     */
    function _paySubInvoices(
        uint216[] memory _subInvoiceIds,
        address _paymentToken,
        uint256 _tokenUsdPrice,
        uint8 _decimals
    ) internal returns (uint256 amountPaid) {
        for (uint256 j = 0; j < _subInvoiceIds.length; j++) {
            uint216 subInvoiceId = _subInvoiceIds[j];
            Invoice memory i = invoices[subInvoiceId];
            if (i.state == CREATED) {
                uint256 price = i.price.mulDiv(10 ** _decimals, _tokenUsdPrice);
                if (price == 0) {
                    i.state = CANCELED;
                    continue;
                }
                amountPaid += _pay(i, subInvoiceId, _paymentToken, price);
                invoices[subInvoiceId] = i;
            }
        }
    }

    /**
     * @notice Creates a new invoice and stores it in contract state.
     * @param _nonce The unique ID to assign to the new invoice.
     * @param _metaInvoiceId The associated meta-invoice ID, or 0 for standalone invoices.
     * @param _param The parameters required to create the invoice.
     * @return invoiceId The keccak256 hash representing the invoice ID.
     */
    function _createInvoice(uint216 _nonce, uint216 _metaInvoiceId, InvoiceCreationParam memory _param)
        internal
        returns (uint216 invoiceId)
    {
        if (_param.seller == address(0)) revert InvalidSeller();
        if (_param.price == 0) revert PriceCannotBeZero();
        if (_param.price < minimumPrice) revert PriceIsTooLow();
        Invoice memory i;
        i.seller = _param.seller;
        i.price = _param.price;
        i.createdAt = (block.timestamp).toUint40();
        i.metaInvoiceId = _metaInvoiceId;
        i.state = CREATED;
        i.invoiceNonce = _nonce;
        i.expiresAt = (ppStorage.getPaymentValidityDuration() + block.timestamp).toUint40();
        i.escrowHoldPeriod = _param.escrowHoldPeriod;

        invoiceId = (uint256(keccak256(abi.encode(_param.invoiceId))) & ((1 << 216) - 1)).toUint216();

        if (invoices[invoiceId].createdAt != 0) revert InvoiceAlreadyExists();

        invoices[invoiceId] = i;

        emit InvoiceCreated(invoiceId, i);
        return invoiceId;
    }

    /**
     * @notice Calculates a portion of an amount using basis points.
     * @param _amount The base amount to apply the percentage to.
     * @param _basisPoints The percentage value in basis points (1 BPS = 0.01%).
     * @return value The resulting value after applying basis points.
     */
    function _applyBasisPoints(uint256 _amount, uint256 _basisPoints) internal pure returns (uint256 value) {
        value = (_amount * _basisPoints) / BASIS_POINTS;
    }

    /**
     * @notice Distributes the remaining invoice balance between the seller and the buyer.
     * @dev Transfers the buyer's refund (if any) and the seller's payout based on the given share.
     * @param _i The invoice containing payment and escrow details.
     * @param _sellerShare The portion of the invoice balance (in basis points) to be sent to the seller.
     * @return sellerReceivingValue The amount sent to the seller.
     * @return buyerReceivingValue The amount refunded to the buyer (zero if sellerShare == 10000).
     */
    function _distributeFunds(Invoice memory _i, uint256 _sellerShare)
        internal
        returns (uint256 sellerReceivingValue, uint256 buyerReceivingValue)
    {
        if (_sellerShare != BASIS_POINTS) {
            buyerReceivingValue = _applyBasisPoints(_i.balance, BASIS_POINTS - _sellerShare);

            if (!IEscrow(_i.escrow).withdraw(_i.paymentToken, _i.buyer, buyerReceivingValue)) {
                revert EscrowWithdrawFailed();
            }
        }

        sellerReceivingValue = _i.balance - buyerReceivingValue;
        if (sellerReceivingValue != 0) {
            sellerReceivingValue = _processSellerPayout(_i, sellerReceivingValue, true);
        }
    }

    /**
     * @notice Distributes the seller's payout from the escrow, applying platform fees.
     * @param _i The invoice data containing escrow and recipient info.
     * @param _sellerReceivingValue The gross amount owed to the seller before fees.
     * @param _revertOnFail If true, reverts on failed transfer (manual paths). If false, emits
     *        TransferFailed instead (automation path, to prevent head-of-line DoS).
     * @return sellerNetAmount The amount the seller receives after fees are deducted.
     */
    function _processSellerPayout(Invoice memory _i, uint256 _sellerReceivingValue, bool _revertOnFail)
        internal
        returns (uint256 sellerNetAmount)
    {
        uint256 fee = _applyBasisPoints(_sellerReceivingValue, ppStorage.getFeeRate());
        sellerNetAmount = _sellerReceivingValue - fee;

        if (!IEscrow(_i.escrow).withdraw(_i.paymentToken, _i.seller, sellerNetAmount)) {
            if (_revertOnFail) revert EscrowWithdrawFailed();
        }

        if (!IEscrow(_i.escrow).withdraw(_i.paymentToken, ppStorage.getFeeReceiver(), fee)) {
            if (_revertOnFail) revert EscrowWithdrawFailed();
        }

        return sellerNetAmount;
    }

    /**
     * @notice Computes a deterministic ID for a meta-invoice based on the sub-invoice range and a salt.
     * @dev The hash is based on the contract address, the sub-invoice ID range [lower, upper], and a salt
     *      (e.g., a sequence number or counter). This prevents collisions when multiple meta-invoices share
     *      the same buyer and invoice range.
     * @param _lower The starting sub-invoice ID in the group.
     * @param _upper The ending sub-invoice ID in the group.
     * @param _salt A user-provided or system-generated value (e.g., nextMetaInvoiceNonce) to ensure uniqueness.
     * @return metaInvoiceId A keccak256 hash representing the deterministic meta-invoice order ID.
     */
    function _computeMetaInvoiceId(uint256 _lower, uint256 _upper, uint256 _salt)
        internal
        view
        returns (uint216 metaInvoiceId)
    {
        metaInvoiceId =
            (uint256(keccak256(abi.encode(_lower, _upper, _salt, address(this)))) & ((1 << 216) - 1)).toUint216();
    }

    /**
     * @notice Returns the decimal precision of an ERC20 token by calling its `decimals()` function.
     * @dev Falls back to `DEFAULT_DECIMAL` (18) if the call fails or the token does not implement `decimals()`.
     * @param _token The address of the ERC20 token.
     * @return tokenDecimals The number of decimals the token uses.
     */
    function _getDecimals(address _token) public view returns (uint8 tokenDecimals) {
        (bool ok, bytes memory data) = _token.staticcall(abi.encodeWithSignature("decimals()"));

        if (ok && data.length > 0) {
            return abi.decode(data, (uint8));
        }

        return DEFAULT_DECIMAL;
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
     * @notice Ensures that the caller is the owner of the PaymentProcessorStorage contract.
     * @dev Reverts with `NotAuthorized` if `msg.sender` is not the storage owner.
     */
    function _onlyOwner() internal view {
        if (msg.sender != _owner()) revert NotAuthorized();
    }

    /**
     * @notice Ensures that the caller is the registered marketplace address.
     * @dev Reverts with `NotAuthorized` if `msg.sender` is not equal to
     *      the marketplace address stored in `ppStorage`.
     */
    function _onlyMarketplace() internal view {
        if (msg.sender != ppStorage.getMarketplace()) revert NotAuthorized();
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getInvoice(uint216 _invoiceId) external view returns (Invoice memory i) {
        return invoices[_invoiceId];
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getMetaInvoice(uint216 _metaInvoiceId) public view returns (MetaInvoice memory m) {
        return metaInvoices[_metaInvoiceId];
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function totalUniqueInvoiceCreated() external view returns (uint216 totalInvoices) {
        return ppStorage.totalInvoiceCreated();
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function totalMetaInvoiceCreated() external view returns (uint216 totalMetaInvoices) {
        return nextMetaInvoiceNonce - 1;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getMinimumPrice() external view returns (uint256 currentMinimumPrice) {
        return minimumPrice;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getNextInvoiceNonce() external view returns (uint216 nextInvoiceNonce) {
        return ppStorage.getNextInvoiceNonce();
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getNextMetaInvoiceNonce() external view returns (uint216 nextMetaInvoiceId) {
        return nextMetaInvoiceNonce;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getItems() external view returns (uint216[] memory items) {
        return heap.getItems();
    }
}
