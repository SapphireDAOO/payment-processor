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

    /// @notice Buyer has requested cancelation after payment but before acceptance.
    uint8 public constant CANCELATION_REQUESTED = CANCELED + 1;

    /// @notice Seller has accepted the cancelation request from the buyer.
    uint8 public constant CANCELATION_ACCEPTED = CANCELATION_REQUESTED + 1;

    /// @notice Seller has rejected the cancelation request from the buyer.
    uint8 public constant CANCELATION_REJECTED = CANCELATION_ACCEPTED + 1;

    /// @notice Invoice has been rejected due to seller or system decision.
    uint8 public constant REJECTED = CANCELATION_REJECTED + 1;

    /// @notice Buyer has raised a dispute after acceptance.
    uint8 public constant DISPUTED = REJECTED + 1;

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
    mapping(uint256 id => Invoice data) private invoice;

    /**
     * @notice Mapping from unique meta-invoice ID to its aggregate meta-invoice data.
     * @dev Stores metadata for invoices that are grouped into a single payment.
     */
    mapping(uint256 metaInvoiceId => MetaInvoice data) private metaInvoice;

    /**
     * @notice Mapping of payment tokens to their Chainlink price feed aggregator.
     * @dev Used for converting USD prices to the appropriate payment token amounts.
     */
    mapping(address token => address aggregator) private priceFeed;

    /**
     * @notice Mapping from sub-invoice ID to its parent meta-invoice ID.
     * @dev Enables quick lookup to determine which meta-invoice a sub-invoice belongs to.
     */
    mapping(uint256 subInvoiceId => uint256 metaInvoiceId) private subInvoiceToMetaInvoiceId;

    /**
     * @notice Mapping from a meta-invoice ID and its sub-invoice ID to the actual sub-invoice data.
     * @dev Used to access invoice data that is part of a grouped (meta) payment.
     */
    mapping(uint256 metaInvoiceId => mapping(uint256 subInvoiceId => Invoice invoices)) private metaInvoiceToSubInvoice;

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
    function createSingleInvoice(InvoiceCreationParam memory param) external onlyMarketplace {
        _createInvoice(ppStorage.updateInvoiceId(1), 0, param);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function createMetaInvoice(address buyer, InvoiceCreationParam[] memory param) external onlyMarketplace {
        uint256 totalPrice;
        uint256 thisMetaInvoiceId = nextMetaInvoiceId;
        uint256 startInvoiceId = ppStorage.getNextInvoiceId();
        uint256 i = 0;

        MetaInvoice memory metaInv;
        metaInv.lower = startInvoiceId;
        for (; i < param.length; i++) {
            uint256 invoiceId = startInvoiceId + i;
            param[i].buyer = buyer;
            totalPrice += param[i].price;

            Invoice memory inv = _createInvoice(invoiceId, thisMetaInvoiceId, param[i]);
            metaInvoiceToSubInvoice[thisMetaInvoiceId][invoiceId] = inv;
            subInvoiceToMetaInvoiceId[invoiceId] = thisMetaInvoiceId;
        }

        metaInv.upper = startInvoiceId + i - 1;
        metaInv.price = totalPrice;
        metaInv.buyer = msg.sender;
        metaInvoice[thisMetaInvoiceId] = metaInv;
        nextMetaInvoiceId++;
        ppStorage.updateInvoiceId(i);

        emit MetaInvoiceCreated(thisMetaInvoiceId, metaInv);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function paySingleInvoice(uint256 id, address paymentToken) external payable {
        if (paymentToken != address(0) && address(priceFeed[paymentToken]) == address(0)) revert InvalidPaymentToken();

        Invoice memory inv = invoice[id];
        _invoicePayment(inv, msg.value, id, paymentToken);
        invoice[id] = inv;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function payMetaInvoice(uint256 id, address paymentToken) external payable {
        if (paymentToken != address(0) && address(priceFeed[paymentToken]) == address(0)) revert InvalidPaymentToken();
        MetaInvoice memory metaInv = metaInvoice[id];
        uint256 price = getTokenValueFromUsd(paymentToken, metaInv.price);

        if (metaInv.price == 0) revert InvoiceDoesNotExist();
        if (msg.value != price && msg.value > 0) revert InvalidMetaInvoicePayment();
        if (msg.sender != metaInvoiceToSubInvoice[id][metaInv.lower].buyer) revert InvalidBuyer();

        metaInv.paymentToken = paymentToken;
        for (uint256 i = metaInv.lower; i <= metaInv.upper; i++) {
            Invoice memory inv = metaInvoiceToSubInvoice[id][i];
            if (inv.state != INITIATED) continue;
            uint256 invPrice = getTokenValueFromUsd(paymentToken, inv.price);
            _invoicePayment(inv, invPrice, i, paymentToken);
            metaInvoiceToSubInvoice[id][i] = inv;
        }
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function acceptInvoice(uint256[] calldata ids) external {
        for (uint256 i = 0; i < ids.length; i++) {
            acceptInvoice(ids[i]);
        }
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function handleCancelationRequest(uint256 id, bool accept) external {
        Invoice memory inv = _getInvoice(id);
        inv.state = accept ? CANCELATION_ACCEPTED : CANCELATION_REJECTED;
        _updateInvoice(id, inv);
        if (inv.state == CANCELATION_ACCEPTED) {
            IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, inv.amountPaid);
        }

        emit CancelationRequestHandled(id, accept);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function requestCancelation(uint256[] memory ids) external {
        for (uint256 i = 0; i < ids.length; i++) {
            requestCancelation(ids[i]);
        }
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function cancelInvoice(uint256[] memory ids) external {
        for (uint256 i; i < ids.length; i++) {
            cancelInvoice(ids[i]);
        }
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function createDispute(uint256 id) external {
        Invoice memory inv = _getInvoice(id);
        if (msg.sender != inv.buyer) revert UnauthorizedBuyer();
        if (inv.state != ACCEPTED) revert InvalidInvoiceState();
        if (block.timestamp > inv.paidAt + inv.releaseWindow) revert DisputeWindowExpired();

        inv.state = DISPUTED;
        _updateInvoice(id, inv);
        emit DisputeCreated(id);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function resolveDispute(uint256 id, uint8 resolution, uint256 sellerShare) external onlyMarketplace {
        Invoice memory inv = _getInvoice(id);

        if (inv.state != DISPUTED) revert InvalidInvoiceState();
        if (sellerShare > BASIS_POINTS) revert InvalidSellersPayoutShare();
        if (resolution < DISPUTED || resolution > DISPUTE_SETTLED) revert InvalidDisputeResolution();

        inv.state = resolution;
        _updateInvoice(id, inv);

        if (resolution == DISPUTE_RESOLVED) {
            emit DisputeResolved(id);
        }

        if (resolution == DISPUTE_DISMISSED) {
            emit DisputeDismissed(id);
        }

        if (resolution == DISPUTE_SETTLED) {
            uint256 sellerReceivingValue = _applyBasisPoints(inv.amountPaid, sellerShare);
            uint256 buyerReceivingValue;
            if (sellerShare != BASIS_POINTS) {
                buyerReceivingValue = _applyBasisPoints(inv.amountPaid, BASIS_POINTS - sellerShare);
                IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, buyerReceivingValue);
            }

            _processSellerPayout(inv, sellerReceivingValue);

            emit DisputeSettled(id, sellerReceivingValue, buyerReceivingValue);
        }
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function releasePayment(uint256 id) external onlyMarketplace {
        Invoice memory inv = _getInvoice(id);
        if (inv.state == RELEASED) revert InvalidInvoiceState();
        if (inv.state != ACCEPTED) revert InvalidInvoiceState();

        inv.state = RELEASED;
        _updateInvoice(id, inv);
        _processSellerPayout(inv, inv.amountPaid);

        emit PaymentReleased(id);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function claimExpiredInvoiceRefunds(uint256 id) external {
        Invoice memory inv = _getInvoice(id);
        if (inv.state > REFUNDED) revert InvalidInvoiceState();
        if (inv.state == REFUNDED) revert AlreadyRefunded();
        if (msg.sender != inv.buyer) revert UnauthorizedBuyer();
        if (block.timestamp < inv.createdAt + inv.timeBeforeCancelation) revert InvoiceStillActive();

        inv.state = REFUNDED;
        _updateInvoice(id, inv);

        IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, inv.amountPaid);

        emit ExpiredInvoiceRefunded(id);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function cancelInvoice(uint256 id) public {
        Invoice memory inv = _getInvoice(id);
        if (msg.sender != inv.seller) revert UnauthorizedSeller();
        if (inv.state != PAID) revert InvalidInvoiceState();

        inv.state = CANCELED;
        _updateInvoice(id, inv);
        IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, inv.amountPaid);

        emit InvoiceCanceled(id);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function acceptInvoice(uint256 id) public {
        Invoice memory inv = _getInvoice(id);
        if (inv.seller != msg.sender) revert UnauthorizedSeller();
        if (inv.state != PAID) revert InvalidInvoiceState();
        if (block.timestamp > inv.createdAt + inv.timeBeforeCancelation) revert InvoiceResponseTimeExpired();

        inv.state = ACCEPTED;
        _updateInvoice(id, inv);

        emit InvoiceAccepted(id);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function requestCancelation(uint256 id) public {
        Invoice memory inv = _getInvoice(id);
        if (msg.sender != inv.buyer) revert UnauthorizedBuyer();
        if (inv.state != PAID) revert InvalidInvoiceState();
        if (block.timestamp > inv.createdAt + inv.timeBeforeCancelation) revert CancelationRequestDeadlinePassed();

        inv.state = CANCELATION_REQUESTED;
        _updateInvoice(id, inv);

        emit CancelationRequested(id);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function setPriceFeed(address token, address aggregator) external onlyOwner {
        priceFeed[token] = aggregator;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function setMarketplace(address marketplaceAddr) public onlyOwner {
        marketplace = marketplaceAddr;
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
     * @notice Handles payment for an invoice, performs validation, and initializes escrow.
     * @param inv The invoice to be paid.
     * @param value The amount of native token (if any) sent with the transaction.
     * @param id The ID of the invoice being paid.
     * @param paymentToken The address of the payment token (use address(0) for the native token).
     *
     * @dev
     * - Converts the USD price to payment token amount using Chainlink oracles.
     * - Validates invoice state, sender, and expiration.
     * - Creates an escrow contract and updates the invoice with payment info.
     * - Transfers tokens to escrow if the payment is in ERC20.
     */
    function _invoicePayment(Invoice memory inv, uint256 value, uint256 id, address paymentToken) internal {
        uint256 price = getTokenValueFromUsd(paymentToken, inv.price);

        if (block.timestamp > inv.createdAt + inv.invoiceExpiryDuration) revert InvoiceExpired();
        if (value > 0 && value != price) revert InvalidNativePayment();
        if (msg.sender != inv.buyer) revert InvalidBuyer();
        if (inv.state != INITIATED) revert InvalidInvoiceState();

        address escrowAddress = _create(
            EscrowCreationParams({
                seller: inv.seller,
                buyer: inv.buyer,
                invoiceId: id,
                value: value,
                paymentToken: paymentToken
            })
        );

        inv.state = PAID;
        inv.escrow = escrowAddress;
        inv.paidAt = (block.timestamp).toUint48();
        inv.amountPaid = price;

        if (paymentToken != address(0)) {
            inv.paymentToken = paymentToken;
            paymentToken.safeTransferFrom(msg.sender, escrowAddress, price);
        }

        emit InvoicePaid(id, paymentToken, escrowAddress, price);
    }

    /**
     * @notice Creates a new invoice and stores it in contract state.
     * @param id The unique ID to assign to the new invoice.
     * @param metaInvoiceId The ID of the parent meta-invoice, or 0 if this is a standalone invoice.
     * @param param The parameters required to create the invoice.
     * @return inv The newly created invoice.
     */
    function _createInvoice(uint256 id, uint256 metaInvoiceId, InvoiceCreationParam memory param)
        internal
        returns (Invoice memory)
    {
        Invoice memory inv;
        inv.seller = param.seller;
        inv.buyer = param.buyer;
        inv.price = param.price;
        inv.createdAt = (block.timestamp).toUint48();
        inv.timeBeforeCancelation = param.timeBeforeCancelation;
        inv.state = INITIATED;
        inv.metaInvoiceId = metaInvoiceId;
        inv.releaseWindow = param.releaseWindow;
        inv.invoiceExpiryDuration = param.invoiceExpiryDuration;

        invoice[id] = inv;
        emit InvoiceCreated(id, inv);
        return inv;
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
     * @notice Updates an invoice in storage, either single or sub-invoice in a meta-invoice.
     * @param id The unique invoice ID.
     * @param inv The updated invoice data to be stored.
     */
    function _updateInvoice(uint256 id, Invoice memory inv) internal {
        if (inv.metaInvoiceId == 0) {
            invoice[id] = inv;
        } else {
            metaInvoiceToSubInvoice[inv.metaInvoiceId][id] = inv;
        }
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
     * @notice Retrieves invoice data by ID, resolving whether it is standalone or part of a meta-invoice.
     * @param id The ID of the invoice to retrieve.
     * @return The invoice struct for the given ID.
     */
    function _getInvoice(uint256 id) internal view returns (Invoice memory) {
        uint256 metaInvoiceId = subInvoiceToMetaInvoiceId[id];
        return metaInvoiceId == 0 ? invoice[id] : metaInvoiceToSubInvoice[metaInvoiceId][id];
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getInvoice(uint256 id) external view returns (Invoice memory) {
        return _getInvoice(id);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getMetaInvoice(uint256 id) external view returns (MetaInvoice memory) {
        return metaInvoice[id];
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
    function getMetaInvoiceIdForSub(uint256 id) external view returns (uint256) {
        return subInvoiceToMetaInvoiceId[id];
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getMarketplace() external view returns (address) {
        return marketplace;
    }
}
