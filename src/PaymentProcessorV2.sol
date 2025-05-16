// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IEscrow } from "./interface/IEscrow.sol";
import { EscrowFactory } from "./EscrowFactory.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

// expire when an invoice is sent without a payment

struct Invoice {
    address seller;
    address buyer;
    uint256 createdAt;
    uint256 price;
    uint256 paidAt;
    uint256 timeBeforeCancelation;
    uint256 disputeWindow;
    uint256 state;
    uint256 metaInvoiceId;
    address paymentToken;
    address escrow;
}

struct MetaInvoice {
    uint256 price;
    uint256 upper;
    uint256 lower;
    address paymentToken;
    address escrow;
}

struct InvoiceCreationParam {
    address seller;
    address buyer;
    uint256 timeBeforeCancelation; // pack
    uint256 disputeWindow; // pack
    uint256 price;
}

// send funds in dispute settlement
// release should impl access control
// tests
// impl access control
// test
// rearrange file (v1 + v2) ?
// package struct

contract PaymentProcessorV2 is EscrowFactory, Ownable {
    error InvalidBuyer();
    error InvalidMetaInvoicePayment();
    error InvalidPaymentToken();
    error InvalidNativePayment();
    error EscrowAddressMismatch();
    error NoSubInvoiceCancelled();
    error InvalidInvoiceState();
    error UnauthorizedSeller();
    error InvoiceDoesNotExist();
    error UnauthorizedBuyer();
    error InvoiceResponseTimeExpired();
    error DisputeWindowExpired();
    error InvalidDisputeResolution();
    error InvalidSellersPayoutShare();
    error NoShareAllocatedToBuyer();
    error NotAuthorized();

    using SafeTransferLib for address;

    uint256 private nextInvoiceId;
    uint256 private nextMetaInvoiceId;

    uint256 private feeRate;
    address private marketplace;

    uint32 public constant INITIATED = 1;
    uint32 public constant PAID = INITIATED + 1;
    uint32 public constant ACCEPTED = PAID + 1;
    uint32 public constant CANCELED = ACCEPTED + 1;
    uint32 public constant CANCELATION_REQUESTED = CANCELED + 1;
    uint32 public constant CANCELATION_ACCEPTED = CANCELATION_REQUESTED + 1;
    uint32 public constant CANCELATION_REJECTED = CANCELATION_ACCEPTED + 1;
    uint32 public constant REJECTED = CANCELATION_REJECTED + 1;
    uint32 public constant DISPUTED = REJECTED + 1;

    uint32 public constant DISPUTE_RESOLVED = DISPUTED + 1;
    uint32 public constant DISPUTE_DISMISSED = DISPUTE_RESOLVED + 1;
    uint32 public constant DISPUTE_SETTLED = DISPUTE_DISMISSED + 1;

    uint32 public constant RELEASED = DISPUTE_SETTLED + 1;

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

    constructor(address ownerAddress, address marketplaceAddress, uint256 newFeeRate) {
        _initializeOwner(ownerAddress);
        setMarketplace(marketplaceAddress);
        setFeeRate(newFeeRate);
        nextInvoiceId = 1;
        nextMetaInvoiceId = 1;
    }

    function openMetaInvoice(address buyer, InvoiceCreationParam[] memory param) public onlyMarketplace {
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

            Invoice memory inv = _openInvoice(invoiceId, thisMetaInvoiceId, param[i]);
            metaInvoiceToSubInvoice[thisMetaInvoiceId][invoiceId] = inv;
            subInvoiceToMetaInvoiceId[invoiceId] = thisMetaInvoiceId;
        }

        metaInv.upper = startInvoiceId + i - 1;
        metaInv.price = totalPrice;
        nextMetaInvoiceId++;
        nextInvoiceId += i;

        emit OpenedMetaInvoice(thisMetaInvoiceId, totalPrice);
    }

    function openInvoice(InvoiceCreationParam memory param) public onlyMarketplace {
        _openInvoice(nextInvoiceId++, 0, param);
    }

    function paySingleInvoice(uint256 id, address paymentToken) external payable {
        if (paymentToken != address(0) && !isAllowed[paymentToken]) revert InvalidPaymentToken();

        Invoice memory inv = invoice[id];
        _invoicePayment(inv, msg.value, id, paymentToken);
        invoice[id] = inv;
    }

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

    function acceptInvoice(uint256[] calldata ids) external {
        for (uint256 i = 0; i < ids.length; i++) {
            acceptInvoice(ids[i]);
        }
    }

    function acceptInvoice(uint256 id) public {
        Invoice memory inv = _getInvoice(id);
        if (inv.seller != msg.sender) revert UnauthorizedSeller();
        if (inv.state != PAID) revert InvalidInvoiceState();
        if (block.timestamp > inv.createdAt + inv.timeBeforeCancelation) revert InvoiceResponseTimeExpired();

        inv.state = ACCEPTED;

        _updateInvoice(id, inv);

        emit InvoiceAccepted(id);
    }

    function handleCancelationRequest(uint256 id, bool accept) public {
        Invoice memory inv = _getInvoice(id);
        inv.state = accept ? CANCELATION_ACCEPTED : CANCELATION_REJECTED;
        _updateInvoice(id, inv);

        if (inv.state == CANCELATION_ACCEPTED) {
            IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, inv.price);
        }
    }

    function requestCancelation(uint256[] memory ids) public {
        for (uint256 i = 0; i < ids.length; i++) {
            requestCancelation(ids[i]);
        }
    }

    function requestCancelation(uint256 id) public {
        Invoice memory inv = _getInvoice(id);
        if (msg.sender != inv.buyer) revert UnauthorizedBuyer();
        if (inv.state != PAID) revert InvalidInvoiceState();
        if (block.timestamp > inv.createdAt + inv.timeBeforeCancelation) revert InvoiceResponseTimeExpired();

        inv.state = CANCELATION_REQUESTED;
        _updateInvoice(id, inv);
    }

    function cancelInvoice(uint256[] memory ids) external {
        for (uint256 i; i < ids.length; i++) {
            cancelInvoice(ids[i]);
        }
    }

    function cancelInvoice(uint256 id) public {
        Invoice memory inv = _getInvoice(id);
        if (msg.sender != inv.seller && inv.state != PAID) revert InvalidInvoiceState();
        // time check?

        inv.state = CANCELED;
        _updateInvoice(id, inv);
        IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.buyer, inv.price);

        emit InvoiceCanceled(id);
    }

    // dispute invoice

    function createDispute(uint256 id) external {
        Invoice memory inv = _getInvoice(id);
        if (msg.sender != inv.buyer) revert UnauthorizedBuyer();
        if (block.timestamp > inv.paidAt + inv.disputeWindow) revert DisputeWindowExpired();
        if (inv.state != ACCEPTED) revert InvalidInvoiceState();

        inv.state = DISPUTED;
        _updateInvoice(id, inv);
    }

    // resolve dispute
    // impl access control
    function resolveDispute(uint256 id, uint256 resolution, uint256 sellerShare) external onlyMarketplace {
        Invoice memory inv = _getInvoice(id);
        if (inv.state != DISPUTED) revert InvalidInvoiceState();
        if (resolution < DISPUTED || resolution > DISPUTE_SETTLED) revert InvalidDisputeResolution();
        if (sellerShare > BASIS_POINTS) revert InvalidSellersPayoutShare();

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
            uint256 fee = _applyBasisPoints(sellerReceivingValue, feeRate);
            sellerReceivingValue = _applyBasisPoints(sellerReceivingValue, fee);
            IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.seller, sellerReceivingValue);

            emit DisputeSettled(id, sellerReceivingValue, buyerReceivingValue);
        }
    }

    function releasePayment(uint256 id) external onlyMarketplace {
        Invoice memory inv = _getInvoice(id);
        if (inv.state == RELEASED) revert();
        if (inv.state == DISPUTE_SETTLED) revert();
        if (inv.state != ACCEPTED && inv.state != DISPUTE_DISMISSED && inv.state != DISPUTE_RESOLVED) {
            revert InvalidInvoiceState();
        }

        inv.state = RELEASED;
        _updateInvoice(id, inv);
        uint256 fee = _applyBasisPoints(inv.price, feeRate);
        IEscrow(inv.escrow).withdraw(inv.paymentToken, inv.seller, inv.price - fee);
    }

    // may be allow multiple action on invoice in one?

    function _invoicePayment(Invoice memory inv, uint256 value, uint256 id, address paymentToken) internal {
        if (value > 0 && value != inv.price) revert InvalidNativePayment();
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
        inv.paidAt = block.timestamp;

        if (paymentToken != address(0)) {
            inv.paymentToken = paymentToken;
            paymentToken.safeTransferFrom(msg.sender, escrowAddress, inv.price);
        }
    }

    function _openInvoice(uint256 id, uint256 metaInvoiceId, InvoiceCreationParam memory param)
        internal
        returns (Invoice memory)
    {
        Invoice memory inv;
        inv.seller = param.seller;
        inv.buyer = param.buyer;
        inv.price = param.price;
        inv.createdAt = block.timestamp;
        inv.timeBeforeCancelation = param.timeBeforeCancelation;
        inv.state = INITIATED;
        inv.metaInvoiceId = metaInvoiceId;
        inv.disputeWindow = param.disputeWindow;

        invoice[id] = inv;
        emit OpenedInvoice(id, inv);
        return inv;
    }

    function calculateFee(uint256 amount) public view returns (uint256) {
        return _applyBasisPoints(amount, feeRate);
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

    function setFeeRate(uint256 _feeRate) public onlyOwner {
        feeRate = _feeRate;
    }

    function setMarketplace(address marketplaceAddr) public onlyOwner {
        marketplace = marketplaceAddr;
    }

    function setPaymentTokenState(address token, bool state) external onlyOwner {
        isAllowed[token] = state;
    }

    function _getInvoice(uint256 id) internal view returns (Invoice memory) {
        uint256 metaInvoiceId = subInvoiceToMetaInvoiceId[id];
        return metaInvoiceId == 0 ? invoice[id] : metaInvoiceToSubInvoice[metaInvoiceId][id];
    }

    function getInvoice(uint256 id) external view returns (Invoice memory) {
        return _getInvoice(id);
    }

    function getMetaInvoice(uint256 id) external view returns (MetaInvoice memory) {
        return metaInvoice[id];
    }

    function totalUniqueInvoiceCreated() external view returns (uint256) {
        return nextInvoiceId - 1;
    }

    function totalMetaInvoiceCreated() external view returns (uint256) {
        return nextMetaInvoiceId - 1;
    }

    function getNextInvoiceId() external view returns (uint256) {
        return nextInvoiceId;
    }

    function getNextMetaInvoiceId() external view returns (uint256) {
        return nextMetaInvoiceId;
    }

    function getMetaInvoiceIdForSub(uint256 id) external view returns (uint256) {
        return subInvoiceToMetaInvoiceId[id];
    }

    event DisputeDismissed(uint256 indexed invoiceId);
    event DisputeResolved(uint256 indexed invoiceId);
    event InvoiceAccepted(uint256 indexed invoiceId);
    event MetaInvoiceSubPaid(uint256 indexed id);
    event OpenedMetaInvoice(uint256 indexed id, uint256 indexed price);
    event OpenedInvoice(uint256 indexed invoiceId, Invoice invoice);
    event InvoiceCanceled(uint256 indexed invoiceId);
    event InvoiceRejected(uint256 indexed invoiceId);
    event DisputeSettled(uint256 indexed id, uint256 sellerAmount, uint256 buyerAmount);

    // take the price input and the amount transferred should be equal to the price input
}
