// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { SimplePaymentProcessorSetUp } from "../utils/SimplePaymentProcessorSetUp.sol";

contract SimplePaymentProcessorInteractions is SimplePaymentProcessorSetUp {
    string POLYGON_MAINNET_RPC = vm.envString("MAINNET_RPC");

    // Real Polygon mainnet address with native POL balance
    address constant NATIVE_TOKEN_BUYER = 0x5e86A14B06a4001cA83688cc06568A0c07425f63;

    uint256 constant INVOICE_PRICE = 10 ether;

    function setUp() public override {
        uint256 fork = vm.createFork(POLYGON_MAINNET_RPC);
        vm.selectFork(fork);
        super.setUp();
    }

    function test_payInvoice() public {
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(INVOICE_PRICE, "", false);

        vm.prank(NATIVE_TOKEN_BUYER);
        address escrow = simplePP.pay{ value: INVOICE_PRICE }(invoiceId, "", false);

        ISimplePaymentProcessor.Invoice memory inv = simplePP.getInvoiceData(invoiceId);

        assertEq(inv.state, simplePP.PAID());
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

        assertEq(simplePP.getInvoiceData(invoiceId).state, simplePP.CANCELLED());
    }

    function test_rejectPayment() public {
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(INVOICE_PRICE, "", false);

        vm.prank(NATIVE_TOKEN_BUYER);
        simplePP.pay{ value: INVOICE_PRICE }(invoiceId, "", false);

        uint256 buyerBalanceBefore = NATIVE_TOKEN_BUYER.balance;

        vm.prank(sellerOne);
        simplePP.rejectPayment(invoiceId);

        assertEq(simplePP.getInvoiceData(invoiceId).state, simplePP.REJECTED());
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

        assertEq(feeReceiver.balance, feeReceiverBefore + expectedFee);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);

        vm.prank(sellerOne);
        simplePP.release(invoiceId);

        ISimplePaymentProcessor.Invoice memory inv = simplePP.getInvoiceData(invoiceId);

        assertEq(inv.state, simplePP.RELEASED());
        assertEq(inv.balance, 0);
        assertEq(inv.escrow.balance, 0);
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

        assertEq(simplePP.getInvoiceData(invoiceId).state, simplePP.REFUNDED());
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

        assertEq(inv.state, simplePP.RELEASED());
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

        assertEq(simplePP.getInvoiceData(invoiceId).state, simplePP.REFUNDED());
        assertEq(NATIVE_TOKEN_BUYER.balance, buyerBalanceBefore + INVOICE_PRICE);
    }
}
