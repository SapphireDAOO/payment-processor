// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor } from "../../src/interface/ISimplePaymentProcessor.sol";
import { SimplePaymentProcessorSetUp } from "../utils/SimplePaymentProcessorSetUp.sol";

contract SimplePaymentProcessorFuzzTest is SimplePaymentProcessorSetUp {
    function testFuzz_invoice_creation(uint256 _amount) public {
        vm.assume(_amount > 1 ether);
        vm.prank(sellerOne);
        uint216 orderId = simplePP.createInvoice(_amount, "", false);
        ISimplePaymentProcessor.Invoice memory invoiceData = simplePP.getInvoiceData(orderId);
        assertEq(invoiceData.seller, sellerOne);
        assertEq(invoiceData.createdAt, block.timestamp);
        assertEq(invoiceData.paidAt, 0);
        assertEq(invoiceData.price, _amount);
        assertEq(invoiceData.balance, 0);
        assertEq(invoiceData.buyer, address(0));
        assertEq(invoiceData.status, simplePP.CREATED());
        assertEq(invoiceData.escrow, address(0));
        assertEq(invoiceData.invoiceNonce, 1);
        assertEq(simplePP.getNextInvoiceId(), 2);
    }

    function testFuzz_createAndPayInvoice(uint256 _invoicePrice) public {
        _invoicePrice = bound(_invoicePrice, 1 ether, 1000 ether);

        vm.prank(sellerOne);
        uint216 orderId = simplePP.createInvoice(_invoicePrice, "", false);

        ISimplePaymentProcessor.Invoice memory invoice = simplePP.getInvoiceData(orderId);
        assertEq(invoice.price, _invoicePrice);
        assertEq(invoice.status, simplePP.CREATED());

        vm.prank(buyerOne);
        address escrow = simplePP.pay{ value: _invoicePrice }(orderId, "", false);

        ISimplePaymentProcessor.Invoice memory updated = simplePP.getInvoiceData(orderId);
        assertEq(updated.buyer, buyerOne);
        assertEq(updated.balance, _invoicePrice);
        assertEq(updated.status, simplePP.PAID());
        assertEq(updated.escrow, escrow);
    }
}
