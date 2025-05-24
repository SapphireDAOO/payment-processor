// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentProcessorV1, PaymentProcessorV1 } from "../../src/PaymentProcessorV1.sol";
import { V1 } from "../util/V1.sol";

error Unauthorized();

contract PaymentProcessorTest is V1 {
    function test_storage_state() public view {
        assertEq(ppStorage.getFeeRate(), FEE);
        assertEq(ppStorage.getFeeReceiver(), feeReceiver);
        assertEq(pp.getNextInvoiceId(), 1);
        assertEq(pp.getDefaultHoldPeriod(), DEFAULT_HOLD_PERIOD);
    }

    function test_invoice_creation() public {
        uint256 cOneInvoicePrice = 100 ether;
        vm.startPrank(sellerOne);

        pp.createInvoice(cOneInvoicePrice);
        vm.stopPrank();

        IPaymentProcessorV1.Invoice memory invoiceDataOne = pp.getInvoiceData(1);
        assertEq(invoiceDataOne.creator, sellerOne);
        assertEq(invoiceDataOne.createdAt, block.timestamp);
        assertEq(invoiceDataOne.paymentTime, 0);
        assertEq(invoiceDataOne.price, 100 ether);
        assertEq(invoiceDataOne.amountPaid, 0);
        assertEq(invoiceDataOne.payer, address(0));
        assertEq(invoiceDataOne.status, pp.CREATED());
        assertEq(invoiceDataOne.escrow, address(0));
        assertEq(pp.getNextInvoiceId(), 2);

        vm.prank(sellerTwo);
        pp.createInvoice(25 ether);

        IPaymentProcessorV1.Invoice memory invoiceDataTwo = pp.getInvoiceData(2);
        assertEq(invoiceDataTwo.creator, sellerTwo);
        assertEq(invoiceDataTwo.createdAt, block.timestamp);
        assertEq(invoiceDataTwo.paymentTime, 0);
        assertEq(invoiceDataTwo.price, 25 ether);
        assertEq(invoiceDataTwo.amountPaid, 0);
        assertEq(invoiceDataTwo.payer, address(0));
        assertEq(invoiceDataTwo.status, pp.CREATED());
        assertEq(invoiceDataTwo.escrow, address(0));
        assertEq(pp.getNextInvoiceId(), 3);
    }

    function test_cancel_invoice() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);

        vm.expectRevert(Unauthorized.selector);
        pp.cancelInvoice(invoiceId);

        vm.prank(buyerOne);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        uint256 currentInvoiceStatus = pp.getInvoiceData(invoiceId).status;

        vm.startPrank(sellerOne);
        vm.expectRevert(abi.encodeWithSelector(IPaymentProcessorV1.InvalidInvoiceState.selector, currentInvoiceStatus));
        pp.cancelInvoice(invoiceId);

        uint256 newInvoiceId = pp.createInvoice(invoicePrice);
        pp.cancelInvoice(newInvoiceId);
        vm.stopPrank();

        assertEq(pp.getInvoiceData(newInvoiceId).status, pp.CANCELLED());
    }

    function test_make_invoice_payment() public {
        // CREATE INVOICE
        uint256 invoicePrice = 100 ether;
        deal(sellerOne, 1);
        vm.startPrank(sellerOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);

        vm.expectRevert(IPaymentProcessorV1.CreatorCannotPayOwnedInvoice.selector);
        pp.makeInvoicePayment{ value: 1 }(invoiceId);
        vm.stopPrank();

        vm.startPrank(buyerOne);

        // TRY INCORRECT PAYMENT

        uint256 s = invoicePrice + 1;
        vm.expectRevert(abi.encodeWithSelector(IPaymentProcessorV1.IncorrectPaymentAmount.selector, s, invoicePrice));
        pp.makeInvoicePayment{ value: s }(invoiceId);

        // TRY EXPIRED INVOICE
        vm.warp(block.timestamp + pp.VALID_PERIOD() + 1);
        vm.expectRevert(IPaymentProcessorV1.InvoiceIsNoLongerValid.selector);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        // MAKE VALID PAYMENT
        vm.warp(block.timestamp - pp.VALID_PERIOD());
        address escrowAddress = pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        uint256 currentInvoiceStatus = pp.getInvoiceData(invoiceId).status;
        // TRY ALREADY PAID INVOICE
        vm.expectRevert(abi.encodeWithSelector(IPaymentProcessorV1.InvalidInvoiceState.selector, currentInvoiceStatus));
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);
        vm.stopPrank();

        IPaymentProcessorV1.Invoice memory invoiceData = pp.getInvoiceData(invoiceId);

        assertEq(buyerOne.balance, INITIAL_BALANCE - invoicePrice);
        assertEq(escrowAddress.balance, invoicePrice);
        assertEq(escrowAddress.balance + address(pp).balance, invoicePrice);
        assertEq(invoiceData.escrow, escrowAddress);
        assertEq(invoiceData.status, pp.PAID());
        assertEq(invoiceData.payer, buyerOne);
    }

    function test_payment_acceptance() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);

        vm.prank(sellerTwo);
        vm.expectRevert(Unauthorized.selector);
        pp.creatorsAction(invoiceId, false);

        vm.warp(block.number + 10);

        vm.prank(sellerOne);
        vm.expectRevert(IPaymentProcessorV1.InvoiceNotPaid.selector);
        pp.creatorsAction(invoiceId, true);

        vm.prank(buyerOne);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        vm.prank(sellerOne);
        pp.creatorsAction(invoiceId, true);
        IPaymentProcessorV1.Invoice memory i = pp.getInvoiceData(invoiceId);
        uint256 fee = pp.calculateFee(i.price);
        assertEq(i.status, pp.ACCEPTED());
        assertEq(ppStorage.getFeeReceiver().balance, fee);
    }

    function test_payment_acceptance_after_acceptance_window() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);

        vm.prank(buyerOne);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        vm.warp(block.timestamp + pp.ACCEPTANCE_WINDOW() + 1);
        vm.prank(sellerOne);
        vm.expectRevert(IPaymentProcessorV1.AcceptanceWindowExceeded.selector);
        pp.creatorsAction(invoiceId, true);
    }

    function test_payer_refund_acceptance_window() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);

        // 10000
        uint256 balanceBeforePayment = buyerOne.balance;
        vm.prank(buyerOne);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        vm.startPrank(buyerOne);
        vm.expectRevert(IPaymentProcessorV1.InvoiceNotEligibleForRefund.selector);
        pp.refundPayerAfterWindow(invoiceId);

        vm.warp(block.timestamp + pp.ACCEPTANCE_WINDOW() + 1);
        pp.refundPayerAfterWindow(invoiceId);
        vm.stopPrank();

        uint256 balanceAfterRefund = buyerOne.balance;

        assertEq(pp.getInvoiceData(invoiceId).status, pp.REFUNDED());
        assertEq(balanceBeforePayment, balanceAfterRefund);
    }

    function test_payment_rejection() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);

        vm.prank(buyerOne);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);
        uint256 buyerOneBalanceAfterPayment = address(buyerOne).balance;
        assertEq(buyerOneBalanceAfterPayment, INITIAL_BALANCE - invoicePrice);

        vm.prank(sellerOne);
        pp.creatorsAction(invoiceId, false);

        assertEq(pp.getInvoiceData(invoiceId).status, pp.REJECTED());
        assertEq(buyerOne.balance, buyerOneBalanceAfterPayment + invoicePrice);
    }

    function test_default_hold_release_invoice() public {
        // CREATE
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);

        uint256 fee = pp.calculateFee(invoicePrice);

        // PAY
        vm.prank(buyerOne);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        // // ACCEPT
        vm.prank(sellerOne);
        pp.creatorsAction(invoiceId, true);

        //RELEASE
        vm.expectRevert(Unauthorized.selector);
        pp.releaseInvoice(invoiceId);

        vm.startPrank(sellerOne);
        vm.expectRevert(IPaymentProcessorV1.HoldPeriodHasNotBeenExceeded.selector);
        pp.releaseInvoice(invoiceId);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);
        pp.releaseInvoice(invoiceId);

        vm.expectRevert(IPaymentProcessorV1.InvoiceHasAlreadyBeenReleased.selector);
        pp.releaseInvoice(invoiceId);
        vm.stopPrank();

        assertEq(sellerOne.balance, INITIAL_BALANCE + invoicePrice - fee);
        assertEq(pp.getInvoiceData(invoiceId).status, pp.RELEASED());
    }

    function test_dynamic_hold_release_invoice() public {
        uint32 adminHoldPeriod = 25 days;

        vm.prank(admin);
        vm.expectRevert(IPaymentProcessorV1.InvoiceHasNotBeenAccepted.selector);
        pp.setInvoiceReleaseTime(1, adminHoldPeriod);

        // CREATE
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);

        uint256 fee = pp.calculateFee(invoicePrice);

        // PAY
        vm.prank(buyerOne);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        // ACCEPT
        vm.prank(sellerOne);
        pp.creatorsAction(invoiceId, true);

        vm.warp(block.timestamp + adminHoldPeriod + 1);
        vm.prank(sellerOne);
        pp.releaseInvoice(invoiceId);

        assertEq(sellerOne.balance, INITIAL_BALANCE + invoicePrice - fee);
        assertEq(pp.getInvoiceData(invoiceId).status, pp.RELEASED());
    }
}
