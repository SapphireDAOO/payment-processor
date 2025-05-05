// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// ->  specific tokens are allowed
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

contract PaymentProcessorV2 { }
