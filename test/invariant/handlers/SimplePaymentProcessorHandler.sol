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

    uint256[] orderIds;

    mapping(bytes4 => uint256) public calls;
    mapping(uint256 => uint256) public price;

    modifier countCall(bytes4 key) {
        calls[key]++;
        _;
    }

    modifier invoiceExists() {
        if (orderIds.length == 0) return;
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
        uint256 orderId = pp.createInvoice(_price);
        price[orderId] = _price;
        orderIds.push(orderId);
        totalInvoiceCreated++;
    }

    function cancelInvoice(uint256 index) public invoiceExists countCall(this.cancelInvoice.selector) {
        index = _bound(index);
        uint256 orderId = orderIds[index];
        if (pp.getInvoiceData(orderId).status != pp.CREATED()) return;
        vm.prank(seller);
        pp.cancelInvoice(orderId);
    }

    function makePayment(uint256 index, uint256 _value) public invoiceExists countCall(this.makePayment.selector) {
        index = _bound(index);
        uint256 orderId = orderIds[index];
        if (pp.getInvoiceData(orderId).status != pp.CREATED()) return;
        uint256 iPrice = pp.getInvoiceData(orderId).price;
        _value = bound(_value, iPrice, iPrice);

        _value = bound(_value, 0, price[orderId]);

        vm.prank(buyer);
        pp.makeInvoicePayment{ value: _value }(orderId);
    }

    function acceptPayment(uint256 index) public invoiceExists countCall(this.acceptPayment.selector) {
        index = _bound(index);
        uint256 orderId = orderIds[index];
        ISimplePaymentProcessor.Invoice memory i = pp.getInvoiceData(orderId);
        if (i.status != pp.PAID()) return;
        vm.prank(seller);
        pp.acceptPayment(orderId);
    }

    function rejectPayment(uint256 index) public invoiceExists countCall(this.rejectPayment.selector) {
        index = _bound(index);
        uint256 orderId = orderIds[index];
        ISimplePaymentProcessor.Invoice memory i = pp.getInvoiceData(orderId);
        if (i.status != pp.PAID()) return;
        vm.prank(seller);
        pp.rejectPayment(orderId);
    }

    function releaseInvoice(uint256 index) public invoiceExists countCall(this.releaseInvoice.selector) {
        index = _bound(index);
        uint256 orderId = orderIds[index];
        if (pp.getInvoiceData(orderId).status == pp.RELEASED()) return;
        vm.assume(block.timestamp > block.timestamp + pp.ACCEPTANCE_WINDOW());
        vm.prank(seller);
        pp.releaseInvoice(orderId);
    }

    function getTotalInvoiceCreated() external view returns (uint256) {
        return totalInvoiceCreated;
    }

    function _bound(uint256 index) internal view returns (uint256) {
        return bound(index, 0, orderIds.length - 1);
    }

    function callSummary() external view {
        console.log("Simple Payment Processor Call Summary:");
        console.log("-------------------");
        console.log("Create Invoice:", calls[this.createInvoice.selector]);
        console.log("Cancel Invoice:", calls[this.cancelInvoice.selector]);
        console.log("Make Payment:", calls[this.makePayment.selector]);
        console.log("Accept Invoice:", calls[this.acceptPayment.selector]);
        console.log("Reject Invoice:", calls[this.rejectPayment.selector]);
        console.log("Release Invoice:", calls[this.releaseInvoice.selector]);
    }
}
