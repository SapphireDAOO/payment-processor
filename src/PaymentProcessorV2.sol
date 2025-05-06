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
// CANCELLED
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
    address paymentToken;
    mapping(uint256 id => Invoice) invoices;
}

contract PaymentProcessorV2 {
    using SafeTransferLib for address;

    uint256 private nextInvoiceId;
    uint256 private nextMetaInvoiceId;

    uint256 public constant INITIATED = 1;
    uint256 public constant ACCEPTED = INITIATED + 1;
    uint256 public constant CANCELLED = ACCEPTED + 1;
    uint256 public constant REJECTED = CANCELLED + 1;
    uint256 public constant DISPUTED = REJECTED + 1;
    uint256 public constant DISPUTE_RESOLVED = DISPUTED + 1;
    uint256 public constant DISPUTE_DISMISSED = DISPUTE_RESOLVED + 1;
    uint256 public constant DISPUTE_SETTLED = DISPUTE_DISMISSED + 1;

    mapping(uint256 id => Invoice data) private invoice;
    mapping(uint256 id => MetaInvoice data) private metaInvoice;
    mapping(address token => bool allowed) private isAllowed;

    constructor() {
        nextInvoiceId = 1;
        nextMetaInvoiceId = 1;
    }

    function openMultipleInvoiceWithPayment(
        address[] calldata sellers,
        uint256[] calldata prices,
        address buyer,
        address paymentToken
    ) public payable {
        // sanity checks

        uint256 totalPrice;
        uint256 thisMetaInvoiceId = nextMetaInvoiceId;
        uint256 currentInvoiceId = nextInvoiceId;
        uint256 i = 0;

        for (; i < sellers.length; i++) {
            totalPrice += prices[i];
            Invoice memory inv = Invoice({
                seller: sellers[i],
                buyer: buyer,
                price: prices[i],
                createdAt: block.timestamp,
                state: INITIATED,
                metaInvoiceId: thisMetaInvoiceId
            });

            invoice[currentInvoiceId + i] = inv;
            metaInvoice[thisMetaInvoiceId].invoices[currentInvoiceId + i] = inv;
        }

        if (msg.value > 0 && msg.value < totalPrice) revert();

        metaInvoice[thisMetaInvoiceId].price = totalPrice;
        metaInvoice[thisMetaInvoiceId].paymentToken = paymentToken;
        nextMetaInvoiceId++;
        nextInvoiceId += i;

        // make payment
        // only when the msg.value == 0

        // events
    }

    // impl access control
    function openInvoiceWithPayment(address seller, address buyer, address paymentToken, uint256 price)
        public
        payable
    {
        if (!isAllowed[paymentToken] && paymentToken != address(0)) revert();
        if (msg.value > 0) price = msg.value;
        invoice[nextInvoiceId++] = Invoice({
            seller: seller,
            buyer: buyer,
            price: price,
            createdAt: block.timestamp,
            state: INITIATED,
            metaInvoiceId: 0
        });

        if (msg.value == 0) {
            paymentToken.safeTransferFrom(msg.sender, address(this), price);
        } else {
            if (msg.value != price) revert();
        }
    }

    function getInvoice(uint256 id) external view returns (Invoice memory) {
        return invoice[id];
    }

    function getChildInvoice(uint256 metaInvoiceId, uint256 subInvoiceId) external view returns (Invoice memory) {
        return metaInvoice[metaInvoiceId].invoices[subInvoiceId];
    }

    function getMetaInvoiceTotalPrice(uint256 metaInvoiceId) external view returns (uint256) {
        return metaInvoice[metaInvoiceId].price;
    }

    // take the price input and the amount transferred should be equal to the price input
}
