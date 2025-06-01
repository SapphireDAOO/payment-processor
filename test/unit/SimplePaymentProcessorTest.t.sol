// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor, SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { SimplePaymentProcessorSetUp } from "../utils/SimplePaymentProcessorSetUp.sol";

error Unauthorized();

contract SimplePaymentProcessorTest is SimplePaymentProcessorSetUp {
    function test_storage_state() public view {
        assertEq(ppStorage.getFeeRate(), FEE);
        assertEq(ppStorage.getFeeReceiver(), feeReceiver);
        assertEq(simplePP.getNextInvoiceId(), 1);
        assertEq(simplePP.getDefaultHoldPeriod(), DEFAULT_HOLD_PERIOD);
    }

    function test_invoice_creation() public {
        uint256 cOneInvoicePrice = 100 ether;
        vm.startPrank(sellerOne);

        bytes32 invoiceKey = simplePP.createInvoice(cOneInvoicePrice);
        vm.stopPrank();

        ISimplePaymentProcessor.Invoice memory invoiceDataOne = simplePP.getInvoiceData(invoiceKey);
        assertEq(invoiceDataOne.seller, sellerOne);
        assertEq(invoiceDataOne.createdAt, block.timestamp);
        assertEq(invoiceDataOne.paymentTime, 0);
        assertEq(invoiceDataOne.price, 100 ether);
        assertEq(invoiceDataOne.amountPaid, 0);
        assertEq(invoiceDataOne.buyer, address(0));
        assertEq(invoiceDataOne.status, simplePP.CREATED());
        assertEq(invoiceDataOne.escrow, address(0));
        assertEq(invoiceDataOne.invoiceId, 1);
        assertEq(simplePP.getNextInvoiceId(), 2);

        vm.prank(sellerTwo);
        invoiceKey = simplePP.createInvoice(25 ether);

        ISimplePaymentProcessor.Invoice memory invoiceDataTwo = simplePP.getInvoiceData(invoiceKey);
        assertEq(invoiceDataTwo.seller, sellerTwo);
        assertEq(invoiceDataTwo.createdAt, block.timestamp);
        assertEq(invoiceDataTwo.paymentTime, 0);
        assertEq(invoiceDataTwo.price, 25 ether);
        assertEq(invoiceDataTwo.amountPaid, 0);
        assertEq(invoiceDataTwo.buyer, address(0));
        assertEq(invoiceDataTwo.status, simplePP.CREATED());
        assertEq(invoiceDataTwo.escrow, address(0));
        assertEq(invoiceDataTwo.invoiceId, 2);
        assertEq(simplePP.getNextInvoiceId(), 3);
    }

    function test_cancel_invoice() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        bytes32 invoiceKey = simplePP.createInvoice(invoicePrice);

        vm.expectRevert(Unauthorized.selector);
        simplePP.cancelInvoice(invoiceKey);

        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(invoiceKey);

        uint256 currentInvoiceStatus = simplePP.getInvoiceData(invoiceKey).status;

        vm.startPrank(sellerOne);
        vm.expectRevert(
            abi.encodeWithSelector(ISimplePaymentProcessor.InvalidInvoiceState.selector, currentInvoiceStatus)
        );
        simplePP.cancelInvoice(invoiceKey);

        invoiceKey = simplePP.createInvoice(invoicePrice);
        simplePP.cancelInvoice(invoiceKey);
        vm.stopPrank();

        assertEq(simplePP.getInvoiceData(invoiceKey).status, simplePP.CANCELLED());
    }

    function test_make_invoice_payment() public {
        // CREATE INVOICE
        uint256 invoicePrice = 100 ether;
        deal(sellerOne, 1);
        vm.startPrank(sellerOne);
        bytes32 invoiceKey = simplePP.createInvoice(invoicePrice);

        vm.expectRevert(ISimplePaymentProcessor.SellerCannotPayOwnedInvoice.selector);
        simplePP.makeInvoicePayment{ value: 1 }(invoiceKey);
        vm.stopPrank();

        vm.startPrank(buyerOne);

        // TRY INCORRECT PAYMENT

        uint256 s = invoicePrice + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ISimplePaymentProcessor.IncorrectPaymentAmount.selector, s, invoicePrice)
        );
        simplePP.makeInvoicePayment{ value: s }(invoiceKey);

        // TRY EXPIRED INVOICE
        vm.warp(block.timestamp + simplePP.VALID_PERIOD() + 1);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceIsNoLongerValid.selector);
        simplePP.makeInvoicePayment{ value: invoicePrice }(invoiceKey);

        // MAKE VALID PAYMENT
        vm.warp(block.timestamp - simplePP.VALID_PERIOD());
        address escrowAddress = simplePP.makeInvoicePayment{ value: invoicePrice }(invoiceKey);

        uint256 currentInvoiceStatus = simplePP.getInvoiceData(invoiceKey).status;
        // TRY ALREADY PAID INVOICE
        vm.expectRevert(
            abi.encodeWithSelector(ISimplePaymentProcessor.InvalidInvoiceState.selector, currentInvoiceStatus)
        );
        simplePP.makeInvoicePayment{ value: invoicePrice }(invoiceKey);
        vm.stopPrank();

        ISimplePaymentProcessor.Invoice memory invoiceData = simplePP.getInvoiceData(invoiceKey);

        assertEq(buyerOne.balance, INITIAL_BALANCE - invoicePrice);
        assertEq(escrowAddress.balance, invoicePrice);
        assertEq(escrowAddress.balance + address(simplePP).balance, invoicePrice);
        assertEq(invoiceData.escrow, escrowAddress);
        assertEq(invoiceData.status, simplePP.PAID());
        assertEq(invoiceData.buyer, buyerOne);
    }

    function test_payment_acceptance() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        bytes32 invoiceKey = simplePP.createInvoice(invoicePrice);

        vm.prank(sellerTwo);
        vm.expectRevert(Unauthorized.selector);
        simplePP.sellerAction(invoiceKey, false);

        vm.warp(block.number + 10);

        vm.prank(sellerOne);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceNotPaid.selector);
        simplePP.sellerAction(invoiceKey, true);

        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(invoiceKey);

        vm.prank(sellerOne);
        simplePP.sellerAction(invoiceKey, true);
        ISimplePaymentProcessor.Invoice memory i = simplePP.getInvoiceData(invoiceKey);
        uint256 fee = simplePP.calculateFee(i.price);
        assertEq(i.status, simplePP.ACCEPTED());
        assertEq(ppStorage.getFeeReceiver().balance, fee);
    }

    function test_payment_acceptance_after_acceptance_window() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        bytes32 invoiceKey = simplePP.createInvoice(invoicePrice);

        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(invoiceKey);

        vm.warp(block.timestamp + simplePP.ACCEPTANCE_WINDOW() + 1);
        vm.prank(sellerOne);
        vm.expectRevert(ISimplePaymentProcessor.AcceptanceWindowExceeded.selector);
        simplePP.sellerAction(invoiceKey, true);
    }

    function test_payer_refund_acceptance_window() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        bytes32 invoiceKey = simplePP.createInvoice(invoicePrice);

        // 10000
        uint256 balanceBeforePayment = buyerOne.balance;
        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(invoiceKey);

        vm.startPrank(buyerOne);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceNotEligibleForRefund.selector);
        simplePP.refundBuyerAfterWindow(invoiceKey);

        vm.warp(block.timestamp + simplePP.ACCEPTANCE_WINDOW() + 1);
        simplePP.refundBuyerAfterWindow(invoiceKey);
        vm.stopPrank();

        uint256 balanceAfterRefund = buyerOne.balance;

        assertEq(simplePP.getInvoiceData(invoiceKey).status, simplePP.REFUNDED());
        assertEq(balanceBeforePayment, balanceAfterRefund);
    }

    function test_payment_rejection() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        bytes32 invoiceKey = simplePP.createInvoice(invoicePrice);

        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(invoiceKey);
        uint256 buyerOneBalanceAfterPayment = address(buyerOne).balance;
        assertEq(buyerOneBalanceAfterPayment, INITIAL_BALANCE - invoicePrice);

        vm.prank(sellerOne);
        simplePP.sellerAction(invoiceKey, false);

        assertEq(simplePP.getInvoiceData(invoiceKey).status, simplePP.REJECTED());
        assertEq(buyerOne.balance, buyerOneBalanceAfterPayment + invoicePrice);
    }

    function test_default_hold_release_invoice() public {
        // CREATE
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        bytes32 invoiceKey = simplePP.createInvoice(invoicePrice);

        uint256 fee = simplePP.calculateFee(invoicePrice);

        // PAY
        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(invoiceKey);

        // // ACCEPT
        vm.prank(sellerOne);
        simplePP.sellerAction(invoiceKey, true);

        //RELEASE
        vm.expectRevert(Unauthorized.selector);
        simplePP.releaseInvoice(invoiceKey);

        vm.startPrank(sellerOne);
        vm.expectRevert(ISimplePaymentProcessor.HoldPeriodHasNotBeenExceeded.selector);
        simplePP.releaseInvoice(invoiceKey);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);
        simplePP.releaseInvoice(invoiceKey);

        vm.expectRevert(ISimplePaymentProcessor.InvoiceHasAlreadyBeenReleased.selector);
        simplePP.releaseInvoice(invoiceKey);
        vm.stopPrank();

        assertEq(sellerOne.balance, INITIAL_BALANCE + invoicePrice - fee);
        assertEq(simplePP.getInvoiceData(invoiceKey).status, simplePP.RELEASED());
    }

    function test_dynamic_hold_release_invoice() public {
        uint32 adminHoldPeriod = 25 days;

        vm.prank(admin);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceHasNotBeenAccepted.selector);
        simplePP.setInvoiceReleaseTime(keccak256(""), adminHoldPeriod);

        // CREATE
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        bytes32 invoiceKey = simplePP.createInvoice(invoicePrice);

        uint256 fee = simplePP.calculateFee(invoicePrice);

        // PAY
        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(invoiceKey);

        // ACCEPT
        vm.prank(sellerOne);
        simplePP.sellerAction(invoiceKey, true);

        vm.warp(block.timestamp + adminHoldPeriod + 1);
        vm.prank(sellerOne);
        simplePP.releaseInvoice(invoiceKey);

        assertEq(sellerOne.balance, INITIAL_BALANCE + invoicePrice - fee);
        assertEq(simplePP.getInvoiceData(invoiceKey).status, simplePP.RELEASED());
    }
}
