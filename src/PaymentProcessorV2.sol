// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// -> specific tokens are allowed
// -> introduce SafeTransferLib

// auth
// -> create for
// -> create dispute
// -> marketplace sets new dispute state/amount

// users
// allow single orders too i.e one-to-one
// -> multiple order, multiple seller single buyer i.e one-to-many
// -> how to handler multiple orders?
// -> the sellers address will be entered
// -> fill in order neccasary data(state, price etc)
// data includes sellers address, invoice id, time created, price

// Types of orders
// Single order
// Bulk order
// What would the data structure look like ?
// Id mapped to the invoice data for single order
// what about Bulk/multiple orders ?
// Have a bulk order Id, unique to only bulk order, then order sub invoice should be linked to itr

// when seller accepts orders, there n number of days
// possible scenarios: acceptance, dispute, cancel
// accepts :-> escrow for n days
// cancels :-> refunded. Even in a bulk order sellers buyer can decide to cancel specific ones

// To-do
// Create invoice for user
// handle single invoice

// STATES ?
// INITIATED
// ACCEPTED
// CANCELED
// REJECTED
// DISPUTED
// DISPUTE RESOLVED
// DISPUTE DISMISSED
// DISPUTE SETTLED

// Handling meta invoice
// single seller multiple items
// multiple seller multiple items

// maybe allow them input the id ?

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { EscrowFactory } from "./EscrowFactory.sol";
import { IEscrow } from "./interface/IEscrow.sol";

// rewrite the data that are share between meta invoice and single invoice
// single buyer
// all price packed
// single creation time

// diff seller
// diff price
// diff state

