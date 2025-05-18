// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IEscrow } from "./interface/IEscrow.sol";
import { EscrowFactory } from "./EscrowFactory.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPaymentProcessorV2 } from "./interface/IPaymentProcessorV2.sol";

// introduce chainlink oracle for balanced prices

contract PaymentProcessorV2 is IPaymentProcessorV2, EscrowFactory, Ownable {
    using SafeTransferLib for address;
    using SafeCastLib for uint256;

    uint256 private nextInvoiceId;
    uint256 private nextMetaInvoiceId;

    uint256 private feeRate;
    address private marketplace;
    address private feeReceiver;

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

    mapping(uint256 id => Invoice data) private invoice;
    mapping(address token => bool allowed) private isAllowed;
    mapping(uint256 metaInvoiceId => MetaInvoice data) private metaInvoice;
    mapping(uint256 subInvoiceId => uint256 metaInvoiceId) private subInvoiceToMetaInvoiceId;
    mapping(uint256 metaInvoiceId => mapping(uint256 subInvoiceId => Invoice invoices)) private metaInvoiceToSubInvoice;

    modifier onlyMarketplace() {
        if (msg.sender != marketplace) revert NotAuthorized();
        _;
    }

    constructor(address ownerAddress, address marketplaceAddress, uint256 newFeeRate, address feeReceiverAddress) {
        _initializeOwner(ownerAddress);
        setMarketplace(marketplaceAddress);
        setFeeRate(newFeeRate);
        setFeeReceiver(feeReceiverAddress);
        nextInvoiceId = 1;
        nextMetaInvoiceId = 1;
    }

    /// @inheritdoc IPaymentProcessorV2
    function createSingleInvoice(InvoiceCreationParam memory param) external onlyMarketplace {
        _createInvoice(nextInvoiceId++, 0, param);
    }

    /// @inheritdoc IPaymentProcessorV2
    function createMetaInvoice(address buyer, InvoiceCreationParam[] memory param) external onlyMarketplace {
        uint256 totalPrice;
        uint256 thisMetaInvoiceId = nextMetaInvoiceId;
        uint256 startInvoiceId = nextInvoiceId;
        uint256 i = 0;

        MetaInvoice storage metaInv = metaInvoice[thisMetaInvoiceId];
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
        nextMetaInvoiceId++;
        nextInvoiceId += i;

        emit OpenedMetaInvoice(thisMetaInvoiceId, totalPrice);
    }

    /// @inheritdoc IPaymentProcessorV2
    function paySingleInvoice(uint256 id, address paymentToken) external payable {
        if (paymentToken != address(0) && !isAllowed[paymentToken]) revert InvalidPaymentToken();

        Invoice memory inv = invoice[id];
        _invoicePayment(inv, msg.value, id, paymentToken);
        invoice[id] = inv;
    }

    /// @inheritdoc IPaymentProcessorV2
    function payMetaInvoice(uint256 id, address paymentToken) external payable {
        if (paymentToken != address(0) && !isAllowed[paymentToken]) revert InvalidPaymentToken();
        MetaInvoice memory meta = metaInvoice[id];
        if (meta.price == 0) revert InvoiceDoesNotExist();

        if (msg.value != meta.price && msg.value > 0) revert InvalidMetaInvoicePayment();
        if (msg.sender != metaInvoiceToSubInvoice[id][meta.lower].buyer) revert InvalidBuyer();

        for (uint256 i = meta.lower; i <= meta.upper; i++) {
            Invoice memory inv = metaInvoiceToSubInvoice[id][i];
            if (inv.state != INITIATED) continue;

            _invoicePayment(inv, inv.price, i, paymentToken);
            metaInvoiceToSubInvoice[id][i] = inv;

            emit MetaInvoiceSubPaid(i);
        }
    }

    /// @inheritdoc IPaymentProcessorV2
    function acceptInvoice(uint256[] calldata ids) external {
        for (uint256 i = 0; i < ids.length; i++) {
            acceptInvoice(ids[i]);
        }
    }

    /// @inheritdoc IPaymentProcessorV2
    function handleCancelationRequest(uint256 id, bool accept) external {
        Invoice memory inv = _getInvoice(id);
        inv.state = accept ? CANCELATION_ACCEPTED : CANCELATION_REJECTED;
        _updateInvoice(id, inv);
        if (inv.state == CANCELATION_ACCEPTED) {
            IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, inv.price);
        }
    }

    /// @inheritdoc IPaymentProcessorV2
    function requestCancelation(uint256[] memory ids) external {
        for (uint256 i = 0; i < ids.length; i++) {
            requestCancelation(ids[i]);
        }
    }

    /// @inheritdoc IPaymentProcessorV2
    function cancelInvoice(uint256[] memory ids) external {
        for (uint256 i; i < ids.length; i++) {
            cancelInvoice(ids[i]);
        }
    }

    /// @inheritdoc IPaymentProcessorV2
    function createDispute(uint256 id) external {
        Invoice memory inv = _getInvoice(id);
        if (msg.sender != inv.buyer) revert UnauthorizedBuyer();
        if (inv.state != ACCEPTED) revert InvalidInvoiceState();
        if (block.timestamp > inv.paidAt + inv.disputeWindow) revert DisputeWindowExpired();

        inv.state = DISPUTED;
        _updateInvoice(id, inv);
    }

    /// @inheritdoc IPaymentProcessorV2
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
            uint256 sellerReceivingValue = _applyBasisPoints(inv.price, sellerShare);
            uint256 buyerReceivingValue;
            if (sellerShare != BASIS_POINTS) {
                buyerReceivingValue = _applyBasisPoints(inv.price, BASIS_POINTS - sellerShare);
                IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, buyerReceivingValue);
            }

            _processSellerPayout(inv, sellerReceivingValue);

            emit DisputeSettled(id, sellerReceivingValue, buyerReceivingValue);
        }
    }

    /// @inheritdoc IPaymentProcessorV2
    function releasePayment(uint256 id) external onlyMarketplace {
        Invoice memory inv = _getInvoice(id);
        if (inv.state == RELEASED) revert InvalidInvoiceState();
        if (inv.state != ACCEPTED) revert InvalidInvoiceState();

        inv.state = RELEASED;
        _updateInvoice(id, inv);
        _processSellerPayout(inv, inv.price);
    }

    /// @inheritdoc IPaymentProcessorV2
    function claimExpiredInvoiceRefunds(uint256 id) external {
        Invoice memory inv = _getInvoice(id);
        if (inv.state > REFUNDED) revert InvalidInvoiceState();
        if (inv.state == REFUNDED) revert AlreadyRefunded();
        if (msg.sender != inv.buyer) revert UnauthorizedBuyer();
        if (block.timestamp < inv.createdAt + inv.timeBeforeCancelation) revert InvoiceStillActive();

        inv.state = REFUNDED;
        _updateInvoice(id, inv);

        IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, inv.price);
    }

    /// @inheritdoc IPaymentProcessorV2
    function cancelInvoice(uint256 id) public {
        Invoice memory inv = _getInvoice(id);
        if (msg.sender != inv.seller) revert UnauthorizedSeller();
        if (inv.state != PAID) revert InvalidInvoiceState();
        // time check?

        inv.state = CANCELED;
        _updateInvoice(id, inv);
        IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, inv.price);

        emit InvoiceCanceled(id);
    }

    /// @inheritdoc IPaymentProcessorV2
    function acceptInvoice(uint256 id) public {
        Invoice memory inv = _getInvoice(id);
        if (inv.seller != msg.sender) revert UnauthorizedSeller();
        if (inv.state != PAID) revert InvalidInvoiceState();
        if (block.timestamp > inv.createdAt + inv.timeBeforeCancelation) revert InvoiceResponseTimeExpired();

        inv.state = ACCEPTED;
        _updateInvoice(id, inv);

        emit InvoiceAccepted(id);
    }

    /// @inheritdoc IPaymentProcessorV2
    function requestCancelation(uint256 id) public {
        Invoice memory inv = _getInvoice(id);
        if (msg.sender != inv.buyer) revert UnauthorizedBuyer();
        if (inv.state != PAID) revert InvalidInvoiceState();
        if (block.timestamp > inv.createdAt + inv.timeBeforeCancelation) revert CancelationRequestDeadlinePassed();

        inv.state = CANCELATION_REQUESTED;
        _updateInvoice(id, inv);
    }

    /// @inheritdoc IPaymentProcessorV2
    function setPaymentTokenState(address token, bool state) external onlyOwner {
        isAllowed[token] = state;
    }

    /// @inheritdoc IPaymentProcessorV2
    function setFeeReceiver(address feeReceiverAddress) public onlyOwner {
        feeReceiver = feeReceiverAddress;
    }

    /// @inheritdoc IPaymentProcessorV2
    function setFeeRate(uint256 _feeRate) public onlyOwner {
        feeRate = _feeRate;
    }

    /// @inheritdoc IPaymentProcessorV2
    function setMarketplace(address marketplaceAddr) public onlyOwner {
        marketplace = marketplaceAddr;
    }

    function _invoicePayment(Invoice memory inv, uint256 value, uint256 id, address paymentToken) internal {
        if (block.timestamp > inv.createdAt + inv.invoiceExpiryDuration) revert InvoiceExpired();
        if (value > 0 && value != inv.price) revert InvalidNativePayment();
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

        if (paymentToken != address(0)) {
            inv.paymentToken = paymentToken;
            paymentToken.safeTransferFrom(msg.sender, escrowAddress, inv.price);
        }
    }

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
        inv.disputeWindow = param.disputeWindow;
        inv.invoiceExpiryDuration = param.invoiceExpiryDuration;

        invoice[id] = inv;
        emit OpenedInvoice(id, inv);
        return inv;
    }

    function _applyBasisPoints(uint256 amount, uint256 basisPoints) internal pure returns (uint256) {
        return (amount * basisPoints) / BASIS_POINTS;
    }

    function _updateInvoice(uint256 id, Invoice memory inv) internal {
        if (inv.metaInvoiceId == 0) {
            invoice[id] = inv;
        } else {
            metaInvoiceToSubInvoice[inv.metaInvoiceId][id] = inv;
        }
    }

    function _processSellerPayout(Invoice memory inv, uint256 sellerReceivingValue) internal {
        uint256 fee = _applyBasisPoints(sellerReceivingValue, feeRate);
        IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.seller, sellerReceivingValue - fee);

        IEscrow(inv.escrow).withdraw(inv.paymentToken, feeReceiver, fee);
    }

    function _getInvoice(uint256 id) internal view returns (Invoice memory) {
        uint256 metaInvoiceId = subInvoiceToMetaInvoiceId[id];
        return metaInvoiceId == 0 ? invoice[id] : metaInvoiceToSubInvoice[metaInvoiceId][id];
    }

    /// @inheritdoc IPaymentProcessorV2
    function getInvoice(uint256 id) external view returns (Invoice memory) {
        return _getInvoice(id);
    }

    /// @inheritdoc IPaymentProcessorV2
    function getMetaInvoice(uint256 id) external view returns (MetaInvoice memory) {
        return metaInvoice[id];
    }

    /// @inheritdoc IPaymentProcessorV2
    function totalUniqueInvoiceCreated() external view returns (uint256) {
        return nextInvoiceId - 1;
    }

    /// @inheritdoc IPaymentProcessorV2
    function totalMetaInvoiceCreated() external view returns (uint256) {
        return nextMetaInvoiceId - 1;
    }

    /// @inheritdoc IPaymentProcessorV2
    function getNextInvoiceId() external view returns (uint256) {
        return nextInvoiceId;
    }

    /// @inheritdoc IPaymentProcessorV2
    function getNextMetaInvoiceId() external view returns (uint256) {
        return nextMetaInvoiceId;
    }

    /// @inheritdoc IPaymentProcessorV2
    function getMetaInvoiceIdForSub(uint256 id) external view returns (uint256) {
        return subInvoiceToMetaInvoiceId[id];
    }
}
