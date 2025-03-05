// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { PaymentProcessorV1 } from "../../src/PaymentProcessorV1.sol";
import "../../src/utils/Constants.sol";

contract Handler is Test {
    PaymentProcessorV1 public pp;

    uint256 public balance;
    uint256 public totalInvoiceCreated;

    address creator;
    address payer;

    uint256[] public ids;

    uint256 constant FEE = 1 ether;
    uint256 constant INVOICE_PRICE = 1000 ether;

    uint256 constant PAYERS_INITIAL_FUND = 10_000 ether;

    mapping(bytes32 => uint256) public calls;
    mapping(uint256 => uint256) public price;

    modifier countCall(bytes32 key) {
        calls[key]++;
        _;
    }

    constructor(PaymentProcessorV1 _pp) {
        totalInvoiceCreated = 1;
        creator = address(1);
        payer = address(2);

        vm.deal(payer, PAYERS_INITIAL_FUND);

        pp = _pp;
    }

    function createInvoice(uint256 _price) public countCall("createInvoice") {
        _price = bound(_price, FEE + 1, INVOICE_PRICE);
        vm.prank(creator);
        uint256 invoiceId = pp.createInvoice(_price);
        ids.push(invoiceId);
        price[invoiceId] = _price;
        totalInvoiceCreated++;
    }

    function cancelInvoice(uint256 _invoiceId) public countCall("cancelInvoice") {
        if (ids.length > 0) {
            _invoiceId = ids[bound(_invoiceId, 0, ids.length - 1)];
            if (pp.getInvoiceData(_invoiceId).status != CREATED) return;
            vm.prank(creator);
            pp.cancelInvoice(_invoiceId);
        }
    }

    function makePayment(uint256 _invoiceId, uint256 _value) public countCall("makePayment") {
        if (ids.length > 0) {
            _invoiceId = ids[bound(_invoiceId, 0, ids.length - 1)];
            if (pp.getInvoiceData(_invoiceId).status != CREATED) return;
            _value = bound(_value, FEE + 1, price[_invoiceId]);

            vm.prank(payer);
            pp.makeInvoicePayment{ value: _value }(_invoiceId);

            balance += FEE;
        }
    }

    function acceptInvoice(uint256 _invoiceId) public countCall("acceptInvoice") {
        if (ids.length > 0) {
            _invoiceId = ids[bound(_invoiceId, 0, ids.length - 1)];
            if (pp.getInvoiceData(_invoiceId).status != PAID) return;
            vm.prank(creator);
            pp.creatorsAction(_invoiceId, true);
        }
    }

    function rejectInvoice(uint256 _invoiceId) public countCall("rejectInvoice") {
        if (ids.length > 0) {
            _invoiceId = ids[bound(_invoiceId, 0, ids.length - 1)];
            if (pp.getInvoiceData(_invoiceId).status != PAID) return;
            vm.prank(creator);
            pp.creatorsAction(_invoiceId, true);
        }
    }

    function releaseInvoice(uint256 _invoiceId) public countCall("releaseInvoice") {
        if (ids.length > 0) {
            _invoiceId = ids[bound(_invoiceId, 0, ids.length - 1)];
            if (pp.getInvoiceData(_invoiceId).status == RELEASED) return;
            vm.assume(block.timestamp > block.timestamp + ACCEPTANCE_WINDOW);
            vm.prank(creator);
            pp.releaseInvoice(_invoiceId);
        }
    }

    function callSummary() external view {
        console.log("Call summary:");
        console.log("-------------------");
        console.log("Create", calls["createInvoice"]);
        console.log("Cancel", calls["cancelInvoice"]);
        console.log("Payment", calls["makePayment"]);
        console.log("Accept", calls["acceptInvoice"]);
        console.log("Reject", calls["rejectInvoice"]);
        console.log("Release", calls["releaseInvoice"]);
    }
}
