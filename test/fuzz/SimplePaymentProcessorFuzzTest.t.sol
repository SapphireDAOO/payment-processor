// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor, SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { SimplePaymentProcessorSetUp } from "../utils/SimplePaymentProcessorSetUp.sol";
import { console } from "forge-std/console.sol";

contract SimplePaymentProcessorFuzzTest is SimplePaymentProcessorSetUp {
    function testFuzz_invoice_creation(uint256 _amount) public {
        vm.assume(_amount > 1 ether);
        vm.prank(sellerOne);
        bytes32 orderId = simplePP.createInvoice(_amount);
        ISimplePaymentProcessor.Invoice memory invoiceData = simplePP.getInvoiceData(orderId);
        assertEq(invoiceData.seller, sellerOne);
        assertEq(invoiceData.createdAt, block.timestamp);
        assertEq(invoiceData.paymentTime, 0);
        assertEq(invoiceData.price, _amount);
        assertEq(invoiceData.amountPaid, 0);
        assertEq(invoiceData.buyer, address(0));
        assertEq(invoiceData.status, simplePP.CREATED());
        assertEq(invoiceData.escrow, address(0));
        assertEq(invoiceData.invoiceId, 1);
        assertEq(simplePP.getNextInvoiceId(), 2);
    }

    function testFuzz_createAndPayInvoice(uint256 _invoicePrice) public {
        _invoicePrice = bound(_invoicePrice, 1 ether, 1000 ether);

        vm.prank(sellerOne);
        bytes32 orderId = simplePP.createInvoice(_invoicePrice);

        ISimplePaymentProcessor.Invoice memory invoice = simplePP.getInvoiceData(orderId);
        assertEq(invoice.price, _invoicePrice);
        assertEq(invoice.status, simplePP.CREATED());

        vm.prank(buyerOne);
        address escrow = simplePP.makeInvoicePayment{ value: _invoicePrice }(orderId);

        ISimplePaymentProcessor.Invoice memory updated = simplePP.getInvoiceData(orderId);
        assertEq(updated.buyer, buyerOne);
        assertEq(updated.amountPaid, _invoicePrice);
        assertEq(updated.status, simplePP.PAID());
        assertEq(updated.escrow, escrow);
    }
}
