// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EscrowFactory } from "./EscrowFactory.sol";
import { AggregatorV3Interface } from "./interface/AggregatorV3Interface.sol";

import { IERC20 } from "./interface/IERC20.sol";
import { IEscrow } from "./interface/IEscrow.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";
import { IAdvancedPaymentProcessor } from "./interface/IAdvancedPaymentProcessor.sol";
import { AutomationCompatibleInterface } from "./interface/AutomationCompatibleInterface.sol";

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TaskQueueLib } from "src/libraries/TaskQueueLib.sol";

/**
 * @title AdvancedPaymentProcessor
 * @notice Handles the creation, payment, and lifecycle management of single and meta invoices with escrow logic.
 * @dev Inherits interfaces for payment processing, Chainlink Automation compatibility, and escrow deployment.
 */
contract AdvancedPaymentProcessor is IAdvancedPaymentProcessor, AutomationCompatibleInterface, EscrowFactory {
    using TaskQueueLib for TaskQueueLib.Heap;

    using { SafeTransferLib.safeTransferFrom } for address;
    using { SafeCastLib.toUint40, SafeCastLib.toUint216 } for uint256;
    using { SafeCastLib.toUint256 } for int256;
    using { FixedPointMathLib.mulDiv } for uint256;

    /// @notice Internal min-heap used to efficiently manage scheduled invoice tasks by release time.
    TaskQueueLib.Heap private heap;

    /// @notice Address of the forwarder contract responsible for calling performUpkeep.
    address private forwarder;

    /// @notice Reference to the external Payment Processor storage contract.
    IPaymentProcessorStorage public ppStorage;

    /// @notice The next available meta-invoice ID to be assigned.
    uint216 private nextMetaInvoiceNonce;

    /// @notice Invoice has been created but no payment has been made yet.
    uint8 public constant CREATED = 1;

    /// @notice Invoice has been paid by the buyer.
    uint8 public constant PAID = CREATED + 1;

    /// @notice Invoice has been refunded to the buyer (e.g., after expiration or rejection).
    uint8 public constant REFUNDED = PAID + 1;

    /// @notice Seller has canceled the invoice before acceptance.
    uint8 public constant CANCELED = REFUNDED + 1;

    /// @notice Buyer has raised a dispute after acceptance.
    uint8 public constant DISPUTED = CANCELED + 1;

    /// @notice Dispute has been resolved in full favor of one party.
    uint8 public constant DISPUTE_RESOLVED = DISPUTED + 1;

    /// @notice Dispute has been dismissed without changes to payouts.
    uint8 public constant DISPUTE_DISMISSED = DISPUTE_RESOLVED + 1;

    /// @notice Dispute has been settled with a split payout.
    uint8 public constant DISPUTE_SETTLED = DISPUTE_DISMISSED + 1;

    /// @notice Payment has been released to the seller after acceptance or resolution.
    uint8 public constant RELEASED = DISPUTE_SETTLED + 1;

    /// @notice Total basis points used for percentage calculations. 10_000 = 100%.
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Default number of decimals used for internal fixed-point arithmetic (e.g., 1e18 = 1.0)
    uint8 public constant DEFAULT_DECIMAL = 18;

    uint256 public constant STALE_THRESHOLD = 1 hours;

    /**
     * @notice Mapping from unique invoice ID to its invoice data.
     * @dev Used for standalone invoices (not part of a meta-invoice).
     */
    mapping(uint216 invoiceId => Invoice data) private invoice;

    /**
     * @notice Mapping of payment tokens to their Chainlink price feed aggregator.
     * @dev Used for converting USD prices to the appropriate payment token amounts.
     */
    mapping(address token => address aggregator) private priceFeed;

    /**
     * @notice Mapping from meta-invoice ID to its aggregate meta-invoice data.
     * @dev Stores metadata for grouped payments consisting of multiple sub-invoices.
     *      Each MetaInvoice contains the total price and all associated sub-invoice IDs.
     */
    mapping(uint216 metaInvoiceId => MetaInvoice invoice) private metaInvoice;

    /**
     *  @notice Maps task or invoice ID to its 1-based index position in the heap.
     * @dev A value of 0 means the task is not present in the heap
     */
    mapping(uint216 invoiceId => uint256 idx) private index;

    /**
     * @notice Restricts function access to the authorized marketplace address.
     * @dev Reverts with NotAuthorized() if the caller is not the marketplace.
     */
    modifier onlyMarketplace() {
        _onlyMarketplace();
        _;
    }

    /**
     * @notice Initializes the AdvancedPaymentProcessor contract with core configuration.
     * @param _paymentProcessorStorageAddress The address of the shared payment processor storage contract.
     */
    constructor(address _paymentProcessorStorageAddress) {
        ppStorage = IPaymentProcessorStorage(_paymentProcessorStorageAddress);
        nextMetaInvoiceNonce = 1;
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
        uint256 totalPrice;
        uint216 firstInvoiceNonce = ppStorage.getNextInvoiceNonce();
        uint256 length = _param.length;
        uint256 lastInvoiceNonce = length + firstInvoiceNonce - 1;

        metaInvoiceId = _computeMetaInvoiceId(firstInvoiceNonce, lastInvoiceNonce, nextMetaInvoiceNonce);
        if (metaInvoice[metaInvoiceId].price != 0) revert MetaInvoiceAlreadyExists();

        for (uint216 i = 0; i < length; i++) {
            totalPrice += _param[i].price;
            metaInvoice[metaInvoiceId].subInvoiceIds
                .push(_createInvoice(firstInvoiceNonce + i, metaInvoiceId, _param[i]));
        }

        metaInvoice[metaInvoiceId].price = totalPrice;
        ppStorage.updateInvoiceNonce(length.toUint216());
        nextMetaInvoiceNonce++;

        emit MetaInvoiceCreated(metaInvoiceId, totalPrice);

        return metaInvoiceId;
    }

    /**
     * @notice Pays a single invoice or a meta invoice depending on the flag.
     * @param _invoiceId The invoice or meta-invoice ID to pay.
     * @param _paymentToken The payment token address (use address(0) for native token).
     * @param _single True to pay a single invoice; false to pay a meta invoice.
     */
    function pay(uint216 _invoiceId, address _paymentToken, bool _single) external payable {
        if (_single) {
            this.paySingleInvoice(_invoiceId, _paymentToken);
        } else {
            this.payMetaInvoice(_invoiceId, _paymentToken);
        }
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function paySingleInvoice(uint216 _invoiceId, address _paymentToken) external payable {
        if (address(priceFeed[_paymentToken]) == address(0)) {
            revert InvalidPaymentToken();
        }

        Invoice memory inv = invoice[_invoiceId];
        _invoicePayment(inv, _invoiceId, _paymentToken, msg.value);
        invoice[_invoiceId] = inv;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function payMetaInvoice(uint216 _invoiceId, address _paymentToken) external payable {
        if (address(priceFeed[_paymentToken]) == address(0)) {
            revert InvalidPaymentToken();
        }
        MetaInvoice memory metaInv = metaInvoice[_invoiceId];

        if (metaInv.price == 0) revert InvoiceDoesNotExist();

        uint216[] memory subInvoiceIds = metaInvoice[_invoiceId].subInvoiceIds;

        bool done;

        for (uint256 i = 0; i < subInvoiceIds.length; i++) {
            uint216 subInvoiceId = subInvoiceIds[i];
            Invoice memory inv = invoice[subInvoiceId];

            if (inv.state != CREATED) continue;
            uint256 invPrice = getTokenValueFromUsd(_paymentToken, inv.price);

            uint256 value = _paymentToken == address(0) ? invPrice : 0;
            _invoicePayment(inv, subInvoiceId, _paymentToken, value);

            invoice[subInvoiceId] = inv;
            if (i == subInvoiceIds.length - 1) done = true;
        }

        if (!done) revert InvalidInvoiceState();
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function createDispute(uint216 _invoiceId) external onlyMarketplace {
        Invoice memory inv = invoice[_invoiceId];
        if (inv.state != PAID) revert InvalidInvoiceState();

        inv.state = DISPUTED;
        invoice[_invoiceId] = inv;
        heap.removeAt(index[_invoiceId] - 1, index);
        emit DisputeCreated(_invoiceId);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function handleDispute(uint216 _invoiceId, uint8 _resolution, uint256 _sellerShare) external onlyMarketplace {
        Invoice memory inv = invoice[_invoiceId];

        if (inv.state != DISPUTED) revert InvalidInvoiceState();
        if (_sellerShare > BASIS_POINTS) revert InvalidSellersPayoutShare();
        if (_resolution != DISPUTE_DISMISSED && _resolution != DISPUTE_SETTLED) {
            revert InvalidDisputeResolution();
        }

        inv.state = _resolution;
        invoice[_invoiceId] = inv;

        if (_resolution == DISPUTE_DISMISSED) {
            heap.insert(_invoiceId, inv.releaseAt, index);
            emit DisputeDismissed(_invoiceId);
        }

        if (_resolution == DISPUTE_SETTLED) {
            (uint256 sellerReceivingValue, uint256 buyerReceivingValue) = _distributeFunds(inv, _sellerShare);
            emit DisputeSettled(_invoiceId, sellerReceivingValue, buyerReceivingValue);
        }
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function release(uint216 _invoiceId) external onlyMarketplace {
        if (_release(_invoiceId) != TaskQueueLib.SUCCESSFUL) revert InvalidInvoiceState();
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function refund(uint216 _invoiceId, uint256 _refundShare) external onlyMarketplace {
        Invoice memory inv = invoice[_invoiceId];
        if (inv.state != PAID) revert InvalidInvoiceState();

        uint256 amount = _applyBasisPoints(inv.balance, _refundShare);
        if (amount > inv.balance) revert InsufficientBalance();

        if (_refundShare == BASIS_POINTS) {
            heap.removeAt(index[_invoiceId] - 1, index);
        }

        inv.balance -= amount;
        invoice[_invoiceId] = inv;

        IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, amount);
        emit Refunded(_invoiceId, amount);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function cancelInvoice(uint216 _invoiceId) public onlyMarketplace {
        if (invoice[_invoiceId].state != CREATED) revert InvalidInvoiceState();
        invoice[_invoiceId].state = CANCELED;
        emit InvoiceCanceled(_invoiceId);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function resolveDispute(uint216 _invoiceId) external onlyMarketplace {
        Invoice memory inv = invoice[_invoiceId];
        if (inv.state != DISPUTED) revert InvalidInvoiceState();
        inv.state = DISPUTE_RESOLVED;
        heap.insert(_invoiceId, inv.releaseAt, index);

        invoice[_invoiceId] = inv;
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

        uint256 gasThresold = ppStorage.getGasThreshold();
        heap.processDueTask(_release, gasThresold);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function setPriceFeed(address _token, address _aggregator) external {
        if (msg.sender != _owner()) {
            revert NotAuthorized();
        }
        priceFeed[_token] = _aggregator;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function setInvoiceReleaseTime(uint216 _invoiceId, uint256 _holdPeriod) external {
        if (msg.sender != _owner()) revert NotAuthorized();
        Invoice memory inv = invoice[_invoiceId];
        if (inv.state != PAID) revert InvalidInvoiceState();

        inv.releaseAt = (block.timestamp + _holdPeriod).toUint40();
        invoice[_invoiceId] = inv;

        heap.reschedule(_invoiceId, inv.releaseAt, index);

        emit UpdateReleaseTime(_invoiceId, _holdPeriod);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function setForwarderAddress(address _forwarderAddress) external {
        if (msg.sender != _owner()) revert NotAuthorized();
        forwarder = _forwarderAddress;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getForwarder() external view returns (address forwarderAddress) {
        return forwarder;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getTokenValueFromUsd(address _paymentToken, uint256 _usdAmount) public view returns (uint256 tokenValue) {
        address aggregator = priceFeed[_paymentToken];
        if (aggregator == address(0)) revert UnsupportedToken();
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(aggregator).latestRoundData();

        // check for stale data
        if (block.timestamp > updatedAt + STALE_THRESHOLD) revert StalePriceFeed();

        uint256 usdPerToken = answer.toUint256(); // 8 decimals from Chainlink

        uint8 tokenDecimals = _paymentToken == address(0) ? DEFAULT_DECIMAL : IERC20(_paymentToken).decimals();

        tokenValue = _usdAmount.mulDiv(10 ** tokenDecimals, usdPerToken);
    }

    /**
     * @dev Checks if an invoice state is eligible for release.
     * @return isReleasable True if the invoice can be released.
     */
    function _isReleasable(Invoice memory _inv) internal view returns (bool isReleasable) {
        isReleasable = (_inv.state == PAID || _inv.state == DISPUTE_RESOLVED || _inv.state == DISPUTE_DISMISSED)
            && block.timestamp >= _inv.releaseAt;
    }

    /**
     * @notice Attempts to release the payment for a given invoice.
     * @dev Performs validation checks before releasing. If successful, updates invoice state,
     *      removes it from the heap, processes seller payout, and emits a PaymentReleased event.
     * @param _invoiceId The ID of the invoice to release.
     * @return status The release status code (SUCCESSFUL, ERROR, or NOT_ELIGIBLE_FOR_RELEASE).
     */
    function _release(uint216 _invoiceId) internal returns (uint256 status) {
        Invoice memory inv = invoice[_invoiceId];
        if (!_isReleasable(inv)) return TaskQueueLib.NOT_ELIGIBLE_FOR_RELEASE;

        uint256 pos = index[_invoiceId];
        if (pos == 0 || pos > heap.data.length) return TaskQueueLib.ERROR;

        invoice[_invoiceId].state = RELEASED;
        invoice[_invoiceId].balance = 0;

        heap.removeAt(pos - 1, index);
        uint256 sellerNetAmount = _processSellerPayout(inv, inv.balance);
        emit PaymentReleased(_invoiceId, sellerNetAmount);
        return TaskQueueLib.SUCCESSFUL;
    }

    /**
     * @notice Handles payment for an invoice, performs validation, and initializes escrow.
     * @param _inv The invoice to be paid.
     * @param _invoiceId The key of the invoice being paid.
     * @param _paymentToken The address of the payment token (use address(0) for the native token).
     *  @param _value The amount of native token sent with the transaction.
     *
     * @dev
     * - Converts the USD price to payment token amount using Chainlink oracles.
     * - Validates invoice state, sender, and expiration.
     * - Creates an escrow contract and updates the invoice with payment info.
     * - Transfers tokens to escrow if the payment is in ERC20.
     */
    function _invoicePayment(Invoice memory _inv, uint216 _invoiceId, address _paymentToken, uint256 _value) internal {
        if (msg.sender == _inv.seller) revert BuyerCannotBeSeller();
        if (_inv.state != CREATED) revert InvalidInvoiceState();

        uint256 price = getTokenValueFromUsd(_paymentToken, _inv.price);
        bool isNative = _paymentToken == address(0);

        if (isNative && _value != price) revert InvalidNativePayment();

        address escrowAddress = _create(
            EscrowCreationParams({
                seller: _inv.seller,
                buyer: msg.sender,
                invoiceId: _invoiceId,
                value: isNative ? _value : 0,
                paymentToken: _paymentToken
            })
        );

        _inv.buyer = msg.sender;
        _inv.state = PAID;
        _inv.escrow = escrowAddress;
        _inv.paidAt = (block.timestamp).toUint40();
        _inv.balance = price;
        _inv.amountPaid = price;

        if (_inv.releaseAt == 0) {
            _inv.releaseAt = (block.timestamp + ppStorage.getDefaultHoldPeriod()).toUint40();
            heap.insert(_invoiceId, _inv.releaseAt, index);
        }

        if (!isNative) {
            _inv.paymentToken = _paymentToken;
            _paymentToken.safeTransferFrom(msg.sender, escrowAddress, price);
        }

        emit InvoicePaid(_invoiceId, _paymentToken, escrowAddress, price);
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
        if (_param.price == 0) revert PriceCannotBeZero();
        // make the minimum price dynamic
        if (_param.price < 1e8) revert PriceIsTooLow();
        Invoice memory inv;
        inv.seller = _param.seller;
        inv.price = _param.price;
        inv.createdAt = (block.timestamp).toUint40();
        inv.metaInvoiceId = _metaInvoiceId;
        inv.state = CREATED;
        inv.invoiceNonce = _nonce;

        invoiceId = (uint256(keccak256(abi.encode(_param.invoiceId))) & ((1 << 216) - 1)).toUint216();

        if (invoice[invoiceId].createdAt != 0) revert InvoiceAlreadyExists();

        invoice[invoiceId] = inv;

        emit InvoiceCreated(invoiceId, inv);
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
     *      The refund is only processed if the seller is not entitled to the full balance.
     * @param _inv The invoice containing payment and escrow details.
     * @param _sellerShare The portion of the invoice balance (in basis points) to be sent to the seller.
     * @return sellerReceivingValue The amount sent to the seller.
     * @return buyerReceivingValue The amount refunded to the buyer (zero if sellerShare == 10000).
     */
    function _distributeFunds(Invoice memory _inv, uint256 _sellerShare)
        internal
        returns (uint256 sellerReceivingValue, uint256 buyerReceivingValue)
    {
        sellerReceivingValue = _applyBasisPoints(_inv.balance, _sellerShare);
        if (_sellerShare != BASIS_POINTS) {
            buyerReceivingValue = _applyBasisPoints(_inv.balance, BASIS_POINTS - _sellerShare);
            IEscrow(_inv.escrow).withdraw(_inv.paymentToken, _inv.buyer, buyerReceivingValue);
        }

        _processSellerPayout(_inv, sellerReceivingValue);
        return (sellerReceivingValue, buyerReceivingValue);
    }

    /**
     * @notice Distributes the seller's payout from the escrow, applying platform fees.
     * @param _inv The invoice data containing escrow and recipient info.
     * @param _sellerReceivingValue The gross amount owed to the seller before fees.
     * @return sellerNetAmount The amount the seller receives after fees are deducted.
     */
    function _processSellerPayout(Invoice memory _inv, uint256 _sellerReceivingValue)
        internal
        returns (uint256 sellerNetAmount)
    {
        uint256 fee = _applyBasisPoints(_sellerReceivingValue, ppStorage.getFeeRate());
        sellerNetAmount = _sellerReceivingValue - fee;
        IEscrow(_inv.escrow).withdraw(_inv.paymentToken, _inv.seller, sellerNetAmount);

        IEscrow(_inv.escrow).withdraw(_inv.paymentToken, ppStorage.getFeeReceiver(), fee);
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
     * @notice Returns the owner of the PaymentProcessorStorage contract.
     * @dev This helper reads the owner directly from the linked PaymentProcessorStorage instance.
     * @return ownerAddress The address that currently owns the PaymentProcessorStorage contract.
     */
    function _owner() internal view returns (address ownerAddress) {
        ownerAddress = PaymentProcessorStorage(address(ppStorage)).owner();
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
    function getInvoice(uint216 _invoiceId) external view returns (Invoice memory invoiceData) {
        return invoice[_invoiceId];
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getMetaInvoice(uint216 _metaInvoiceId) public view returns (MetaInvoice memory metaInvoiceData) {
        return metaInvoice[_metaInvoiceId];
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