struct Invoice {
    address seller;
    address buyer;
    uint256 price;
    uint256 createdAt;
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

contract PaymentProcessorV2 is EscrowFactory {
    error InvalidBuyer();
    error InvalidMetaInvoicePayment();
    error InvalidPaymentToken();
    error InvalidNativePayment();
    error EscrowAddressMismatch();
    error NoSubInvoiceCancelled();

    using SafeTransferLib for address;

    uint256 private nextInvoiceId;
    uint256 private nextMetaInvoiceId;

    uint256 private feeRate;

    uint32 public constant INITIATED = 1;
    uint32 public constant PAID = INITIATED + 1;
    uint32 public constant ACCEPTED = PAID + 1;
    uint32 public constant CANCELED = ACCEPTED + 1;
    uint32 public constant REJECTED = CANCELED + 1;
    uint32 public constant DISPUTED = REJECTED + 1;
    uint32 public constant DISPUTE_RESOLVED = DISPUTED + 1;
    uint32 public constant DISPUTE_DISMISSED = DISPUTE_RESOLVED + 1;
    uint32 public constant DISPUTE_SETTLED = DISPUTE_DISMISSED + 1;

    uint256 public constant BASIS_POINTS = 10_000;

    mapping(uint256 id => Invoice data) private invoice;
    mapping(uint256 metaInvoiceId => MetaInvoice data) private metaInvoice;
    mapping(address token => bool allowed) private isAllowed;
    mapping(uint256 subInvoiceId => uint256 metaInvoiceId) private subInvoiceToMetaInvoiceId;
    mapping(uint256 metaInvoiceId => mapping(uint256 subInvoiceId => Invoice invoices)) private metaInvoiceToSubInvoice;

    constructor() {
        nextInvoiceId = 1;
        nextMetaInvoiceId = 1;
    }

    // impl access control
    function openMetaInvoice(address[] calldata sellers, uint256[] calldata prices, address buyer) public {
        uint256 totalPrice;
        uint256 thisMetaInvoiceId = nextMetaInvoiceId;
        uint256 startInvoiceId = nextInvoiceId;
        uint256 i = 0;

        MetaInvoice storage metaInv = metaInvoice[thisMetaInvoiceId];
        metaInv.lower = startInvoiceId;
        for (; i < sellers.length; i++) {
            startInvoiceId += i;
            totalPrice += prices[i];

            Invoice memory inv = _openInvoice(startInvoiceId, sellers[i], buyer, prices[i], thisMetaInvoiceId);
            metaInvoiceToSubInvoice[thisMetaInvoiceId][startInvoiceId] = inv;
            subInvoiceToMetaInvoiceId[startInvoiceId] = thisMetaInvoiceId;
        }

        metaInv.upper = startInvoiceId;
        metaInv.price = totalPrice;
        nextMetaInvoiceId++;
        nextInvoiceId += i;

        emit OpenedMetaInvoice(thisMetaInvoiceId, totalPrice);
    }

    // impl access control
    function openInvoice(address seller, address buyer, uint256 price) public {
        _openInvoice(nextInvoiceId++, seller, buyer, price, 0);
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

        if (msg.value != meta.price && msg.value > 0) revert InvalidMetaInvoicePayment();
        if (msg.sender != metaInvoiceToSubInvoice[id][meta.lower].buyer) revert InvalidBuyer();

        for (uint256 i = meta.lower; i <= meta.upper; i++) {
            Invoice memory inv = metaInvoiceToSubInvoice[id][i];
            if (inv.state == CANCELED) continue;

            _invoicePayment(inv, inv.price, i, paymentToken);
            metaInvoiceToSubInvoice[id][i] = inv;

            emit MetaInvoiceSubPaid(i);
        }
    }

    function acceptInvoice(uint256 id) external {
        Invoice memory inv = _getInvoice(id);
        if (inv.state != PAID) revert();
        if (inv.seller != msg.sender) revert();

        inv.state = ACCEPTED;

        _updateInvoice(id, inv);
    }

    function cancelMetaInvoice(uint256 id) external {
        MetaInvoice memory meta = metaInvoice[id];

        if (msg.sender != metaInvoiceToSubInvoice[id][meta.lower].buyer) revert InvalidBuyer();
        uint256 i = meta.lower;
        for (; i <= meta.upper; i++) {
            Invoice memory inv = metaInvoiceToSubInvoice[id][i];

            if (inv.state != PAID && inv.state != INITIATED) continue;

            metaInvoiceToSubInvoice[id][i].state = REJECTED;

            // refund to buyer & emit event
        }

        if (i < meta.upper) revert NoSubInvoiceCancelled();
    }

    function cancelInvoice(uint256[] memory ids) external {
        for (uint256 i; i < ids.length; i++) {
            cancelInvoice(ids[i]);
        }
    }

    function cancelInvoice(uint256 id) public {
        Invoice memory inv = _getInvoice(id);
        if (msg.sender != inv.buyer && inv.state != INITIATED) revert();
        if (msg.sender != inv.seller && inv.state != PAID) revert();

        inv.state = msg.sender == inv.seller ? REJECTED : CANCELED;

        _updateInvoice(id, inv);
    }

    function _invoicePayment(Invoice memory inv, uint256 value, uint256 id, address paymentToken) internal {
        if (value > 0 && value != inv.price) revert InvalidNativePayment();

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

        if (paymentToken != address(0)) {
            inv.paymentToken = paymentToken;
            paymentToken.safeTransferFrom(msg.sender, escrowAddress, inv.price);
        }
    }

    function _openInvoice(uint256 id, address seller, address buyer, uint256 price, uint256 metaInvoiceId)
        internal
        returns (Invoice memory)
    {
        Invoice memory inv = Invoice({
            seller: seller,
            buyer: buyer,
            price: price,
            createdAt: block.timestamp,
            state: INITIATED,
            metaInvoiceId: metaInvoiceId,
            paymentToken: address(0),
            escrow: address(0)
        });

        invoice[id] = inv;
        emit OpenedInvoice(id, inv);
        return inv;
    }

    // function cancelInvoice(uint256 id) external {
    //     Invoice memory inv = _getInvoice(id);

    // }

    // dispute invoice

    // resolve dispute

    // release

    function calculateFee(uint256 _amount) public view returns (uint256) {
        return (_amount * feeRate) / BASIS_POINTS;
    }

    function setPaymentTokenState(address token, bool state) external {
        isAllowed[token] = state;
    }

    function _updateInvoice(uint256 id, Invoice memory inv) internal {
        if (inv.metaInvoiceId == 0) {
            invoice[id] = inv;
        } else {
            metaInvoiceToSubInvoice[inv.metaInvoiceId][id] = inv;
        }
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

    function getNextInvoiceId() external view returns (uint256) {
        return nextInvoiceId;
    }

    function getNextMetaInvoiceId() external view returns (uint256) {
        return nextMetaInvoiceId;
    }

    function getMetaInvoiceIdForSub(uint256 id) external view returns (uint256) {
        return subInvoiceToMetaInvoiceId[id];
    }

    event MetaInvoiceSubPaid(uint256 indexed id);
    event OpenedMetaInvoice(uint256 indexed id, uint256 indexed price);
    event OpenedInvoice(uint256 indexed invoiceId, Invoice invoice);

    // take the price input and the amount transferred should be equal to the price input
}
