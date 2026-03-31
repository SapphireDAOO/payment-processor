// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { SimplePaymentProcessorSetUp } from "../utils/SimplePaymentProcessorSetUp.sol";

import { PAID, REJECTED, CANCELED, REFUNDED, RELEASED } from "src/constants/Simple.sol";

contract SimplePaymentProcessorInteractions is SimplePaymentProcessorSetUp {
    string MAINNET_RPC = vm.envString("MAINNET_RPC");

    address constant NATIVE_TOKEN_BUYER = 0xBefa750Ed568Cc84970eB4FD506aF4FF599c42D0;

    uint256 constant INVOICE_PRICE = 10 ether;

    function setUp() public override {
        uint256 fork = vm.createFork(MAINNET_RPC);
        vm.selectFork(fork);
        super.setUp();
    }

    function test_payInvoice() public {
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(INVOICE_PRICE, "", false);

        vm.prank(NATIVE_TOKEN_BUYER);
        address escrow = simplePP.pay{ value: INVOICE_PRICE }(invoiceId, "", false);

        ISimplePaymentProcessor.Invoice memory inv = simplePP.getInvoiceData(invoiceId);

        assertEq(inv.state, PAID);
        assertEq(inv.buyer, NATIVE_TOKEN_BUYER);
        assertEq(inv.escrow, escrow);
        assertEq(inv.balance, INVOICE_PRICE);
        assertEq(escrow.balance, INVOICE_PRICE);
    }

    function test_sellerCancelInvoice() public {
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(INVOICE_PRICE, "", false);

        vm.prank(sellerOne);
        simplePP.cancelInvoice(invoiceId);

        assertEq(simplePP.getInvoiceData(invoiceId).state, CANCELED);
    }

    function test_rejectPayment() public {
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(INVOICE_PRICE, "", false);

        vm.prank(NATIVE_TOKEN_BUYER);
        simplePP.pay{ value: INVOICE_PRICE }(invoiceId, "", false);

        uint256 buyerBalanceBefore = NATIVE_TOKEN_BUYER.balance;

        vm.prank(sellerOne);
        simplePP.rejectPayment(invoiceId);

        assertEq(simplePP.getInvoiceData(invoiceId).state, REJECTED);
        assertEq(NATIVE_TOKEN_BUYER.balance, buyerBalanceBefore + INVOICE_PRICE);
    }

    function test_acceptAndReleaseInvoice() public {
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(INVOICE_PRICE, "", false);

        vm.prank(NATIVE_TOKEN_BUYER);
        simplePP.pay{ value: INVOICE_PRICE }(invoiceId, "", false);

        uint256 expectedFee = simplePP.calculateFee(INVOICE_PRICE);
        uint256 feeReceiverBefore = feeReceiver.balance;
        uint256 sellerBalanceBefore = sellerOne.balance;

        vm.prank(sellerOne);
        simplePP.acceptPayment(invoiceId);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);

        vm.prank(sellerOne);
        simplePP.release(invoiceId);

        ISimplePaymentProcessor.Invoice memory inv = simplePP.getInvoiceData(invoiceId);

        assertEq(inv.state, RELEASED);
        assertEq(inv.balance, 0);
        assertEq(inv.escrow.balance, 0);
        assertEq(feeReceiver.balance, feeReceiverBefore + expectedFee);
        assertEq(sellerOne.balance, sellerBalanceBefore + (INVOICE_PRICE - expectedFee));
    }

    function test_refundBuyerAfterDecisionWindowExpires() public {
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(INVOICE_PRICE, "", false);

        vm.prank(NATIVE_TOKEN_BUYER);
        simplePP.pay{ value: INVOICE_PRICE }(invoiceId, "", false);

        ISimplePaymentProcessor.Invoice memory inv = simplePP.getInvoiceData(invoiceId);
        uint256 buyerBalanceBefore = NATIVE_TOKEN_BUYER.balance;

        vm.warp(uint256(inv.expiresAt) + 1);
        simplePP.refundBuyer(invoiceId);

        assertEq(simplePP.getInvoiceData(invoiceId).state, REFUNDED);
        assertEq(NATIVE_TOKEN_BUYER.balance, buyerBalanceBefore + INVOICE_PRICE);
    }

    function test_performUpkeep_autoReleasesAcceptedInvoice() public {
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(INVOICE_PRICE, "", false);

        vm.prank(NATIVE_TOKEN_BUYER);
        simplePP.pay{ value: INVOICE_PRICE }(invoiceId, "", false);

        vm.prank(sellerOne);
        simplePP.acceptPayment(invoiceId);

        uint256 expectedFee = simplePP.calculateFee(INVOICE_PRICE);
        uint256 sellerBalanceBefore = sellerOne.balance;

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);

        vm.prank(admin);
        simplePP.performUpkeep("");

        ISimplePaymentProcessor.Invoice memory inv = simplePP.getInvoiceData(invoiceId);

        assertEq(inv.state, RELEASED);
        assertEq(sellerOne.balance, sellerBalanceBefore + (INVOICE_PRICE - expectedFee));
    }

    function test_performUpkeep_autoRefundsBuyerWhenSellerDoesNotAct() public {
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(INVOICE_PRICE, "", false);

        vm.prank(NATIVE_TOKEN_BUYER);
        simplePP.pay{ value: INVOICE_PRICE }(invoiceId, "", false);

        ISimplePaymentProcessor.Invoice memory inv = simplePP.getInvoiceData(invoiceId);
        uint256 buyerBalanceBefore = NATIVE_TOKEN_BUYER.balance;

        vm.warp(uint256(inv.expiresAt) + 1);

        vm.prank(admin);
        simplePP.performUpkeep("");

        assertEq(simplePP.getInvoiceData(invoiceId).state, REFUNDED);
        assertEq(NATIVE_TOKEN_BUYER.balance, buyerBalanceBefore + INVOICE_PRICE);
    }
}
