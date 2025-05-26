// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor, SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { SimplePaymentProcessorSetUp } from "../util/SimplePaymentProcessorSetUp.sol";
import { console } from "forge-std/console.sol";

contract SimplePaymentProcessorFuzzTest is SimplePaymentProcessorSetUp {
    function testFuzz_invoice_creation(uint256 _amount) public {
        vm.assume(_amount > 1 ether);
        vm.prank(sellerOne);
        simplePP.createInvoice(_amount);
        ISimplePaymentProcessor.Invoice memory invoiceData = simplePP.getInvoiceData(1);
        assertEq(invoiceData.creator, sellerOne);
        assertEq(invoiceData.createdAt, block.timestamp);
        assertEq(invoiceData.paymentTime, 0);
        assertEq(invoiceData.price, _amount);
        assertEq(invoiceData.amountPaid, 0);
        assertEq(invoiceData.payer, address(0));
        assertEq(invoiceData.status, simplePP.CREATED());
        assertEq(invoiceData.escrow, address(0));
        assertEq(simplePP.getNextInvoiceId(), 2);
    }

    function testFuzz_createAndPayInvoice(uint256 _invoicePrice) public {
        _invoicePrice = bound(_invoicePrice, 1 ether, 1000 ether);

        vm.prank(sellerOne);
        uint256 invoiceId = simplePP.createInvoice(_invoicePrice);

        ISimplePaymentProcessor.Invoice memory invoice = simplePP.getInvoiceData(invoiceId);
        assertEq(invoice.price, _invoicePrice);
        assertEq(invoice.status, simplePP.CREATED());

        vm.prank(buyerOne);
        address escrow = simplePP.makeInvoicePayment{ value: _invoicePrice }(invoiceId);

        ISimplePaymentProcessor.Invoice memory updated = simplePP.getInvoiceData(invoiceId);
        assertEq(updated.payer, buyerOne);
        assertEq(updated.amountPaid, _invoicePrice);
        assertEq(updated.status, simplePP.PAID());
        assertEq(updated.escrow, escrow);
    }
}
