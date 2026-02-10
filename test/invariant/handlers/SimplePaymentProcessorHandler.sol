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

    uint216[] invoiceIds;

    mapping(bytes4 => uint256) public calls;
    mapping(uint256 => uint256) public price;

    modifier countCall(bytes4 _key) {
        calls[_key]++;
        _;
    }

    modifier invoiceExists() {
        if (invoiceIds.length == 0) return;
        _;
    }

    constructor(SimplePaymentProcessor _sPP, address _buyersAddr, address _sellersAddr) {
        totalInvoiceCreated = 0;
        seller = _sellersAddr;
        buyer = _buyersAddr;

        pp = _sPP;
    }

    function createInvoice(uint256 _price) public countCall(this.createInvoice.selector) {
        _price = bound(_price, 1.01 ether, INVOICE_PRICE);
        vm.prank(seller);
        uint216 invoiceId = pp.createInvoice(_price, "", false);
        price[invoiceId] = _price;
        invoiceIds.push(invoiceId);
        totalInvoiceCreated++;
    }

    function cancelInvoice(uint256 _index) public invoiceExists countCall(this.cancelInvoice.selector) {
        _index = _bound(_index);
        uint216 invoiceId = invoiceIds[_index];
        if (pp.getInvoiceData(invoiceId).status != pp.CREATED()) return;
        vm.prank(seller);
        pp.cancelInvoice(invoiceId);
    }

    function makePayment(uint256 _index, uint256 _value) public invoiceExists countCall(this.makePayment.selector) {
        _index = _bound(_index);
        uint216 invoiceId = invoiceIds[_index];
        if (pp.getInvoiceData(invoiceId).status != pp.CREATED()) return;
        uint256 iPrice = pp.getInvoiceData(invoiceId).price;
        _value = bound(_value, iPrice, iPrice);

        _value = bound(_value, 0, price[invoiceId]);

        vm.prank(buyer);
        pp.pay{ value: _value }(invoiceId, "", false);
    }

    function acceptPayment(uint256 _index) public invoiceExists countCall(this.acceptPayment.selector) {
        _index = _bound(_index);
        uint216 invoiceId = invoiceIds[_index];
        ISimplePaymentProcessor.Invoice memory i = pp.getInvoiceData(invoiceId);
        if (i.status != pp.PAID()) return;
        vm.prank(seller);
        pp.acceptPayment(invoiceId);
    }

    function rejectPayment(uint256 _index) public invoiceExists countCall(this.rejectPayment.selector) {
        _index = _bound(_index);
        uint216 invoiceId = invoiceIds[_index];
        ISimplePaymentProcessor.Invoice memory i = pp.getInvoiceData(invoiceId);
        if (i.status != pp.PAID()) return;
        vm.prank(seller);
        pp.rejectPayment(invoiceId);
    }

    function release(uint256 _index) public invoiceExists countCall(this.release.selector) {
        _index = _bound(_index);
        uint216 invoiceId = invoiceIds[_index];

        if (pp.getInvoiceData(invoiceId).status == pp.RELEASED()) return;

        uint256 eligibleAt = uint256(pp.getInvoiceData(invoiceId).releaseAt);
        if (block.timestamp <= eligibleAt) {
            vm.warp(eligibleAt + 1);
        }

        vm.prank(seller);
        pp.release(invoiceId);
    }

    /// @notice Returns the total number of invoices created by the handler.
    function getTotalInvoiceCreated() external view returns (uint256 totalInvoices) {
        return totalInvoiceCreated;
    }

    /**
     * @notice Bounds an index to the current invoiceIds array length.
     * @param _index The index to bound.
     * @return boundedIndex The bounded index.
     */
    function _bound(uint256 _index) internal view returns (uint256 boundedIndex) {
        return bound(_index, 0, invoiceIds.length - 1);
    }

    function callSummary() external view {
        console.log("Simple Payment Processor Call Summary:");
        console.log("-------------------");
        console.log("Create Invoice:", calls[this.createInvoice.selector]);
        console.log("Cancel Invoice:", calls[this.cancelInvoice.selector]);
        console.log("Make Payment:", calls[this.makePayment.selector]);
        console.log("Accept Invoice:", calls[this.acceptPayment.selector]);
        console.log("Reject Invoice:", calls[this.rejectPayment.selector]);
        console.log("Release Invoice:", calls[this.release.selector]);
    }

    /// @notice Returns the number of tracked invoices.
    function getInvoiceCount() external view returns (uint256 count) {
        return invoiceIds.length;
    }

    /// @notice Returns the invoice id at a given index.
    function getInvoiceId(uint256 _index) external view returns (uint216 invoiceId) {
        return invoiceIds[_index];
    }
}
