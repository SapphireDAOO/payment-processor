// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor } from "../../src/interface/ISimplePaymentProcessor.sol";
import { SimplePaymentProcessorSetUp } from "../utils/SimplePaymentProcessorSetUp.sol";

contract SimplePaymentProcessorFuzzTest is SimplePaymentProcessorSetUp {
    function test_invoiceCreation(uint256 _amount) public {
        _amount = bound(_amount, 1 ether, 1000 ether);
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(_amount, "", false);
        ISimplePaymentProcessor.Invoice memory invoiceData = simplePP.getInvoiceData(invoiceId);
        assertEq(invoiceData.seller, sellerOne);
        assertEq(invoiceData.createdAt, block.timestamp);
        assertEq(invoiceData.paidAt, 0);
        assertEq(invoiceData.price, _amount);
        assertEq(invoiceData.balance, 0);
        assertEq(invoiceData.buyer, address(0));
        assertEq(invoiceData.status, simplePP.CREATED());
        assertEq(invoiceData.escrow, address(0));
        assertEq(invoiceData.invoiceNonce, 1);
        assertEq(simplePP.getNextInvoiceNonce(), 2);
    }

    function test_createAndPayInvoice(uint256 _invoicePrice) public {
        _invoicePrice = bound(_invoicePrice, 1 ether, 1000 ether);

        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(_invoicePrice, "", false);

        ISimplePaymentProcessor.Invoice memory invoice = simplePP.getInvoiceData(invoiceId);
        assertEq(invoice.price, _invoicePrice);
        assertEq(invoice.status, simplePP.CREATED());

        vm.prank(buyerOne);
        address escrow = simplePP.pay{ value: _invoicePrice }(invoiceId, "", false);

        ISimplePaymentProcessor.Invoice memory updated = simplePP.getInvoiceData(invoiceId);
        assertEq(updated.buyer, buyerOne);
        assertEq(updated.balance, _invoicePrice);
        assertEq(updated.status, simplePP.PAID());
        assertEq(updated.escrow, escrow);
    }

    function test_acceptAndRelease(uint256 _invoicePrice) public {
        _invoicePrice = bound(_invoicePrice, 1 ether, 1000 ether);

        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(_invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: _invoicePrice }(invoiceId, "", false);

        uint256 feeReceiverBefore = feeReceiver.balance;

        vm.prank(sellerOne);
        simplePP.acceptPayment(invoiceId);

        uint256 expectedFee = simplePP.calculateFee(_invoicePrice);
        assertEq(feeReceiver.balance, feeReceiverBefore + expectedFee);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);

        uint256 sellerBefore = sellerOne.balance;

        vm.prank(sellerOne);
        simplePP.release(invoiceId);

        ISimplePaymentProcessor.Invoice memory inv = simplePP.getInvoiceData(invoiceId);
        assertEq(inv.status, simplePP.RELEASED());
        assertEq(sellerOne.balance, sellerBefore + (_invoicePrice - expectedFee));
        assertEq(feeReceiver.balance, feeReceiverBefore + expectedFee);
    }

    function test_rejectPayment(uint256 _invoicePrice) public {
        _invoicePrice = bound(_invoicePrice, 1 ether, 1000 ether);

        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(_invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: _invoicePrice }(invoiceId, "", false);

        uint256 buyerBefore = buyerOne.balance;

        vm.prank(sellerOne);
        simplePP.rejectPayment(invoiceId);

        ISimplePaymentProcessor.Invoice memory inv = simplePP.getInvoiceData(invoiceId);
        assertEq(inv.status, simplePP.REJECTED());
        assertEq(buyerOne.balance, buyerBefore + _invoicePrice);
    }

    function test_cancelInvoice(uint256 _invoicePrice) public {
        _invoicePrice = bound(_invoicePrice, 1 ether, 1000 ether);

        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(_invoicePrice, "", false);

        vm.prank(sellerOne);
        simplePP.cancelInvoice(invoiceId);

        ISimplePaymentProcessor.Invoice memory inv = simplePP.getInvoiceData(invoiceId);
        assertEq(inv.status, simplePP.CANCELLED());
        assertEq(inv.escrow, address(0));
    }

    function test_calculateFee(uint256 _amount) public view {
        _amount = bound(_amount, 0, type(uint256).max / FEE_RATE);

        uint256 fee = simplePP.calculateFee(_amount);
        uint256 expected = (_amount * FEE_RATE) / simplePP.BASIS_POINTS();

        assertEq(fee, expected);
    }
}
