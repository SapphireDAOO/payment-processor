// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EscrowFactory } from "./EscrowFactory.sol";

import { AggregatorV3Interface } from "./interface/AggregatorV3Interface.sol";

import { IERC20 } from "./interface/IERC20.sol";
import { IEscrow } from "./interface/IEscrow.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";
import { IAdvancedPaymentProcessor } from "./interface/IAdvancedPaymentProcessor.sol";

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { TaskQueueLib } from "src/libraries/TaskQueueLib.sol";
import { MinHeapLib } from "solady/utils/MinHeapLib.sol";

contract AdvancedPaymentProcessor is IAdvancedPaymentProcessor, EscrowFactory {
    using { SafeTransferLib.safeTransferFrom } for address;
    using { SafeCastLib.toUint48, SafeCastLib.toUint216 } for uint256;
    using { SafeCastLib.toUint256 } for int256;
    using { FixedPointMathLib.mulDiv } for uint256;

    using TaskQueueLib for MinHeapLib.Heap;

    MinHeapLib.Heap private heap;

    /// @notice Reference to the external Payment Processor storage contract.
    IPaymentProcessorStorage public ppStorage;

    /// @notice The next available meta-invoice ID to be assigned.
    uint256 private nextMetaInvoiceId;

    /// @notice Chainlink price feed aggregator for the native token.
    address private nativeTokenAggregator;

    /// @notice Invoice has been created but no payment has been made yet.
    uint8 public constant INITIATED = 1;

    /// @notice Invoice has been paid by the buyer.
    uint8 public constant PAID = INITIATED + 1;

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

    /**
     * @notice Mapping from unique invoice ID to its invoice data.
     * @dev Used for standalone invoices (not part of a meta-invoice).
     */
    mapping(uint216 orderId => Invoice data) private invoice;

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

    mapping(uint216 => uint256) private index;

    /**
     * @notice Restricts function access to the authorized marketplace address.
     * @dev Reverts with NotAuthorized() if the caller is not the marketplace.
     */
    modifier onlyMarketplace() {
        if (msg.sender != ppStorage.getMarketplace()) revert NotAuthorized();
        _;
    }
    /**
     * @notice Initializes the AdvancedPaymentProcessor contract with core configuration.
     * @param paymentProcessorStorageAddress The address of the shared payment processor storage contract.
     * @param nativeTokenAggregatorAddress The Chainlink aggregator address for the native token (e.g., ETH/USD, POL/USD).
     */

    constructor(address paymentProcessorStorageAddress, address nativeTokenAggregatorAddress) {
        ppStorage = IPaymentProcessorStorage(paymentProcessorStorageAddress);
        nativeTokenAggregator = nativeTokenAggregatorAddress;
        nextMetaInvoiceId = 1;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function createSingleInvoice(InvoiceCreationParam memory param) external onlyMarketplace returns (uint216) {
        uint216 orderId = _createInvoice(ppStorage.updateInvoiceId(1), 0, param);
        return orderId;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function createMetaInvoice(InvoiceCreationParam[] memory param) external onlyMarketplace returns (uint216) {
        uint256 totalPrice;
        uint256 startInvoiceId = ppStorage.getNextInvoiceId();
        uint256 length = param.length;
        uint256 upperInvoiceId = length + startInvoiceId - 1;

        uint216 metaInvoiceOrderId = _computeMetaInvoiceOrderId(startInvoiceId, upperInvoiceId, nextMetaInvoiceId);
        if (metaInvoice[metaInvoiceOrderId].price != 0) revert MetaInvoiceAlreadyExists();

        for (uint256 i = 0; i < length; i++) {
            totalPrice += param[i].price;
            uint216 subOrderId = _createInvoice(startInvoiceId + i, metaInvoiceOrderId, param[i]);
            metaInvoice[metaInvoiceOrderId].subInvoiceIds.push(subOrderId);
        }

        metaInvoice[metaInvoiceOrderId].price = totalPrice;

        ppStorage.updateInvoiceId(length.toUint216());

        nextMetaInvoiceId++;

        emit MetaInvoiceCreated(metaInvoiceOrderId, totalPrice);

        return metaInvoiceOrderId;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function paySingleInvoice(uint216 orderId, address paymentToken) external payable {
        if (paymentToken != address(0) && address(priceFeed[paymentToken]) == address(0)) revert InvalidPaymentToken();

        Invoice memory inv = invoice[orderId];
        _invoicePayment(inv, orderId, paymentToken, msg.value);
        invoice[orderId] = inv;
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function payMetaInvoice(uint216 orderId, address paymentToken) external payable {
        if (paymentToken != address(0) && address(priceFeed[paymentToken]) == address(0)) revert InvalidPaymentToken();
        MetaInvoice memory metaInv = metaInvoice[orderId];

        if (metaInv.price == 0) revert InvoiceDoesNotExist();

        uint216[] memory subOrderIds = metaInvoice[orderId].subInvoiceIds;

        bool done;

        for (uint256 i = 0; i < subOrderIds.length; i++) {
            uint216 subOrderId = subOrderIds[i];
            Invoice memory inv = invoice[subOrderId];

            if (inv.state != INITIATED) continue;
            uint256 invPrice = getTokenValueFromUsd(paymentToken, inv.price);

            uint256 value = paymentToken == address(0) ? invPrice : 0;
            _invoicePayment(inv, subOrderId, paymentToken, value);

            invoice[subOrderId] = inv;
            if (i == subOrderIds.length - 1) done = true;
        }

        if (!done) revert InvalidInvoiceState();
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function createDispute(uint216 orderId) external onlyMarketplace {
        Invoice memory inv = invoice[orderId];
        if (inv.state != PAID) revert InvalidInvoiceState();

        inv.state = DISPUTED;
        invoice[orderId] = inv;
        emit DisputeCreated(orderId);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function handleDispute(uint216 orderId, uint8 resolution, uint256 sellerShare) external onlyMarketplace {
        Invoice memory inv = invoice[orderId];

        if (inv.state != DISPUTED) revert InvalidInvoiceState();
        if (sellerShare > BASIS_POINTS) revert InvalidSellersPayoutShare();
        if (resolution != DISPUTE_DISMISSED && resolution != DISPUTE_SETTLED) {
            revert InvalidDisputeResolution();
        }

        inv.state = resolution;
        invoice[orderId] = inv;

        if (resolution == DISPUTE_DISMISSED) {
            emit DisputeDismissed(orderId);
        }

        if (resolution == DISPUTE_SETTLED) {
            heap.removeAt(index[orderId] - 1, index);
            (uint256 sellerReceivingValue, uint256 buyerReceivingValue) = _distributeFunds(inv, sellerShare);
            emit DisputeSettled(orderId, sellerReceivingValue, buyerReceivingValue);
        }
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function release(uint216 orderId) external onlyMarketplace {
        if (!_release(orderId)) revert InvalidInvoiceState();
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function refund(uint216 orderId, uint256 refundShare) external onlyMarketplace {
        Invoice memory inv = invoice[orderId];
        if (inv.state != PAID) revert InvalidInvoiceState();

        uint256 amount = _applyBasisPoints(inv.balance, refundShare);
        if (amount > inv.balance) revert InsufficientBalance();

        if (refundShare == inv.balance) {
            heap.removeAt(index[orderId] - 1, index);
        }

        inv.balance -= amount;
        invoice[orderId] = inv;

        IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, amount);
        emit Refunded(orderId, amount);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function cancelInvoice(uint216 orderId) public onlyMarketplace {
        if (invoice[orderId].state != INITIATED) revert InvalidInvoiceState();
        invoice[orderId].state = CANCELED;
        emit InvoiceCanceled(orderId);
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function resolveDispute(uint216 orderId) external onlyMarketplace {
        if (invoice[orderId].state != DISPUTED) revert InvalidInvoiceState();
        invoice[orderId].state = DISPUTE_RESOLVED;
        emit DisputeResolved(orderId);
    }

    function checkUpkeep(bytes calldata) external view returns (bool, bytes memory) {
        return (heap.due(), bytes(""));
    }

    function performUpkeep(bytes calldata) external {
        uint256 gasThresold = 5_000_000;
        while (gasleft() > gasThresold && heap.due()) {
            (uint216 orderId,) = heap.peek();

            bool released = _release(orderId);
            if (!released) {
                uint256 pos = index[orderId];
                if (pos > 0 && pos <= heap.data.length) {
                    heap.removeAt(pos - 1, index);
                } else {
                    break;
                }
            }
        }
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function setPriceFeed(address token, address aggregator) external {
        if (msg.sender != PaymentProcessorStorage(address(ppStorage)).owner()) revert NotAuthorized();
        priceFeed[token] = aggregator;
    }

    function setInvoiceReleaseTime(uint216 orderId, uint256 holdPeriod) external {
        if (msg.sender != address(ppStorage)) revert NotAuthorized();
        Invoice memory inv = invoice[orderId];
        if (inv.state != PAID) revert InvalidInvoiceState();

        inv.releaseAt = block.timestamp + holdPeriod;

        heap.reschedule(orderId, uint40(inv.releaseAt), index);

        emit UpdateReleaseTime(orderId, holdPeriod);
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
     * @dev Checks if an invoice state is eligible for release.
     */
    function _isReleasable(Invoice memory inv) internal view returns (bool) {
        return (inv.state == PAID || inv.state == DISPUTE_RESOLVED || inv.state == DISPUTE_DISMISSED)
            && block.timestamp >= inv.releaseAt;
    }

    function _release(uint216 orderId) internal returns (bool) {
        Invoice memory inv = invoice[orderId];
        invoice[orderId].state = RELEASED;
        invoice[orderId].balance = 0;
        if (!_isReleasable(inv)) return false;

        uint256 pos = index[orderId];
        if (pos == 0 || pos > heap.data.length) return false;

        heap.removeAt(pos - 1, index);
        uint256 sellerNetAmount = _processSellerPayout(inv, inv.balance);
        emit PaymentReleased(orderId, sellerNetAmount);
        return true;
    }

    /**
     * @notice Handles payment for an invoice, performs validation, and initializes escrow.
     * @param inv The invoice to be paid.
     * @param orderId The key of the invoice being paid.
     * @param paymentToken The address of the payment token (use address(0) for the native token).
     *  @param value The amount of native token sent with the transaction.
     *
     * @dev
     * - Converts the USD price to payment token amount using Chainlink oracles.
     * - Validates invoice state, sender, and expiration.
     * - Creates an escrow contract and updates the invoice with payment info.
     * - Transfers tokens to escrow if the payment is in ERC20.
     */
    function _invoicePayment(Invoice memory inv, uint216 orderId, address paymentToken, uint256 value) internal {
        if (msg.sender == inv.seller) revert BuyerCannotBeSeller();
        uint256 price = getTokenValueFromUsd(paymentToken, inv.price);
        if (inv.state != INITIATED) revert InvalidInvoiceState();

        bool isNative = paymentToken == address(0);

        if (isNative && value != price) revert InvalidNativePayment();

        address escrowAddress = _create(
            EscrowCreationParams({
                seller: inv.seller,
                buyer: msg.sender,
                orderId: orderId,
                value: isNative ? value : 0,
                paymentToken: paymentToken
            })
        );

        inv.buyer = msg.sender;
        inv.state = PAID;
        inv.escrow = escrowAddress;
        inv.paidAt = (block.timestamp).toUint48();
        inv.balance = price;
        inv.amountPaid = price;
        inv.releaseAt = inv.releaseAt == 0 ? block.timestamp + ppStorage.getDefaultHoldPeriod() : inv.releaseAt;

        heap.insert(orderId, uint40(inv.releaseAt), index);

        if (!isNative) {
            inv.paymentToken = paymentToken;
            paymentToken.safeTransferFrom(msg.sender, escrowAddress, price);
        }

        emit InvoicePaid(orderId, paymentToken, escrowAddress, price);
    }

    /**
     * @notice Creates a new invoice and stores it in contract state.
     * @param id The unique ID to assign to the new invoice.
     * @param param The parameters required to create the invoice.
     * @return orderId The keccak256 hash representing the invoice ID.
     */
    function _createInvoice(uint256 id, uint216 metaInvoiceId, InvoiceCreationParam memory param)
        internal
        returns (uint216)
    {
        if (param.price == 0) revert PriceCannotBeZero();
        if (param.price < 1e8) revert PriceIsTooLow();
        Invoice memory inv;
        inv.seller = param.seller;
        inv.price = param.price;
        inv.createdAt = (block.timestamp).toUint48();
        inv.metaInvoiceId = metaInvoiceId;
        inv.state = INITIATED;
        inv.invoiceId = id;

        uint216 orderId = (uint256(keccak256(abi.encode(param.orderId))) & ((1 << 216) - 1)).toUint216();

        if (invoice[orderId].createdAt != 0) revert InvoiceAlreadyExists();

        invoice[orderId] = inv;

        emit InvoiceCreated(orderId, inv);
        return orderId;
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
     * @notice Distributes the remaining invoice balance between the seller and the buyer.
     * @dev Transfers the buyer's refund (if any) and the seller's payout based on the given share.
     *      The refund is only processed if the seller is not entitled to the full balance.
     * @param inv The invoice containing payment and escrow details.
     * @param sellerShare The portion of the invoice balance (in basis points) to be sent to the seller.
     * @return sellerReceivingValue The amount sent to the seller.
     * @return buyerReceivingValue The amount refunded to the buyer (zero if sellerShare == 10000).
     */
    function _distributeFunds(Invoice memory inv, uint256 sellerShare) internal returns (uint256, uint256) {
        uint256 sellerReceivingValue = _applyBasisPoints(inv.balance, sellerShare);
        uint256 buyerReceivingValue;
        if (sellerShare != BASIS_POINTS) {
            buyerReceivingValue = _applyBasisPoints(inv.balance, BASIS_POINTS - sellerShare);
            IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, buyerReceivingValue);
        }

        _processSellerPayout(inv, sellerReceivingValue);
        return (sellerReceivingValue, buyerReceivingValue);
    }

    /**
     * @notice Distributes the seller's payout from the escrow, applying platform fees.
     * @param inv The invoice data containing escrow and recipient info.
     * @param sellerReceivingValue The gross amount owed to the seller before fees.
     * @return The amount the seller receives after fees are deducted.
     */
    function _processSellerPayout(Invoice memory inv, uint256 sellerReceivingValue) internal returns (uint256) {
        uint256 fee = _applyBasisPoints(sellerReceivingValue, ppStorage.getFeeRate());
        uint256 amount = sellerReceivingValue - fee;
        IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.seller, amount);

        IEscrow(inv.escrow).withdraw(inv.paymentToken, ppStorage.getFeeReceiver(), fee);
        return amount;
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
    function _computeMetaInvoiceOrderId(uint256 lower, uint256 upper, uint256 salt) internal view returns (uint216) {
        return (uint256(keccak256(abi.encode(lower, upper, salt, address(this)))) & ((1 << 216) - 1)).toUint216();
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getInvoice(uint216 orderId) external view returns (Invoice memory) {
        return invoice[orderId];
    }

    /// @inheritdoc IAdvancedPaymentProcessor
    function getMetaInvoice(uint216 metaInvoiceId) public view returns (MetaInvoice memory) {
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
}
