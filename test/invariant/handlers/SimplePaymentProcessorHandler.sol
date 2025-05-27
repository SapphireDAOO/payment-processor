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

    uint256 constant buyerS_INITIAL_FUND = 10_000 ether;

    mapping(bytes4 => uint256) public calls;
    mapping(uint256 => uint256) public price;

    modifier countCall(bytes4 key) {
        calls[key]++;
        _;
    }

    modifier invoiceExists() {
        if (totalInvoiceCreated == 1) return;
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
        uint256 invoiceId = pp.createInvoice(_price);
        price[invoiceId] = _price;
        totalInvoiceCreated++;
    }

    function cancelInvoice(uint256 _invoiceId) public invoiceExists countCall(this.cancelInvoice.selector) {
        _invoiceId = bound(_invoiceId, 0, totalInvoiceCreated);
        if (pp.getInvoiceData(_invoiceId).status != pp.CREATED()) return;
        vm.prank(seller);
        pp.cancelInvoice(_invoiceId);
    }

    function makePayment(uint256 _invoiceId, uint256 _value)
        public
        invoiceExists
        countCall(this.makePayment.selector)
    {
        _invoiceId = bound(_invoiceId, 0, totalInvoiceCreated);

        if (pp.getInvoiceData(_invoiceId).status != pp.CREATED()) return;
        uint256 iPrice = pp.getInvoiceData(_invoiceId).price;
        _value = bound(_value, iPrice, iPrice);

        _value = bound(_value, 0, price[_invoiceId]);

        vm.prank(buyer);
        pp.makeInvoicePayment{ value: _value }(_invoiceId);
    }

    function acceptInvoice(uint256 _invoiceId) public invoiceExists countCall(this.acceptInvoice.selector) {
        _invoiceId = bound(_invoiceId, 0, totalInvoiceCreated);
        ISimplePaymentProcessor.Invoice memory i = pp.getInvoiceData(_invoiceId);
        if (i.status != pp.PAID()) return;
        vm.prank(seller);
        pp.creatorsAction(_invoiceId, true);
    }

    function rejectInvoice(uint256 _invoiceId) public invoiceExists countCall(this.rejectInvoice.selector) {
        _invoiceId = bound(_invoiceId, 0, totalInvoiceCreated);
        if (pp.getInvoiceData(_invoiceId).status != pp.PAID()) return;
        vm.prank(seller);
        pp.creatorsAction(_invoiceId, false);
    }

    function releaseInvoice(uint256 _invoiceId) public invoiceExists countCall(this.releaseInvoice.selector) {
        _invoiceId = bound(_invoiceId, 0, totalInvoiceCreated);
        if (pp.getInvoiceData(_invoiceId).status == pp.RELEASED()) return;
        vm.assume(block.timestamp > block.timestamp + pp.ACCEPTANCE_WINDOW());
        vm.prank(seller);
        pp.releaseInvoice(_invoiceId);
    }

    function getTotalInvoiceCreated() external view returns (uint256) {
        return totalInvoiceCreated;
    }

    function callSummary() external view {
        console.log("Simple Payment Processor Call Summary:");
        console.log("-------------------");
        console.log("Create Invoice:", calls[this.createInvoice.selector]);
        console.log("Cancel Invoice:", calls[this.cancelInvoice.selector]);
        console.log("Make Payment:", calls[this.makePayment.selector]);
        console.log("Accept Invoice:", calls[this.acceptInvoice.selector]);
        console.log("Reject Invoice:", calls[this.rejectInvoice.selector]);
        console.log("Release Invoice:", calls[this.releaseInvoice.selector]);
    }
}
