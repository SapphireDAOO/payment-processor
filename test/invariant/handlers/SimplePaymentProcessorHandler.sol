// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor, SimplePaymentProcessor } from "../../../src/SimplePaymentProcessor.sol";
import { Test, console } from "forge-std/Test.sol";

contract SimplePaymentProcessorHandler is Test {
    SimplePaymentProcessor public pp;

    uint256 private totalInvoiceCreated;

    address seller;
    address buyer;

    uint256 constant INVOICE_PRICE = 1000 ether;

    uint256 constant BUYERS_INITIAL_FUND = 10_000 ether;

    bytes32[] invoiceKeys;

    mapping(bytes4 => uint256) public calls;
    mapping(bytes32 => uint256) public price;

    modifier countCall(bytes4 key) {
        calls[key]++;
        _;
    }

    modifier invoiceExists() {
        if (invoiceKeys.length == 0) return;
        _;
    }

    constructor(SimplePaymentProcessor sPP, address buyersAddr, address sellersAddr) {
        totalInvoiceCreated = 0;
        seller = sellersAddr;
        buyer = buyersAddr;

        pp = sPP;
    }

    function createInvoice(uint256 _price) public countCall(this.createInvoice.selector) {
        _price = bound(_price, 1.01 ether, INVOICE_PRICE);
        vm.prank(seller);
        bytes32 invoiceKey = pp.createInvoice(_price);
        price[invoiceKey] = _price;
        invoiceKeys.push(invoiceKey);
        totalInvoiceCreated++;
    }

    function cancelInvoice(uint256 index) public invoiceExists countCall(this.cancelInvoice.selector) {
        index = _bound(index);
        bytes32 invoiceKey = invoiceKeys[index];
        if (pp.getInvoiceData(invoiceKey).status != pp.CREATED()) return;
        vm.prank(seller);
        pp.cancelInvoice(invoiceKey);
    }

    function makePayment(uint256 index, uint256 _value) public invoiceExists countCall(this.makePayment.selector) {
        index = _bound(index);
        bytes32 invoiceKey = invoiceKeys[index];
        if (pp.getInvoiceData(invoiceKey).status != pp.CREATED()) return;
        uint256 iPrice = pp.getInvoiceData(invoiceKey).price;
        _value = bound(_value, iPrice, iPrice);

        _value = bound(_value, 0, price[invoiceKey]);

        vm.prank(buyer);
        pp.makeInvoicePayment{ value: _value }(invoiceKey);
    }

    function sellerAction(uint256 index, bool accept) public invoiceExists countCall(this.sellerAction.selector) {
        index = _bound(index);
        bytes32 invoiceKey = invoiceKeys[index];
        ISimplePaymentProcessor.Invoice memory i = pp.getInvoiceData(invoiceKey);
        if (i.status != pp.PAID()) return;
        vm.prank(seller);
        pp.sellerAction(invoiceKey, accept);
    }

    function releaseInvoice(uint256 index) public invoiceExists countCall(this.releaseInvoice.selector) {
        index = _bound(index);
        bytes32 invoiceKey = invoiceKeys[index];
        if (pp.getInvoiceData(invoiceKey).status == pp.RELEASED()) return;
        vm.assume(block.timestamp > block.timestamp + pp.ACCEPTANCE_WINDOW());
        vm.prank(seller);
        pp.releaseInvoice(invoiceKey);
    }

    function getTotalInvoiceCreated() external view returns (uint256) {
        return totalInvoiceCreated;
    }

    function _bound(uint256 index) internal view returns (uint256) {
        return bound(index, 0, invoiceKeys.length - 1);
    }

    function callSummary() external view {
        console.log("Simple Payment Processor Call Summary:");
        console.log("-------------------");
        console.log("Create Invoice:", calls[this.createInvoice.selector]);
        console.log("Cancel Invoice:", calls[this.cancelInvoice.selector]);
        console.log("Make Payment:", calls[this.makePayment.selector]);
        console.log("Accept/reject Invoice:", calls[this.sellerAction.selector]);
        console.log("Release Invoice:", calls[this.releaseInvoice.selector]);
    }
}
