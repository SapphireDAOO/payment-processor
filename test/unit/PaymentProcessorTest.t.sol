// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SetUp } from "../SetUp.sol";
import { IPaymentProcessorV1, PaymentProcessorV1 } from "../../src/PaymentProcessorV1.sol";

error Unauthorized();

contract PaymentProcessorTest is SetUp {
    function test_storage_state() public view {
        assertEq(pp.getFeeRate(), FEE_RATE);
        assertEq(pp.getFeeReceiver(), feeReceiver);
        assertEq(pp.getNextInvoiceId(), 1);
        assertEq(pp.getDefaultHoldPeriod(), DEFAULT_HOLD_PERIOD);
    }

    function test_setters() public {
        vm.startPrank(owner);

        vm.expectRevert(IPaymentProcessorV1.FeeValueCanNotBeZero.selector);
        pp.setFeeRate(0);

        vm.expectRevert(IPaymentProcessorV1.HoldPeriodCanNotBeZero.selector);
        pp.setDefaultHoldPeriod(0);

        vm.expectRevert(IPaymentProcessorV1.ZeroAddressIsNotAllowed.selector);
        pp.setFeeReceiversAddress(address(0));
        vm.stopPrank();
    }

    function test_invoice_creation() public {
        uint256 cOneInvoicePrice = 100 ether;
        vm.startPrank(creatorOne);

        pp.createInvoice(cOneInvoicePrice);
        vm.stopPrank();

        IPaymentProcessorV1.Invoice memory invoiceDataOne = pp.getInvoiceData(1);
        assertEq(invoiceDataOne.creator, creatorOne);
        assertEq(invoiceDataOne.createdAt, block.timestamp);
        assertEq(invoiceDataOne.paymentTime, 0);
        assertEq(invoiceDataOne.price, 100 ether);
        assertEq(invoiceDataOne.amountPaid, 0);
        assertEq(invoiceDataOne.payer, address(0));
        assertEq(invoiceDataOne.status, pp.CREATED());
        assertEq(invoiceDataOne.escrow, address(0));
        assertEq(pp.getNextInvoiceId(), 2);

        vm.prank(creatorTwo);
        pp.createInvoice(25 ether);

        IPaymentProcessorV1.Invoice memory invoiceDataTwo = pp.getInvoiceData(2);
        assertEq(invoiceDataTwo.creator, creatorTwo);
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
        vm.prank(creatorOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);

        vm.expectRevert(Unauthorized.selector);
        pp.cancelInvoice(invoiceId);

        vm.prank(payerOne);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        uint256 currentInvoiceStatus = pp.getInvoiceData(invoiceId).status;

        vm.startPrank(creatorOne);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPaymentProcessorV1.InvalidInvoiceState.selector, currentInvoiceStatus
            )
        );
        pp.cancelInvoice(invoiceId);

        uint256 newInvoiceId = pp.createInvoice(invoicePrice);
        pp.cancelInvoice(newInvoiceId);
        vm.stopPrank();

        assertEq(pp.getInvoiceData(newInvoiceId).status, pp.CANCELLED());
    }

    function test_make_invoice_payment() public {
        // CREATE INVOICE
        uint256 invoicePrice = 100 ether;
        deal(creatorOne, 1);
        vm.startPrank(creatorOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);
        uint256 fee = pp.calculateFee(invoicePrice);

        vm.expectRevert(IPaymentProcessorV1.CreatorCannotPayOwnedInvoice.selector);
        pp.makeInvoicePayment{ value: 1 }(invoiceId);
        vm.stopPrank();

        vm.startPrank(payerOne);
        // TRY VERY LOW PAYMENT
        vm.expectRevert(IPaymentProcessorV1.ValueIsTooLow.selector);
        pp.makeInvoicePayment{ value: 0 }(invoiceId);

        // TRY EXCESSIVE PAYMENT

        vm.expectRevert(IPaymentProcessorV1.ExcessivePayment.selector);
        pp.makeInvoicePayment{ value: invoicePrice + 1 }(invoiceId);

        // TRY EXPIRED INVOICE
        vm.warp(block.timestamp + pp.VALID_PERIOD() + 1);
        vm.expectRevert(IPaymentProcessorV1.InvoiceIsNoLongerValid.selector);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        // MAKE VALID PAYMENT
        vm.warp(block.timestamp - pp.VALID_PERIOD());
        address escrowAddress = pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        uint256 currentInvoiceStatus = pp.getInvoiceData(invoiceId).status;
        // TRY ALREADY PAID INVOICE
        vm.expectRevert(
            abi.encodeWithSelector(
                IPaymentProcessorV1.InvalidInvoiceState.selector, currentInvoiceStatus
            )
        );
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);
        vm.stopPrank();

        IPaymentProcessorV1.Invoice memory invoiceData = pp.getInvoiceData(invoiceId);

        assertEq(payerOne.balance, PAYER_ONE_INITIAL_BALANCE - invoicePrice);
        assertEq(escrowAddress.balance, invoicePrice - fee);
        assertEq(address(pp).balance, fee);
        assertEq(escrowAddress.balance + address(pp).balance, invoicePrice);
        assertEq(invoiceData.escrow, escrowAddress);
        assertEq(invoiceData.status, pp.PAID());
        assertEq(invoiceData.payer, payerOne);
    }

    function test_payment_acceptance() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(creatorOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);

        vm.prank(creatorTwo);
        vm.expectRevert(Unauthorized.selector);
        pp.creatorsAction(invoiceId, false);

        vm.warp(block.number + 10);

        vm.prank(creatorOne);
        vm.expectRevert(IPaymentProcessorV1.InvoiceNotPaid.selector);
        pp.creatorsAction(invoiceId, true);

        vm.prank(payerOne);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        vm.prank(creatorOne);
        pp.creatorsAction(invoiceId, true);
        assertEq(pp.getInvoiceData(invoiceId).status, pp.ACCEPTED());
    }

    function test_payment_acceptance_after_acceptance_window() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(creatorOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);

        vm.prank(payerOne);
        invoicePrice = 0.1 ether;
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        vm.warp(block.timestamp + pp.ACCEPTANCE_WINDOW() + 1);
        vm.prank(creatorOne);
        vm.expectRevert(IPaymentProcessorV1.AcceptanceWindowExceeded.selector);
        pp.creatorsAction(invoiceId, true);
    }

    function test_payer_refund_acceptance_window() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(creatorOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);
        uint256 fee = pp.calculateFee(invoicePrice);

        // 10000
        uint256 balanceBeforePayment = payerOne.balance;
        vm.prank(payerOne);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);
        // 10000 - 100 = 9900

        vm.startPrank(payerOne);
        vm.expectRevert(IPaymentProcessorV1.InvoiceNotEligibleForRefund.selector);
        pp.refundPayerAfterWindow(invoiceId);

        vm.warp(block.timestamp + pp.ACCEPTANCE_WINDOW() + 1);
        pp.refundPayerAfterWindow(invoiceId);
        vm.stopPrank();

        // 9900 + 99 = 9999

        uint256 balanceAfterRefund = payerOne.balance;

        assertEq(pp.getInvoiceData(invoiceId).status, pp.REFUNDED());
        assertEq(balanceBeforePayment - fee, balanceAfterRefund);
    }

    function test_payment_rejection() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(creatorOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);
        uint256 fee = pp.calculateFee(invoicePrice);

        vm.prank(payerOne);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);
        uint256 payerOneBalanceAfterPayment = address(payerOne).balance;
        assertEq(payerOneBalanceAfterPayment, PAYER_ONE_INITIAL_BALANCE - invoicePrice);

        vm.prank(creatorOne);
        pp.creatorsAction(invoiceId, false);

        assertEq(pp.getInvoiceData(invoiceId).status, pp.REJECTED());
        assertEq(address(payerOne).balance, payerOneBalanceAfterPayment + invoicePrice - fee);
    }

    function test_default_hold_release_invoice() public {
        // CREATE
        uint256 invoicePrice = 100 ether;
        vm.prank(creatorOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);

        uint256 fee = pp.calculateFee(invoicePrice);

        // PAY
        vm.prank(payerOne);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        // // ACCEPT
        vm.prank(creatorOne);
        pp.creatorsAction(invoiceId, true);

        //RELEASE
        vm.expectRevert(Unauthorized.selector);
        pp.releaseInvoice(invoiceId);

        vm.startPrank(creatorOne);
        vm.expectRevert(IPaymentProcessorV1.HoldPeriodHasNotBeenExceeded.selector);
        pp.releaseInvoice(invoiceId);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);
        pp.releaseInvoice(invoiceId);

        vm.expectRevert(IPaymentProcessorV1.InvoiceHasAlreadyBeenReleased.selector);
        pp.releaseInvoice(invoiceId);
        vm.stopPrank();

        assertEq(creatorOne.balance, invoicePrice - fee);
        assertEq(pp.getInvoiceData(invoiceId).status, pp.RELEASED());
    }

    function test_dynamic_hold_release_invoice() public {
        uint32 adminHoldPeriod = 25 days;

        vm.prank(owner);
        vm.expectRevert(IPaymentProcessorV1.InvoiceHasNotBeenAccepted.selector);
        pp.setInvoiceReleaseTime(1, adminHoldPeriod);

        // CREATE
        uint256 invoicePrice = 100 ether;
        vm.prank(creatorOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);

        uint256 fee = pp.calculateFee(invoicePrice);

        // PAY
        vm.prank(payerOne);
        pp.makeInvoicePayment{ value: invoicePrice }(invoiceId);

        // ACCEPT
        vm.prank(creatorOne);
        pp.creatorsAction(invoiceId, true);

        vm.warp(block.timestamp + adminHoldPeriod + 1);
        vm.prank(creatorOne);
        pp.releaseInvoice(invoiceId);

        assertEq(creatorOne.balance, invoicePrice - fee);
        assertEq(pp.getInvoiceData(invoiceId).status, pp.RELEASED());
    }

    function test_Ether_Withdrawal() public {
        // CREATE INVOICE
        uint256 invoicePrice = 100 ether;
        vm.prank(creatorOne);
        uint256 invoiceIdOne = pp.createInvoice(invoicePrice);

        uint256 fee = pp.calculateFee(invoicePrice);

        pp.makeInvoicePayment{ value: invoicePrice }(invoiceIdOne);

        vm.expectRevert(Unauthorized.selector);
        pp.withdrawFees();

        vm.prank(feeReceiver);
        pp.withdrawFees();
        assertEq(address(feeReceiver).balance, fee);

        vm.prank(creatorTwo);
        uint256 invoiceIdTwo = pp.createInvoice(invoicePrice);

        pp.makeInvoicePayment{ value: invoicePrice }(invoiceIdTwo);

        uint256 receiversBalanceBefore = address(feeReceiver).balance;
        vm.prank(owner);
        pp.withdrawFees();
        assertEq(address(feeReceiver).balance, fee + receiversBalanceBefore);
        assertEq(address(pp).balance, 0);
    }
}
