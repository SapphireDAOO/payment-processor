// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EscrowFactory } from "./EscrowFactory.sol";
import { IEscrow } from "./interface/IEscrow.sol";
import { IOracleManager } from "./interface/IOracleManager.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";
import { IIntermediatedPaymentProcessor } from "./interface/IIntermediatedPaymentProcessor.sol";

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";

import { FeeAuthorizationLib } from "./libraries/FeeAuthorizationLib.sol";

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
    BASIS_POINTS,
    DEFAULT_DECIMAL,
    DEFAULT_MINIMUM_INVOICE_PRICE
} from "./constants/Intermediated.sol";

/**
 * @title IntermediatedPaymentProcessor
 * @notice Handles the creation, payment, and lifecycle management of single and meta invoices with escrow logic.
 * @dev Releases and refunds are triggered manually by the Intermediated Platforms Operator; there is no
 *      automated upkeep path. Inherits interfaces for payment processing and escrow deployment.
 */
contract IntermediatedPaymentProcessor is IIntermediatedPaymentProcessor, EscrowFactory, ReentrancyGuard {
    using { SafeTransferLib.safeTransferETH, SafeTransferLib.safeTransferFrom } for address;
    using { SafeCastLib.toUint16, SafeCastLib.toUint40, SafeCastLib.toUint216 } for uint256;
    using { SafeCastLib.toUint256 } for int256;
    using { FixedPointMathLib.mulDiv, FixedPointMathLib.mulDivUp } for uint256;

    /// @notice Minimum USD price (8 decimals) an invoice must meet to be accepted by the processor.
    uint256 private minimumPrice;

    /// @notice Reference to the external Payment Processor storage contract.
    IPaymentProcessorStorage public immutable ppStorage;

    /// @notice OracleManager used to convert USD-denominated invoice prices into payment-token amounts.
    IOracleManager public oracle;

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
     * @notice Tokens each invoice accepts as payment.
     * @dev Fixed at invoice creation and never widened afterwards, so a buyer can only pay in a
     *      currency the operator listed for that invoice. `address(0)` means native currency.
     */
    mapping(uint216 invoiceId => mapping(address paymentToken => bool allowed)) private allowedPaymentTokens;

    /**
     * @notice Restricts function access to the authorized Intermediated Platforms Operator.
     * @dev Reverts with NotAuthorized() if the caller is not the Intermediated Platforms Operator.
     */
    modifier onlyIntermediatedPlatformsOperator() {
        _onlyIntermediatedPlatformsOperator();
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
     * @notice Blocks the call while the system is paused.
     * @dev Reverts with ContractPaused. `cancelInvoice` is exempt: it moves no funds.
     */
    modifier whenNotPaused() {
        _whenNotPaused();
        _;
    }

    /**
     * @notice Initializes the IntermediatedPaymentProcessor contract with core configuration.
     * @param _paymentProcessorStorageAddress The address of the shared payment processor storage contract.
     * @param _oracle The address of the deployed OracleManager contract used for token price conversions.
     */
    constructor(address _paymentProcessorStorageAddress, address _oracle) {
        ppStorage = IPaymentProcessorStorage(_paymentProcessorStorageAddress);
        oracle = IOracleManager(_oracle);
        nextMetaInvoiceNonce = 1;
        minimumPrice = DEFAULT_MINIMUM_INVOICE_PRICE;
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function createSingleInvoice(InvoiceCreationParam memory _param)
        external
        onlyIntermediatedPlatformsOperator
        whenNotPaused
        returns (uint216 invoiceId)
    {
        return _createInvoice(ppStorage.updateInvoiceNonce(1), 0, _param);
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function createMetaInvoice(InvoiceCreationParam[] memory _param)
        external
        onlyIntermediatedPlatformsOperator
        whenNotPaused
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
            uint216 invoiceId = _createInvoice(firstInvoiceNonce + j, metaInvoiceId, _param[j]);
            metaInvoices[metaInvoiceId].subInvoiceIds.push(invoiceId);
        }

        metaInvoices[metaInvoiceId].price = totalPrice;
        nextMetaInvoiceNonce++;
        ppStorage.updateInvoiceNonce(length.toUint216());

        emit MetaInvoiceCreated(metaInvoiceId, totalPrice);

        return metaInvoiceId;
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function payInvoice(uint216 _invoiceId, address _paymentToken, address _feeReceiver, bytes memory _data)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (!allowedPaymentTokens[_invoiceId][_paymentToken]) {
            revert PaymentTokenNotAllowed(_invoiceId, _paymentToken);
        }

        Invoice memory i = invoices[_invoiceId];
        uint256 priceInToken = getTokenValueFromUsd(_paymentToken, i.price);

        _validateFeeAuthorization(_invoiceId, _feeReceiver, _data);

        if (_paymentToken == address(0)) {
            if (msg.value < priceInToken) revert InvalidNativePayment();
        } else {
            if (msg.value != 0) revert InvalidNativePayment();
        }

        uint256 amountPaid = _pay(i, _invoiceId, _paymentToken, priceInToken, _feeReceiver);
        _refundExtra(priceInToken, amountPaid);

        invoices[_invoiceId] = i;
    }

    /**
     * @notice Pays all sub-invoices in a meta-invoice using native ETH.
     * @dev Caller must send exactly the oracle-converted total. Any dust from integer rounding is refunded.
     * @param _invoiceId The meta-invoice ID to pay.
     */
    function payMetaInvoiceWithValue(uint216 _invoiceId, address[] calldata _feeReceivers, bytes memory _data)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        MetaInvoice memory m = metaInvoices[_invoiceId];
        if (m.price == 0) revert InvoiceDoesNotExist();

        _validateMetaFeeAuthorization(_invoiceId, m.subInvoiceIds.length, _feeReceivers, _data);

        uint256 usdPerToken = _usdPerToken(address(0));
        uint256 priceInToken = m.price.mulDivUp(10 ** DEFAULT_DECIMAL, usdPerToken);

        if (priceInToken != msg.value) revert InvalidMetaInvoicePaymentAmount(msg.value, priceInToken);

        uint256 amountPaid = _paySubInvoices(m.subInvoiceIds, address(0), usdPerToken, DEFAULT_DECIMAL, _feeReceivers);
        if (amountPaid == 0) revert InvalidInvoiceState();

        _refundExtra(priceInToken, amountPaid);
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function payMetaInvoice(
        uint216 _invoiceId,
        address _paymentToken,
        address[] calldata _feeReceivers,
        bytes memory _data
    ) external nonReentrant whenNotPaused {
        MetaInvoice memory m = metaInvoices[_invoiceId];
        if (m.price == 0) revert InvoiceDoesNotExist();

        _validateMetaFeeAuthorization(_invoiceId, m.subInvoiceIds.length, _feeReceivers, _data);

        uint256 usdPerToken = _usdPerToken(_paymentToken);
        uint8 decimals = _getDecimals(_paymentToken);

        _paySubInvoices(m.subInvoiceIds, _paymentToken, usdPerToken, decimals, _feeReceivers);
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function createDispute(uint216 _invoiceId) external onlyIntermediatedPlatformsOperator whenNotPaused {
        Invoice memory i = invoices[_invoiceId];
        if (i.state != PAID) revert InvalidInvoiceState();

        i.state = DISPUTED;
        invoices[_invoiceId] = i;
        emit DisputeCreated(_invoiceId);
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function handleDispute(uint216 _invoiceId, uint8 _resolution, uint256 _sellerShare)
        external
        onlyIntermediatedPlatformsOperator
        whenNotPaused
    {
        Invoice memory i = invoices[_invoiceId];

        if (i.state != DISPUTED) revert InvalidInvoiceState();
        if (_sellerShare > BASIS_POINTS) revert InvalidSellersPayoutShare();
        if (_resolution != DISPUTE_DISMISSED && _resolution != DISPUTE_SETTLED) {
            revert InvalidDisputeResolution();
        }

        i.state = _resolution;
        invoices[_invoiceId] = i;

        if (_resolution == DISPUTE_DISMISSED) {
            emit DisputeDismissed(_invoiceId);
        }

        if (_resolution == DISPUTE_SETTLED) {
            invoices[_invoiceId].balance = 0;
            (uint256 sellerReceivingValue, uint256 buyerReceivingValue, uint256 fee) = _distributeFunds(i, _sellerShare);
            emit DisputeSettled(_invoiceId, sellerReceivingValue, buyerReceivingValue, fee);
        }
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function release(uint216 _invoiceId) external onlyIntermediatedPlatformsOperator whenNotPaused {
        Invoice memory i = invoices[_invoiceId];
        uint8 state = i.state;
        bool isReleasable = (state == PAID || state == DISPUTE_RESOLVED || state == DISPUTE_DISMISSED)
            && block.timestamp >= i.releaseAt;
        if (!isReleasable) revert InvalidInvoiceState();
        uint256 fee = _applyBasisPoints(i.balance, i.feeRate);
        uint256 sellerNetAmount = i.balance - fee;
        IEscrow(i.escrow).withdraw(i.paymentToken, i.seller, sellerNetAmount);

        invoices[_invoiceId].state = RELEASED;
        invoices[_invoiceId].balance = 0;

        address feeReceiver = _feeReceiverFor(i.feeReceiver);
        if (!IEscrow(i.escrow).withdraw(i.paymentToken, feeReceiver, fee)) {
            emit TransferFailed(_invoiceId, feeReceiver, fee);
        }

        emit PaymentReleased(_invoiceId, i.seller, i.paymentToken, sellerNetAmount, fee);
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function refund(uint216 _invoiceId, uint256 _refundShare)
        external
        onlyIntermediatedPlatformsOperator
        whenNotPaused
    {
        Invoice memory i = invoices[_invoiceId];
        if (i.state != PAID) revert InvalidInvoiceState();
        if (_refundShare == 0 || _refundShare > BASIS_POINTS) revert InvalidSellersPayoutShare();

        uint256 amount = _applyBasisPoints(i.balance, _refundShare);

        if (amount > i.balance) revert InsufficientBalance();

        if (_refundShare == BASIS_POINTS) {
            i.state = REFUNDED;
        }

        i.balance -= amount;
        invoices[_invoiceId] = i;

        if (!IEscrow(i.escrow).withdraw(i.paymentToken, i.buyer, amount)) revert EscrowWithdrawFailed();

        emit Refunded(_invoiceId, amount);
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function cancelInvoice(uint216 _invoiceId) public onlyIntermediatedPlatformsOperator {
        Invoice memory i = invoices[_invoiceId];
        if (i.state != CREATED) revert InvalidInvoiceState();
        invoices[_invoiceId].state = CANCELED;
        if (i.metaInvoiceId != 0) {
            metaInvoices[i.metaInvoiceId].price -= i.price;
        }
        emit InvoiceCanceled(_invoiceId);
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function resolveDispute(uint216 _invoiceId) external onlyIntermediatedPlatformsOperator {
        Invoice memory i = invoices[_invoiceId];
        if (i.state != DISPUTED) revert InvalidInvoiceState();
        i.state = DISPUTE_RESOLVED;

        invoices[_invoiceId] = i;
        emit DisputeResolved(_invoiceId);
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function setInvoiceReleaseTime(uint216 _invoiceId, uint256 _holdPeriod) external onlyOwner {
        Invoice memory i = invoices[_invoiceId];

        if (i.state != PAID && i.state != DISPUTE_RESOLVED && i.state != DISPUTE_DISMISSED) {
            revert InvalidInvoiceState();
        }

        i.releaseAt = (block.timestamp + _holdPeriod).toUint40();
        invoices[_invoiceId] = i;

        emit UpdateReleaseTime(_invoiceId, _holdPeriod);
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function setMinimumPrice(uint256 _newMinimumPrice) external onlyOwner {
        minimumPrice = _newMinimumPrice;
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert InvalidOracle();
        emit OracleUpdated(address(oracle), _oracle);
        oracle = IOracleManager(_oracle);
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
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
     * @notice Shared base for all invoice payment paths.
     * @dev For native ETH payments, the caller must have already validated `msg.value == _tokenPrice`.
     *      For ERC20 payments, tokens are pulled from the caller via safeTransferFrom.
     * @param _i The invoice memory struct to be updated in-place.
     * @param _invoiceId The ID of the invoice being paid.
     * @param _paymentToken The token address (address(0) for native ETH).
     * @param _tokenPrice The oracle-converted price in the payment token's units.
     */
    function _pay(
        Invoice memory _i,
        uint216 _invoiceId,
        address _paymentToken,
        uint256 _tokenPrice,
        address _feeReceiver
    ) internal returns (uint256 amountPaid) {
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
        _i.feeReceiver = _feeReceiver;

        if (_paymentToken != address(0)) {
            _paymentToken.safeTransferFrom(msg.sender, escrowAddress, _tokenPrice);
        }

        if (_i.releaseAt == 0) {
            _i.releaseAt = (block.timestamp + _i.escrowHoldPeriod).toUint40();
        }

        emit InvoicePaid(_invoiceId, _paymentToken, escrowAddress, _tokenPrice, _i.releaseAt, _feeReceiver);
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
        uint8 _decimals,
        address[] calldata _feeReceivers
    ) internal returns (uint256 amountPaid) {
        for (uint256 j = 0; j < _subInvoiceIds.length; j++) {
            uint216 subInvoiceId = _subInvoiceIds[j];
            Invoice memory i = invoices[subInvoiceId];
            if (i.state == CREATED) {
                if (!allowedPaymentTokens[subInvoiceId][_paymentToken]) {
                    revert PaymentTokenNotAllowed(subInvoiceId, _paymentToken);
                }

                uint256 price = i.price.mulDiv(10 ** _decimals, _tokenUsdPrice);
                if (price == 0) continue;

                amountPaid += _pay(i, subInvoiceId, _paymentToken, price, _feeReceivers[j]);
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
        if (_param.escrowHoldPeriod == 0) revert HoldPeriodCanNotBeZero();
        if (_param.paymentTokens.length == 0) revert NoPaymentTokens();
        Invoice memory i;
        i.seller = _param.seller;
        i.price = _param.price;
        i.createdAt = (block.timestamp).toUint40();
        i.metaInvoiceId = _metaInvoiceId;
        i.state = CREATED;
        i.invoiceNonce = _nonce;
        i.feeRate = (ppStorage.getFeeRate()).toUint16();
        i.expiresAt = (ppStorage.getPaymentValidityDuration() + block.timestamp).toUint40();
        i.escrowHoldPeriod = _param.escrowHoldPeriod;

        invoiceId = (uint256(keccak256(abi.encode(_param.invoiceId))) & ((1 << 216) - 1)).toUint216();

        if (invoices[invoiceId].createdAt != 0) revert InvoiceAlreadyExists();

        invoices[invoiceId] = i;

        for (uint256 j = 0; j < _param.paymentTokens.length; j++) {
            if (!oracle.isSupportedToken(_param.paymentTokens[j])) revert UnsupportedToken();
            allowedPaymentTokens[invoiceId][_param.paymentTokens[j]] = true;
        }

        emit InvoiceCreated(invoiceId, i);
        emit PaymentTokensRegistered(invoiceId, _param.paymentTokens);
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
     * @return sellerReceivingValue The net amount sent to the seller, after fees.
     * @return buyerReceivingValue The amount refunded to the buyer (zero if sellerShare == 10000).
     * @return fee The platform fee deducted from the seller's share and sent to the fee receiver.
     */
    function _distributeFunds(Invoice memory _i, uint256 _sellerShare)
        internal
        returns (uint256 sellerReceivingValue, uint256 buyerReceivingValue, uint256 fee)
    {
        if (_sellerShare != BASIS_POINTS) {
            buyerReceivingValue = _applyBasisPoints(_i.balance, BASIS_POINTS - _sellerShare);

            if (!IEscrow(_i.escrow).withdraw(_i.paymentToken, _i.buyer, buyerReceivingValue)) {
                revert EscrowWithdrawFailed();
            }
        }

        sellerReceivingValue = _i.balance - buyerReceivingValue;
        if (sellerReceivingValue != 0) {
            (sellerReceivingValue, fee) = _processSellerPayout(_i, sellerReceivingValue, true);
        }
    }

    /**
     * @notice Distributes the seller's payout from the escrow, applying platform fees.
     * @param _i The invoice data containing escrow and recipient info.
     * @param _sellerReceivingValue The gross amount owed to the seller before fees.
     * @param _revertOnFail If true, reverts on failed transfer. If false, emits TransferFailed
     *        instead so a single failing recipient cannot block the remaining payout.
     * @return sellerNetAmount The amount the seller receives after fees are deducted.
     * @return fee The platform fee deducted and sent to the fee receiver.
     */
    function _processSellerPayout(Invoice memory _i, uint256 _sellerReceivingValue, bool _revertOnFail)
        internal
        returns (uint256 sellerNetAmount, uint256 fee)
    {
        fee = _applyBasisPoints(_sellerReceivingValue, _i.feeRate);
        sellerNetAmount = _sellerReceivingValue - fee;

        if (!IEscrow(_i.escrow).withdraw(_i.paymentToken, _i.seller, sellerNetAmount)) {
            if (_revertOnFail) revert EscrowWithdrawFailed();
        }

        if (!IEscrow(_i.escrow).withdraw(_i.paymentToken, _feeReceiverFor(_i.feeReceiver), fee)) {
            if (_revertOnFail) revert EscrowWithdrawFailed();
        }
    }

    /**
     * @notice Reverts unless every fee receiver in a meta-invoice payment was authorized by the fee signer.
     * @dev One signature covers the whole array, so the receivers must be supplied in the same order as
     *      the meta-invoice's sub-invoice IDs and the count must match exactly.
     * @param _metaInvoiceId The meta-invoice being paid.
     * @param _subInvoiceCount How many sub-invoices the meta-invoice holds.
     * @param _feeReceivers The fee receivers supplied by the caller.
     * @param _data The fee signer's ECDSA signature over the authorization digest.
     */
    function _validateMetaFeeAuthorization(
        uint216 _metaInvoiceId,
        uint256 _subInvoiceCount,
        address[] calldata _feeReceivers,
        bytes memory _data
    ) internal view {
        if (_feeReceivers.length != _subInvoiceCount) {
            revert FeeReceiverCountMismatch(_feeReceivers.length, _subInvoiceCount);
        }

        for (uint256 j = 0; j < _feeReceivers.length; j++) {
            if (_feeReceivers[j] == address(0)) revert InvalidFeeReceiver();
        }

        if (!FeeAuthorizationLib.isAuthorized(ppStorage.getFeeSigner(), _metaInvoiceId, _feeReceivers, _data)) {
            revert InvalidFeeAuthorization();
        }
    }

    function _validateFeeAuthorization(uint216 _invoiceId, address _feeReceiver, bytes memory _data) internal view {
        if (_feeReceiver == address(0)) revert InvalidFeeReceiver();
        if (!FeeAuthorizationLib.isAuthorized(ppStorage.getFeeSigner(), _invoiceId, _feeReceiver, _data)) {
            revert InvalidFeeAuthorization();
        }
    }

    /**
     * @notice Resolves the address that should receive an invoice's platform fee.
     * @dev Every payment path now records a receiver, so the fallback only covers invoices paid before
     *      per-invoice receivers existed.
     * @param _feeReceiver The fee receiver stored on the invoice; zero when it has none.
     * @return feeReceiver The address to send the fee to.
     */
    function _feeReceiverFor(address _feeReceiver) internal view returns (address feeReceiver) {
        return _feeReceiver == address(0) ? ppStorage.getFeeReceiver() : _feeReceiver;
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
     * @notice Returns the part of a native payment that was not applied to the invoice(s).
     * @dev Useful because if the quoted price from the off-chain call (usually the frontend) is slightly
     *      higher than the on-chain quote, the transaction shouldn't revert; the extra amount is refunded
     *      instead. This is a precautionary measure — situations like this have little chance of occurring.
     * @param _priceInToken The quoted price, in the native token.
     * @param _amountPaid The amount actually applied.
     */
    function _refundExtra(uint256 _priceInToken, uint256 _amountPaid) internal {
        uint256 refundableAmount = _priceInToken - _amountPaid;
        if (refundableAmount > 0) (msg.sender).safeTransferETH(refundableAmount);
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

    /// @dev Reverts with ContractPaused while the storage contract reports a pause.
    function _whenNotPaused() internal view {
        if (ppStorage.isPaused()) revert ContractPaused();
    }

    /**
     * @notice Ensures that the caller is the registered Intermediated Platforms Operator.
     * @dev Reverts with `NotAuthorized` if `msg.sender` is not equal to
     *      the Intermediated Platforms Operator address stored in `ppStorage`.
     */
    function _onlyIntermediatedPlatformsOperator() internal view {
        if (msg.sender != ppStorage.getIntermediatedPlatformsOperator()) revert NotAuthorized();
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function getInvoice(uint216 _invoiceId) external view returns (Invoice memory i) {
        return invoices[_invoiceId];
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function isPaymentTokenAllowed(uint216 _invoiceId, address _paymentToken) external view returns (bool allowed) {
        return allowedPaymentTokens[_invoiceId][_paymentToken];
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function getMetaInvoice(uint216 _metaInvoiceId) public view returns (MetaInvoice memory m) {
        return metaInvoices[_metaInvoiceId];
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function totalUniqueInvoiceCreated() external view returns (uint216 totalInvoices) {
        return ppStorage.totalInvoiceCreated();
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function totalMetaInvoiceCreated() external view returns (uint216 totalMetaInvoices) {
        return nextMetaInvoiceNonce - 1;
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function getMinimumPrice() external view returns (uint256 currentMinimumPrice) {
        return minimumPrice;
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function getNextInvoiceNonce() external view returns (uint216 nextInvoiceNonce) {
        return ppStorage.getNextInvoiceNonce();
    }

    /// @inheritdoc IIntermediatedPaymentProcessor
    function getNextMetaInvoiceNonce() external view returns (uint216 nextMetaInvoiceId) {
        return nextMetaInvoiceNonce;
    }
}
