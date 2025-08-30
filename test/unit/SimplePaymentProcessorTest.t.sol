// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { SimplePaymentProcessorSetUp } from "../utils/SimplePaymentProcessorSetUp.sol";

error NotAuthorized();

contract SimplePaymentProcessorTest is SimplePaymentProcessorSetUp {
    function test_storage_state() public view {
        assertEq(ppStorage.getFeeRate(), FEE_RATE);
        assertEq(ppStorage.getFeeReceiver(), feeReceiver);
        assertEq(simplePP.getNextInvoiceId(), 1);
        assertEq(ppStorage.getDefaultHoldPeriod(), DEFAULT_HOLD_PERIOD);
    }

    function test_invoice_creation() public {
        uint256 cOneInvoicePrice = 100 ether;
        vm.startPrank(sellerOne);

        bytes32 orderId = simplePP.createInvoice(cOneInvoicePrice);
        vm.stopPrank();

        ISimplePaymentProcessor.Invoice memory invoiceDataOne = simplePP.getInvoiceData(orderId);
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
        orderId = simplePP.createInvoice(25 ether);

        ISimplePaymentProcessor.Invoice memory invoiceDataTwo = simplePP.getInvoiceData(orderId);
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
        bytes32 orderId = simplePP.createInvoice(invoicePrice);

        vm.expectRevert(NotAuthorized.selector);
        simplePP.cancelInvoice(orderId);

        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(orderId);

        uint256 currentInvoiceStatus = simplePP.getInvoiceData(orderId).status;

        vm.startPrank(sellerOne);
        vm.expectRevert(
            abi.encodeWithSelector(ISimplePaymentProcessor.InvalidInvoiceState.selector, currentInvoiceStatus)
        );
        simplePP.cancelInvoice(orderId);

        orderId = simplePP.createInvoice(invoicePrice);
        simplePP.cancelInvoice(orderId);
        vm.stopPrank();

        assertEq(simplePP.getInvoiceData(orderId).status, simplePP.CANCELLED());
    }

    function test_make_invoice_payment() public {
        // CREATE INVOICE
        uint256 invoicePrice = 100 ether;
        deal(sellerOne, 1);
        vm.startPrank(sellerOne);
        bytes32 orderId = simplePP.createInvoice(invoicePrice);

        vm.expectRevert(ISimplePaymentProcessor.SellerCannotPayOwnedInvoice.selector);
        simplePP.makeInvoicePayment{ value: 1 }(orderId);
        vm.stopPrank();

        vm.startPrank(buyerOne);

        // TRY INCORRECT PAYMENT

        uint256 s = invoicePrice + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ISimplePaymentProcessor.IncorrectPaymentAmount.selector, s, invoicePrice)
        );
        simplePP.makeInvoicePayment{ value: s }(orderId);

        // TRY EXPIRED INVOICE
        vm.warp(block.timestamp + simplePP.VALID_PERIOD() + 1);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceIsNoLongerValid.selector);
        simplePP.makeInvoicePayment{ value: invoicePrice }(orderId);

        // MAKE VALID PAYMENT
        vm.warp(block.timestamp - simplePP.VALID_PERIOD());
        address escrowAddress = simplePP.makeInvoicePayment{ value: invoicePrice }(orderId);

        uint256 currentInvoiceStatus = simplePP.getInvoiceData(orderId).status;
        // TRY ALREADY PAID INVOICE
        vm.expectRevert(
            abi.encodeWithSelector(ISimplePaymentProcessor.InvalidInvoiceState.selector, currentInvoiceStatus)
        );
        simplePP.makeInvoicePayment{ value: invoicePrice }(orderId);
        vm.stopPrank();

        ISimplePaymentProcessor.Invoice memory invoiceData = simplePP.getInvoiceData(orderId);

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
        bytes32 orderId = simplePP.createInvoice(invoicePrice);

        vm.prank(sellerTwo);
        vm.expectRevert(NotAuthorized.selector);
        simplePP.acceptPayment(orderId);

        vm.warp(block.number + 10);

        vm.prank(sellerOne);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceNotPaid.selector);
        simplePP.acceptPayment(orderId);

        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(orderId);

        vm.prank(sellerOne);
        simplePP.acceptPayment(orderId);
        ISimplePaymentProcessor.Invoice memory i = simplePP.getInvoiceData(orderId);
        uint256 fee = simplePP.calculateFee(i.price);
        assertEq(i.status, simplePP.ACCEPTED());
        assertEq(ppStorage.getFeeReceiver().balance, fee);
    }

    function test_payment_acceptance_after_acceptance_window() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        bytes32 orderId = simplePP.createInvoice(invoicePrice);

        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(orderId);

        vm.warp(block.timestamp + simplePP.ACCEPTANCE_WINDOW() + 1);
        vm.prank(sellerOne);
        vm.expectRevert(ISimplePaymentProcessor.AcceptanceWindowExceeded.selector);
        simplePP.acceptPayment(orderId);
    }

    function test_payer_refund_acceptance_window() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        bytes32 orderId = simplePP.createInvoice(invoicePrice);

        // 10000
        uint256 balanceBeforePayment = buyerOne.balance;
        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(orderId);

        vm.startPrank(buyerOne);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceNotEligibleForRefund.selector);
        simplePP.refundBuyer(orderId);

        vm.warp(block.timestamp + simplePP.ACCEPTANCE_WINDOW() + 1);
        simplePP.refundBuyer(orderId);
        vm.stopPrank();

        uint256 balanceAfterRefund = buyerOne.balance;

        assertEq(simplePP.getInvoiceData(orderId).status, simplePP.REFUNDED());
        assertEq(balanceBeforePayment, balanceAfterRefund);
    }

    function test_payment_rejection() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        bytes32 orderId = simplePP.createInvoice(invoicePrice);

        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(orderId);
        uint256 buyerOneBalanceAfterPayment = address(buyerOne).balance;
        assertEq(buyerOneBalanceAfterPayment, INITIAL_BALANCE - invoicePrice);

        vm.prank(sellerOne);
        simplePP.rejectPayment(orderId);

        assertEq(simplePP.getInvoiceData(orderId).status, simplePP.REJECTED());
        assertEq(buyerOne.balance, buyerOneBalanceAfterPayment + invoicePrice);
    }

    function test_default_hold_release_invoice() public {
        // CREATE
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        bytes32 orderId = simplePP.createInvoice(invoicePrice);

        uint256 fee = simplePP.calculateFee(invoicePrice);

        // PAY
        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(orderId);

        // // ACCEPT
        vm.prank(sellerOne);
        simplePP.acceptPayment(orderId);

        //RELEASE
        vm.expectRevert(NotAuthorized.selector);
        simplePP.releaseInvoice(orderId);

        vm.startPrank(sellerOne);
        vm.expectRevert(ISimplePaymentProcessor.HoldPeriodHasNotBeenExceeded.selector);
        simplePP.releaseInvoice(orderId);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);
        simplePP.releaseInvoice(orderId);

        vm.expectRevert(ISimplePaymentProcessor.InvoiceHasAlreadyBeenReleased.selector);
        simplePP.releaseInvoice(orderId);
        vm.stopPrank();

        assertEq(sellerOne.balance, INITIAL_BALANCE + invoicePrice - fee);
        assertEq(simplePP.getInvoiceData(orderId).status, simplePP.RELEASED());
    }

    function test_dynamic_hold_release_invoice() public {
        uint32 adminHoldPeriod = 25 days;

        vm.prank(admin);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceHasNotBeenAccepted.selector);

        bytes memory data =
            abi.encodeWithSelector(simplePP.setInvoiceReleaseTime.selector, keccak256(""), adminHoldPeriod);
        ppStorage.execute(address(simplePP), data);

        // CREATE
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        bytes32 orderId = simplePP.createInvoice(invoicePrice);

        uint256 fee = simplePP.calculateFee(invoicePrice);

        // PAY
        vm.prank(buyerOne);
        simplePP.makeInvoicePayment{ value: invoicePrice }(orderId);

        // ACCEPT
        vm.prank(sellerOne);
        simplePP.acceptPayment(orderId);

        data = abi.encodeWithSelector(simplePP.setInvoiceReleaseTime.selector, orderId, adminHoldPeriod);
        vm.prank(admin);
        ppStorage.execute(address(simplePP), data);

        vm.warp(block.timestamp + adminHoldPeriod);
        vm.prank(sellerOne);
        simplePP.releaseInvoice(orderId);

        assertEq(sellerOne.balance, INITIAL_BALANCE + invoicePrice - fee);
        assertEq(simplePP.getInvoiceData(orderId).status, simplePP.RELEASED());
    }
}
