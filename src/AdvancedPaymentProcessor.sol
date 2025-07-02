// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EscrowFactory } from "./EscrowFactory.sol";

import { AggregatorV3Interface } from "./interface/AggregatorV3Interface.sol";

import { IERC20 } from "./interface/IERC20.sol";
import { IEscrow } from "./interface/IEscrow.sol";
import { IPaymentProcessorStorage } from "./interface/IPaymentProcessorStorage.sol";
import { IAdvancedPaymentProcessor } from "./interface/IAdvancedPaymentProcessor.sol";

import { Ownable } from "solady/auth/Ownable.sol";

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

contract AdvancedPaymentProcessor is IAdvancedPaymentProcessor, EscrowFactory, Ownable {
    using { SafeTransferLib.safeTransferFrom } for address;
    using { SafeCastLib.toUint48 } for uint256;
    using { SafeCastLib.toUint256 } for int256;
    using { FixedPointMathLib.mulDiv } for uint256;

    IPaymentProcessorStorage public ppStorage;

    /// @notice The next available meta-invoice ID to be assigned.
    uint256 private nextMetaInvoiceId;

    /// @notice Address authorized to interact with invoice creation and specific management functions.
    address private marketplace;

    /// @notice Chainlink price feed aggregator for the native token.
    address private nativeTokenAggregator;

    /// @notice Invoice has been created but no payment has been made yet.
    uint8 public constant INITIATED = 1;

    /// @notice Invoice has been paid by the buyer.
    uint8 public constant PAID = INITIATED + 1;

    /// @notice Invoice has been refunded to the buyer (e.g., after expiration or rejection).
    uint8 public constant REFUNDED = PAID + 1;

    /// @notice Seller has accepted the paid invoice.
    uint8 public constant ACCEPTED = REFUNDED + 1;

    /// @notice Seller has canceled the invoice before acceptance.
    uint8 public constant CANCELED = ACCEPTED + 1;

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

    /**
     * @notice Mapping from unique invoice ID to its invoice data.
     * @dev Used for standalone invoices (not part of a meta-invoice).
     */
    mapping(bytes32 id => Invoice data) private invoice;

    /**
     * @notice Mapping of payment tokens to their Chainlink price feed aggregator.
     * @dev Used for converting USD prices to the appropriate payment token amounts.
     */
    mapping(address token => address aggregator) private priceFeed;

    /**
     * @notice Maps a unique order ID to its associated order details.
     * @dev Stores metadata including escrow address and sub-invoice ID range
     *      for both single and meta-invoice payments.
     */
    mapping(bytes32 orderId => Order orderInfo) private order;

    /**
     * @notice Mapping from meta-invoice ID to its aggregate meta-invoice data.
     * @dev Stores metadata for grouped payments consisting of multiple sub-invoices.
     *      Each MetaInvoice contains the total price and all associated sub-invoice IDs.
     */
    mapping(bytes32 metaInvoiceId => MetaInvoice) private metaInvoice;

    /**
     * @notice Maps an order ID to a mapping of invoice index to sub-order ID
     * @dev Allows tracking of sub-order IDs associated with each order at specific indices
     */
    mapping(bytes32 => mapping(uint256 index => bytes32)) private orderIdToSubOrderId;

    /**
     * @notice Restricts function access to the authorized marketplace address.
     * @dev Reverts with NotAuthorized() if the caller is not the marketplace.
     */
    modifier onlyMarketplace() {
        if (msg.sender != marketplace) revert NotAuthorized();
        _;
    }
    /**
     * @notice Initializes the AdvancedPaymentProcessor contract with core configuration.
     * @param paymentProcessorStorageAddress The address of the shared payment processor storage contract.
     * @param ownerAddress The address to be set as the contract owner.
     * @param marketplaceAddress The address authorized to manage invoice operations.
     * @param nativeTokenAggregatorAddress The Chainlink aggregator address for the native token (e.g., ETH/USD).
     */

    constructor(
        address paymentProcessorStorageAddress,
        address ownerAddress,
        address marketplaceAddress,
        address nativeTokenAggregatorAddress
    ) {
        ppStorage = IPaymentProcessorStorage(paymentProcessorStorageAddress);
        _initializeOwner(ownerAddress);
        marketplace = marketplaceAddress;
        nativeTokenAggregator = nativeTokenAggregatorAddress;
        nextMetaInvoiceId = 1;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function createSingleInvoice(InvoiceCreationParam memory param) external onlyMarketplace returns (bytes32) {
        (Invoice memory inv, bytes32 orderId) = _createInvoice(ppStorage.updateInvoiceId(1), 0, param);
        emit InvoiceCreated(orderId, inv);
        return orderId;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function createMetaInvoice(InvoiceCreationParam[] memory param) external onlyMarketplace returns (bytes32) {
        uint256 totalPrice;
        uint256 startInvoiceId = ppStorage.getNextInvoiceId();
        uint256 i = 0;
        uint256 length = param.length;
        uint256 upperInvoiceId = length + startInvoiceId - 1;

        bytes32 metaInvoiceOrderId = _computeMetaInvoiceOrderId(startInvoiceId, upperInvoiceId, nextMetaInvoiceId);
        if (metaInvoice[metaInvoiceOrderId].price != 0) revert MetaInvoiceAlreadyExists();

        for (; i < length; i++) {
            totalPrice += param[i].price;
            (Invoice memory inv, bytes32 subOrderId) = _createInvoice(startInvoiceId + i, metaInvoiceOrderId, param[i]);
            bytes32 orderId = _computeOrderId(inv.seller, metaInvoiceOrderId);
            Order memory o = order[orderId];

            orderIdToSubOrderId[orderId][startInvoiceId + i] = subOrderId;

            if (o.escrow == address(0) && o.upper == 0) {
                order[orderId].lower = i;
            }

            order[orderId].upper = startInvoiceId + i;

            inv.orderId = orderId;
            invoice[subOrderId] = inv;
            metaInvoice[metaInvoiceOrderId].subInvoiceIds.push(subOrderId);
            emit InvoiceCreated(subOrderId, inv);
        }

        metaInvoice[metaInvoiceOrderId].price = totalPrice;

        ppStorage.updateInvoiceId(i);

        nextMetaInvoiceId++;

        emit MetaInvoiceCreated(metaInvoiceOrderId);

        return metaInvoiceOrderId;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function paySingleInvoice(bytes32 orderId, address paymentToken) external payable {
        if (paymentToken != address(0) && address(priceFeed[paymentToken]) == address(0)) revert InvalidPaymentToken();

        Invoice memory inv = invoice[orderId];
        _invoicePayment(inv, msg.value, orderId, paymentToken);
        invoice[orderId] = inv;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function payMetaInvoice(bytes32 orderId, address paymentToken) external payable {
        if (paymentToken != address(0) && address(priceFeed[paymentToken]) == address(0)) revert InvalidPaymentToken();
        MetaInvoice memory metaInv = metaInvoice[orderId];
        uint256 price = getTokenValueFromUsd(paymentToken, metaInv.price);

        if (metaInv.price == 0) revert InvoiceDoesNotExist();

        metaInv.paymentToken = paymentToken;

        bytes32[] memory subOrderIds = metaInvoice[orderId].subInvoiceIds;

        bool done;

        for (uint256 i = 0; i < subOrderIds.length; i++) {
            bytes32 subOrderId = subOrderIds[i];
            Invoice memory inv = invoice[subOrderId];

            if (inv.state != INITIATED) continue;
            uint256 invPrice = getTokenValueFromUsd(paymentToken, inv.price);

            address escrow = order[inv.orderId].escrow;
            address escrowAddress = _metaInvoicePayment(inv, paymentToken, invPrice, escrow);
            emit InvoicePaid(subOrderId, paymentToken, escrowAddress, price);

            invoice[subOrderId] = inv;
            done = true;
        }

        if (!done) revert InvalidInvoiceState();
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function acceptInvoices(bytes32[] calldata orderIds) external {
        for (uint256 i = 0; i < orderIds.length; i++) {
            acceptInvoice(orderIds[i]);
        }
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function createDispute(bytes32 orderId) external {
        Invoice memory inv = invoice[orderId];
        if (msg.sender != inv.buyer) revert UnauthorizedBuyer();
        if (inv.state != ACCEPTED) revert InvalidInvoiceState();
        if (block.timestamp > inv.paidAt + inv.releaseWindow) revert DisputeWindowExpired();

        inv.state = DISPUTED;
        invoice[orderId] = inv;
        emit DisputeCreated(orderId);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function handleDispute(bytes32 orderId, uint8 resolution, uint256 sellerShare) external onlyMarketplace {
        Invoice memory inv = invoice[orderId];

        if (inv.state != DISPUTED) revert InvalidInvoiceState();
        if (sellerShare > BASIS_POINTS) revert InvalidSellersPayoutShare();
        if (resolution != DISPUTE_DISMISSED && resolution != DISPUTE_SETTLED && inv.resolutionState != 1) {
            revert InvalidDisputeResolution();
        }

        inv.state = resolution;
        invoice[orderId] = inv;

        if (resolution == DISPUTE_DISMISSED) {
            emit DisputeDismissed(orderId);
        }

        if (resolution == DISPUTE_SETTLED) {
            uint256 sellerReceivingValue = _applyBasisPoints(inv.amountPaid, sellerShare);
            uint256 buyerReceivingValue;
            if (sellerShare != BASIS_POINTS) {
                buyerReceivingValue = _applyBasisPoints(inv.amountPaid, BASIS_POINTS - sellerShare);
                IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, buyerReceivingValue);
            }

            _processSellerPayout(inv, sellerReceivingValue);

            emit DisputeSettled(orderId, sellerReceivingValue, buyerReceivingValue);
        }
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function releasePayment(bytes32 orderId) external onlyMarketplace {
        Order memory orderInfo = order[orderId];

        if (orderInfo.lower == 0 && orderInfo.upper == 0) {
            Invoice memory inv = invoice[orderId];

            if (!_isReleasable(inv)) revert InvalidInvoiceState();
            if (block.timestamp < inv.releaseWindow) emit EarlyRelease(orderId);

            inv.state = RELEASED;
            invoice[orderId] = inv;
            _processSellerPayout(inv, inv.amountPaid);
            emit PaymentReleased(orderId);
        } else {
            Invoice memory invoiceData;
            for (uint256 i = orderInfo.lower; i <= orderInfo.upper; i++) {
                bytes32 subOrderId = orderIdToSubOrderId[orderId][i];
                Invoice memory inv = invoice[subOrderId];

                if (invoiceData.escrow == address(0)) {
                    invoiceData.escrow = inv.escrow;
                    invoiceData.seller = inv.seller;
                    invoiceData.paymentToken = inv.paymentToken;
                }

                if (inv.createdAt == 0 || !_isReleasable(inv)) continue;
                if (block.timestamp < inv.releaseWindow) emit EarlyRelease(subOrderId);

                invoiceData.amountPaid += inv.amountPaid;

                invoice[subOrderId].state = RELEASED;
                emit PaymentReleased(subOrderId);
            }

            if (invoiceData.amountPaid == 0) revert OrderIsEmpty();
            _processSellerPayout(invoiceData, invoiceData.amountPaid);
        }
    }

    /**
     * @dev Checks if an invoice state is eligible for release.
     */
    function _isReleasable(Invoice memory inv) internal pure returns (bool) {
        return inv.state == ACCEPTED || inv.state == DISPUTE_RESOLVED || inv.state == DISPUTE_DISMISSED;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function claimExpiredInvoiceRefunds(bytes32 orderId) external {
        Invoice memory inv = invoice[orderId];
        if (inv.state > REFUNDED || inv.state != PAID) revert InvalidInvoiceState();
        if (inv.state == REFUNDED) revert AlreadyRefunded();

        if (block.timestamp < inv.createdAt + inv.timeBeforeCancelation) revert InvoiceStillActive();

        inv.state = REFUNDED;
        invoice[orderId] = inv;

        IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, inv.amountPaid);

        emit ExpiredInvoiceRefunded(orderId);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function cancelInvoice(bytes32 orderId) public onlyMarketplace {
        Invoice memory inv = invoice[orderId];
        if (inv.state != PAID && inv.state != INITIATED) revert InvalidInvoiceState();

        inv.state = CANCELED;
        invoice[orderId] = inv;
        if (inv.buyer != address(0)) {
            IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, inv.amountPaid);
        }

        emit InvoiceCanceled(orderId);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function acceptInvoice(bytes32 orderId) public {
        Invoice memory inv = invoice[orderId];
        if (inv.seller != msg.sender) revert UnauthorizedSeller();
        if (inv.state != PAID) revert InvalidInvoiceState();
        if (block.timestamp > inv.createdAt + inv.timeBeforeCancelation) revert InvoiceResponseTimeExpired();

        inv.state = ACCEPTED;
        invoice[orderId] = inv;

        emit InvoiceAccepted(orderId);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function resolveDispute(bytes32 orderId, address sender) external onlyMarketplace {
        Invoice memory inv = invoice[orderId];
        if (inv.state != DISPUTED) revert InvalidInvoiceState();
        if (sender != inv.seller && sender != inv.buyer) revert UnauthorizedParticipant();
        if (inv.resolutionInitiator != address(0) && sender == inv.resolutionInitiator) {
            revert DuplicateResolutionAttempt();
        }
        if (inv.resolutionState == 1) {
            inv.resolutionState++;
            inv.state = DISPUTE_RESOLVED;
            emit DisputeResolved(orderId);
        } else {
            inv.resolutionInitiator = sender;
            inv.resolutionState++;
        }
        invoice[orderId] = inv;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function setPriceFeed(address token, address aggregator) external onlyOwner {
        priceFeed[token] = aggregator;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function setMarketplace(address marketplaceAddress) external onlyOwner {
        marketplace = marketplaceAddress;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getTokenValueFromUsd(address paymentToken, uint256 price) public view returns (uint256) {
        address aggregator = paymentToken == address(0) ? nativeTokenAggregator : priceFeed[paymentToken];
        (, int256 answer,,,) = AggregatorV3Interface(aggregator).latestRoundData();
        uint256 usdPerToken = answer.toUint256(); // 8 decimals from Chainlink

        uint8 tokenDecimals = paymentToken == address(0) ? DEFAULT_DECIMAL : IERC20(paymentToken).decimals();

        return price.mulDiv(10 ** tokenDecimals, usdPerToken);
    }

    /**
     * @notice Validates an invoice payment request and computes the required payment amount in tokens.
     * @param inv The invoice to validate against.
     * @param paymentToken The token address used for payment (use address(0) for native token).
     * @param value The amount of native token sent with the transaction.
     * @return price The required amount in the given payment token based on the invoice's USD price.
     */
    function _validatePayment(Invoice memory inv, address paymentToken, uint256 value)
        internal
        view
        returns (uint256)
    {
        if (msg.sender == inv.seller) revert BuyerCannotBeSeller();
        uint256 price = getTokenValueFromUsd(paymentToken, inv.price);

        if (block.timestamp > inv.createdAt + inv.invoiceExpiryDuration) revert InvoiceExpired();
        if (value > 0 && value != price) revert InvalidNativePayment();
        if (inv.state != INITIATED) revert InvalidInvoiceState();

        return price;
    }

    /**
     * @notice Handles payment for an invoice, performs validation, and initializes escrow.
     * @param inv The invoice to be paid.
     * @param value The amount of native token (if any) sent with the transaction.
     * @param orderId The key of the invoice being paid.
     * @param paymentToken The address of the payment token (use address(0) for the native token).
     *
     * @dev
     * - Converts the USD price to payment token amount using Chainlink oracles.
     * - Validates invoice state, sender, and expiration.
     * - Creates an escrow contract and updates the invoice with payment info.
     * - Transfers tokens to escrow if the payment is in ERC20.
     */
    function _invoicePayment(Invoice memory inv, uint256 value, bytes32 orderId, address paymentToken) internal {
        uint256 price = _validatePayment(inv, paymentToken, value);

        address escrowAddress = _create(
            EscrowCreationParams({
                seller: inv.seller,
                buyer: msg.sender,
                orderId: orderId,
                value: value,
                paymentToken: paymentToken
            })
        );

        if (paymentToken != address(0)) {
            inv.paymentToken = paymentToken;
            paymentToken.safeTransferFrom(msg.sender, escrowAddress, price);
        }

        inv.buyer = msg.sender;
        inv.state = PAID;
        inv.escrow = escrowAddress;
        inv.paidAt = (block.timestamp).toUint48();
        inv.amountPaid = price;

        emit InvoicePaid(orderId, paymentToken, escrowAddress, price);
    }

    /**
     * @notice Handles payment for a sub-invoice that is part of a meta-invoice.
     * @param inv The sub-invoice being paid.
     * @param paymentToken The token used for payment (address(0) indicates native token).
     * @param value The native token amount (in wei) sent with the transaction, if any.
     * @param escrow The existing escrow address for the order ID (or address(0) to create one).
     * @return The escrow address used for the transaction.
     */
    function _metaInvoicePayment(Invoice memory inv, address paymentToken, uint256 value, address escrow)
        internal
        returns (address)
    {
        uint256 price = _validatePayment(inv, paymentToken, value);
        if (escrow == address(0)) {
            escrow = _create(
                EscrowCreationParams({
                    seller: inv.seller,
                    buyer: msg.sender,
                    orderId: inv.orderId,
                    value: 0,
                    paymentToken: paymentToken
                })
            );
            order[inv.orderId].escrow = escrow;
        }

        inv.buyer = msg.sender;
        inv.state = PAID;
        inv.escrow = escrow;
        inv.paidAt = (block.timestamp).toUint48();
        inv.amountPaid = price;

        if (paymentToken != address(0)) {
            inv.paymentToken = paymentToken;
            paymentToken.safeTransferFrom(msg.sender, escrow, price);
        } else {
            SafeTransferLib.safeTransferETH(escrow, price);
        }

        return escrow;
    }

    /**
     * @notice Creates a new invoice and stores it in contract state.
     * @param id The unique ID to assign to the new invoice.
     * @param param The parameters required to create the invoice.
     * @return inv The newly created invoice.
     * @return orderId The keccak256 hash representing the invoice ID.
     */
    function _createInvoice(uint256 id, bytes32 metaInvoiceId, InvoiceCreationParam memory param)
        internal
        returns (Invoice memory, bytes32)
    {
        if (param.price == 0) revert PriceCannotBeZero();
        Invoice memory inv;
        inv.seller = param.seller;
        inv.price = param.price;
        inv.createdAt = (block.timestamp).toUint48();
        inv.timeBeforeCancelation = param.timeBeforeCancelation;
        inv.metaInvoiceId = metaInvoiceId;
        inv.state = INITIATED;
        inv.releaseWindow = param.releaseWindow;
        inv.invoiceExpiryDuration = param.invoiceExpiryDuration;
        inv.invoiceId = id;

        bytes32 orderId = keccak256(abi.encode(param.orderId));

        if (invoice[orderId].createdAt != 0) revert InvoiceAlreadyExists();

        invoice[orderId] = inv;
        return (inv, orderId);
    }

    /**
     * @notice Calculates a portion of an amount using basis points.
     * @param amount The base amount to apply the percentage to.
     * @param basisPoints The percentage value in basis points (1 BPS = 0.01%).
     * @return The resulting value after applying basis points.
     */
    function _applyBasisPoints(uint256 amount, uint256 basisPoints) internal pure returns (uint256) {
        return (amount * basisPoints) / BASIS_POINTS;
    }

    /**
     * @notice Computes a deterministic order ID for a seller within a given meta-invoice.
     * @dev This ensures all sub-invoices from the same seller in a meta-invoice share the same order ID.
     * @param seller The address of the seller.
     * @param metaInvoiceId The unique identifier of the meta-invoice.
     * @return A keccak256 hash representing the shared order ID for the seller within the meta-invoice.
     */
    function _computeOrderId(address seller, bytes32 metaInvoiceId) internal pure returns (bytes32) {
        return keccak256(abi.encode(seller, metaInvoiceId));
    }

    /**
     * @notice Distributes the seller's payout from the escrow, applying platform fees.
     * @param inv The invoice data containing escrow and recipient info.
     * @param sellerReceivingValue The gross amount owed to the seller before fees.
     */
    function _processSellerPayout(Invoice memory inv, uint256 sellerReceivingValue) internal {
        uint256 fee = _applyBasisPoints(sellerReceivingValue, ppStorage.getFeeRate());
        IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.seller, sellerReceivingValue - fee);

        IEscrow(inv.escrow).withdraw(inv.paymentToken, ppStorage.getFeeReceiver(), fee);
    }

    /**
     * @notice Computes a deterministic ID for a meta-invoice based on the sub-invoice range and a salt.
     * @dev The hash is based on the contract address, the sub-invoice ID range [lower, upper], and a salt
     *      (e.g., a sequence number or counter). This prevents collisions when multiple meta-invoices share
     *      the same buyer and invoice range.
     * @param lower The starting sub-invoice ID in the group.
     * @param upper The ending sub-invoice ID in the group.
     * @param salt A user-provided or system-generated value (e.g., nextMetaInvoiceId) to ensure uniqueness.
     * @return A keccak256 hash representing the deterministic meta-invoice order ID.
     */
    function _computeMetaInvoiceOrderId(uint256 lower, uint256 upper, uint256 salt) internal view returns (bytes32) {
        return keccak256(abi.encode(lower, upper, salt, block.timestamp));
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getInvoice(bytes32 orderId) external view returns (Invoice memory) {
        return invoice[orderId];
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getMetaInvoice(bytes32 metaInvoiceId) public view returns (MetaInvoice memory) {
        return metaInvoice[metaInvoiceId];
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function totalUniqueInvoiceCreated() external view returns (uint256) {
        return ppStorage.totalInvoiceCreated();
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function totalMetaInvoiceCreated() external view returns (uint256) {
        return nextMetaInvoiceId - 1;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getNextInvoiceId() external view returns (uint256) {
        return ppStorage.getNextInvoiceId();
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getNextMetaInvoiceId() external view returns (uint256) {
        return nextMetaInvoiceId;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getMarketplace() external view returns (address) {
        return marketplace;
    }
}
