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
}

struct MetaInvoice {
    uint256 price;
    uint256 upper;
    uint256 lower;
    address paymentToken;
}

contract PaymentProcessorV2 {
    using SafeTransferLib for address;

    uint256 private nextInvoiceId;
    uint256 private nextMetaInvoiceId;

    uint256 public constant INITIATED = 1;
    uint256 public constant PAID = INITIATED + 1;
    uint256 public constant ACCEPTED = PAID + 1;
    uint256 public constant CANCELED = ACCEPTED + 1;
    uint256 public constant REJECTED = CANCELED + 1;
    uint256 public constant DISPUTED = REJECTED + 1;
    uint256 public constant DISPUTE_RESOLVED = DISPUTED + 1;
    uint256 public constant DISPUTE_DISMISSED = DISPUTE_RESOLVED + 1;
    uint256 public constant DISPUTE_SETTLED = DISPUTE_DISMISSED + 1;

    mapping(uint256 id => Invoice data) private invoice;
    mapping(uint256 id => MetaInvoice data) private metaInvoice;
    mapping(address token => bool allowed) private isAllowed;
    mapping(uint256 mId => mapping(uint256 id => Invoice)) private metaInvoiceToSubInvoice;
    mapping(uint256 subInvId => uint256 metaInvId) private subInvoiceToMetaInvoiceId;

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

    function payInvoice(uint256 id, address paymentToken) external payable {
        if (paymentToken != address(0) && !isAllowed[paymentToken]) revert();
        Invoice memory inv = invoice[id];
        invoice[id].state = PAID;

        _handlePayment(paymentToken, msg.value, inv.price);
    }

    function payMetaInvoice(uint256 id, address paymentToken) external payable {
        if (paymentToken != address(0) && !isAllowed[paymentToken]) revert();
        MetaInvoice memory meta = metaInvoice[id];
        if (msg.sender != metaInvoiceToSubInvoice[id][meta.lower].buyer) revert();

        for (uint256 i = meta.lower; i <= meta.upper; i++) {
            if (metaInvoiceToSubInvoice[id][i].state == CANCELED) continue;
            metaInvoiceToSubInvoice[id][i].state = PAID;
            emit MetaInvoiceSubPaid(i);
        }

        _handlePayment(paymentToken, msg.value, meta.price);
    }

    function _handlePayment(address paymentToken, uint256 value, uint256 price) internal {
        if (value != 0) {
            if (value != price) revert();
        } else {
            paymentToken.safeTransferFrom(msg.sender, address(this), price);
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
            metaInvoiceId: metaInvoiceId
        });

        invoice[id] = inv;
        emit OpenedInvoice(id, inv);
        return inv;
    }

    // cancel invoice

    // dispute invoice

    // resolve dispute

    function getInvoice(uint256 id) external view returns (Invoice memory) {
        uint256 metaInvoiceId = subInvoiceToMetaInvoiceId[id];
        return metaInvoiceId == 0 ? invoice[id] : metaInvoiceToSubInvoice[metaInvoiceId][id];
    }

    function getMetaInvoice(uint256 id) external view returns (MetaInvoice memory) {
        return metaInvoice[id];
    }

    function getMetaInvoiceTotalPrice(uint256 metaInvoiceId) external view returns (uint256) {
        return metaInvoice[metaInvoiceId].price;
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
