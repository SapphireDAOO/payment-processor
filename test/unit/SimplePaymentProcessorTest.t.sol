// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { SimplePaymentProcessorSetUp } from "../utils/SimplePaymentProcessorSetUp.sol";
import { console } from "forge-std/console.sol";

error NotAuthorized();

contract SimplePaymentProcessorTest is SimplePaymentProcessorSetUp {
    function test_storage_state() public view {
        assertEq(ppStorage.getFeeRate(), FEE_RATE);
        assertEq(ppStorage.getFeeReceiver(), feeReceiver);
        assertEq(simplePP.getNextInvoiceNonce(), 1);
        assertEq(ppStorage.getDefaultHoldPeriod(), DEFAULT_HOLD_PERIOD);
        assertEq(simplePP.getMinimumInvoiceValue(), MINIMUM_INVOICE_VALUE);
        assertEq(simplePP.getForwarder(), FORWARDER_TWO);
    }

    function test_setForwarder() public {
        vm.expectRevert(ISimplePaymentProcessor.NotAuthorized.selector);
        simplePP.setForwarderAddress(address(2));
    }

    function test_setMinimumInvoiceValue() public {
        vm.expectRevert(ISimplePaymentProcessor.NotAuthorized.selector);
        simplePP.setMinimumInvoiceValue(1 ether);
    }

    function test_invoice_creation() public {
        uint256 cOneInvoicePrice = 100 ether;
        vm.startPrank(sellerOne);

        vm.expectRevert(ISimplePaymentProcessor.ValueIsTooLow.selector);
        simplePP.createInvoice(0, "", false);

        uint216 invoiceId = simplePP.createInvoice(cOneInvoicePrice, "", false);
        vm.stopPrank();

        ISimplePaymentProcessor.Invoice memory invoiceDataOne = simplePP.getInvoiceData(invoiceId);
        assertEq(invoiceDataOne.seller, sellerOne);
        assertEq(invoiceDataOne.createdAt, block.timestamp);
        assertEq(invoiceDataOne.paidAt, 0);
        assertEq(invoiceDataOne.price, 100 ether);
        assertEq(invoiceDataOne.balance, 0);
        assertEq(invoiceDataOne.buyer, address(0));
        assertEq(invoiceDataOne.status, simplePP.CREATED());
        assertEq(invoiceDataOne.escrow, address(0));
        assertEq(invoiceDataOne.invoiceNonce, 1);
        assertEq(simplePP.getNextInvoiceNonce(), 2);

        vm.prank(sellerTwo);
        invoiceId = simplePP.createInvoice(25 ether, "", false);

        ISimplePaymentProcessor.Invoice memory invoiceDataTwo = simplePP.getInvoiceData(invoiceId);
        assertEq(invoiceDataTwo.seller, sellerTwo);
        assertEq(invoiceDataTwo.createdAt, block.timestamp);
        assertEq(invoiceDataTwo.paidAt, 0);
        assertEq(invoiceDataTwo.price, 25 ether);
        assertEq(invoiceDataTwo.balance, 0);
        assertEq(invoiceDataTwo.buyer, address(0));
        assertEq(invoiceDataTwo.status, simplePP.CREATED());
        assertEq(invoiceDataTwo.escrow, address(0));
        assertEq(invoiceDataTwo.invoiceNonce, 2);
        assertEq(simplePP.getNextInvoiceNonce(), 3);
    }

    function test_cancel_invoice() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.expectRevert(NotAuthorized.selector);
        simplePP.cancelInvoice(invoiceId);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        uint256 currentInvoiceStatus = simplePP.getInvoiceData(invoiceId).status;

        vm.startPrank(sellerOne);
        vm.expectRevert(
            abi.encodeWithSelector(ISimplePaymentProcessor.InvalidInvoiceState.selector, currentInvoiceStatus)
        );
        simplePP.cancelInvoice(invoiceId);

        invoiceId = simplePP.createInvoice(invoicePrice, "", false);
        simplePP.cancelInvoice(invoiceId);
        vm.stopPrank();

        assertEq(simplePP.getInvoiceData(invoiceId).status, simplePP.CANCELLED());
    }

    function test_make_invoice_payment() public {
        // CREATE INVOICE
        uint256 invoicePrice = 100 ether;
        deal(sellerOne, 1);
        vm.startPrank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.expectRevert(ISimplePaymentProcessor.SellerCannotPayOwnedInvoice.selector);
        simplePP.pay{ value: 1 }(invoiceId, "", false);
        vm.stopPrank();

        vm.startPrank(buyerOne);

        // TRY INCORRECT PAYMENT

        uint256 s = invoicePrice + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ISimplePaymentProcessor.IncorrectPaymentAmount.selector, s, invoicePrice)
        );
        simplePP.pay{ value: s }(invoiceId, "", false);

        // TRY EXPIRED INVOICE
        vm.warp(block.timestamp + simplePP.validPeriod() + 1);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceIsNoLongerValid.selector);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        // MAKE VALID PAYMENT
        vm.warp(block.timestamp - simplePP.validPeriod());
        address escrowAddress = simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        uint256 currentInvoiceStatus = simplePP.getInvoiceData(invoiceId).status;
        // TRY ALREADY PAID INVOICE
        vm.expectRevert(
            abi.encodeWithSelector(ISimplePaymentProcessor.InvalidInvoiceState.selector, currentInvoiceStatus)
        );
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);
        vm.stopPrank();

        ISimplePaymentProcessor.Invoice memory invoiceData = simplePP.getInvoiceData(invoiceId);

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
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(sellerTwo);
        vm.expectRevert(NotAuthorized.selector);
        simplePP.acceptPayment(invoiceId);

        vm.warp(block.number + 10);

        vm.prank(sellerOne);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceNotPaid.selector);
        simplePP.acceptPayment(invoiceId);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        vm.prank(sellerOne);
        simplePP.acceptPayment(invoiceId);
        ISimplePaymentProcessor.Invoice memory i = simplePP.getInvoiceData(invoiceId);
        uint256 fee = simplePP.calculateFee(i.price);
        assertEq(i.status, simplePP.ACCEPTED());
        assertEq(ppStorage.getFeeReceiver().balance, fee);
    }

    function test_payment_acceptance_after_decisionWindow() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        vm.warp(block.timestamp + simplePP.decisionWindow() + 1);
        vm.prank(sellerOne);
        vm.expectRevert(ISimplePaymentProcessor.AcceptanceWindowExceeded.selector);
        simplePP.acceptPayment(invoiceId);
    }

    function test_payer_refund_decisionWindow() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        // 10000
        uint256 balanceBeforePayment = buyerOne.balance;
        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        vm.startPrank(buyerOne);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceNotEligibleForRefund.selector);
        simplePP.refundBuyer(invoiceId);

        vm.warp(block.timestamp + simplePP.decisionWindow() + 1);
        simplePP.refundBuyer(invoiceId);
        vm.stopPrank();

        uint256 balanceAfterRefund = buyerOne.balance;

        assertEq(simplePP.getInvoiceData(invoiceId).status, simplePP.REFUNDED());
        assertEq(balanceBeforePayment, balanceAfterRefund);
    }

    function test_payment_rejection() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);
        uint256 buyerOneBalanceAfterPayment = address(buyerOne).balance;
        assertEq(buyerOneBalanceAfterPayment, INITIAL_BALANCE - invoicePrice);

        vm.prank(sellerOne);
        simplePP.rejectPayment(invoiceId);

        assertEq(simplePP.getInvoiceData(invoiceId).status, simplePP.REJECTED());
        assertEq(buyerOne.balance, buyerOneBalanceAfterPayment + invoicePrice);
    }

    function test_default_hold_release_invoice() public {
        // CREATE
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        uint256 fee = simplePP.calculateFee(invoicePrice);

        // PAY
        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        vm.prank(sellerOne);
        vm.expectRevert(abi.encodeWithSelector(ISimplePaymentProcessor.InvalidInvoiceState.selector, simplePP.PAID()));
        simplePP.releaseInvoice(invoiceId);

        // // ACCEPT
        vm.prank(sellerOne);
        simplePP.acceptPayment(invoiceId);

        //RELEASE
        vm.expectRevert(NotAuthorized.selector);
        simplePP.releaseInvoice(invoiceId);

        vm.startPrank(sellerOne);
        vm.expectRevert(ISimplePaymentProcessor.HoldPeriodHasNotBeenExceeded.selector);
        simplePP.releaseInvoice(invoiceId);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);
        simplePP.releaseInvoice(invoiceId);

        vm.expectRevert(ISimplePaymentProcessor.InvoiceHasAlreadyBeenReleased.selector);
        simplePP.releaseInvoice(invoiceId);
        vm.stopPrank();

        assertEq(sellerOne.balance, INITIAL_BALANCE + invoicePrice - fee);
        assertEq(simplePP.getInvoiceData(invoiceId).status, simplePP.RELEASED());
    }

    function test_dynamic_hold_release_invoice() public {
        uint32 adminHoldPeriod = 25 days;

        bytes memory data = abi.encodeWithSelector(simplePP.setInvoiceReleaseTime.selector, 0, adminHoldPeriod);

        vm.prank(admin);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceHasNotBeenAccepted.selector);
        // ppStorage.execute(address(simplePP), data);

        // CREATE
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        uint256 fee = simplePP.calculateFee(invoicePrice);

        // PAY
        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        // ACCEPT
        vm.prank(sellerOne);
        simplePP.acceptPayment(invoiceId);

        data = abi.encodeWithSelector(simplePP.setInvoiceReleaseTime.selector, invoiceId, adminHoldPeriod);

        vm.expectRevert(ISimplePaymentProcessor.NotAuthorized.selector);
        simplePP.setInvoiceReleaseTime(invoiceId, adminHoldPeriod);

        vm.prank(admin);
        // ppStorage.execute(address(simplePP), data);

        vm.warp(block.timestamp + adminHoldPeriod);
        vm.prank(sellerOne);
        simplePP.releaseInvoice(invoiceId);

        assertEq(sellerOne.balance, INITIAL_BALANCE + invoicePrice - fee);
        assertEq(simplePP.getInvoiceData(invoiceId).status, simplePP.RELEASED());
    }

    function test_automatedRelease() public {
        uint256 invoicePrice = 100 ether;

        uint256 numberOfInvoice = 10;
        uint216[] memory invoiceIds = new uint216[](numberOfInvoice);

        for (uint256 i = 0; i < numberOfInvoice; i++) {
            vm.prank(sellerOne);
            uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

            // PAY
            vm.prank(buyerOne);
            simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

            // ACCEPT
            vm.prank(sellerOne);
            simplePP.acceptPayment(invoiceId);
            invoiceIds[i] = invoiceId;
        }

        vm.startPrank(admin);
        bytes memory data = abi.encodeWithSelector(simplePP.setInvoiceReleaseTime.selector, invoiceIds[2], 12 hours);
        // ppStorage.execute(address(simplePP), data);

        data = abi.encodeWithSelector(simplePP.setInvoiceReleaseTime.selector, invoiceIds[9], 100 days);
        // ppStorage.execute(address(simplePP), data);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days);

        (bool upkeepNeeded,) = simplePP.checkUpkeep("");
        assertTrue(upkeepNeeded);

        uint216[] memory o = simplePP.getItems();

        assertEq(o[0], invoiceIds[2]);
        for (uint256 i = 0; i < o.length; i++) {
            console.log("items in heap before up keep", o[i]);
        }

        vm.prank(buyerOne);
        vm.expectRevert(ISimplePaymentProcessor.NotAuthorized.selector);
        simplePP.performUpkeep("");

        vm.prank(admin);
        simplePP.performUpkeep("");
        for (uint256 i = 0; i < numberOfInvoice; i++) {
            console.log("order:", invoiceIds[i], simplePP.getInvoiceData(invoiceIds[i]).status, i);
        }
        assertEq(simplePP.getInvoiceData(invoiceIds[9]).status, 2);
    }

    function test_automatedRefund() public {
        uint256 invoicePrice = 100 ether;

        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        uint256 buyerBalanceBeforeRefund = address(buyerOne).balance;

        vm.warp(block.timestamp + 3 days);

        vm.prank(admin);
        simplePP.performUpkeep("");

        uint256 buyerBalanceAfterRefund = address(buyerOne).balance;

        assertEq(simplePP.getInvoiceData(invoiceId).status, simplePP.REFUNDED());
        assertEq(buyerBalanceBeforeRefund + invoicePrice, buyerBalanceAfterRefund);
        assertEq(simplePP.getItems().length, 0);
    }

    function test_dynamicInvalidationPeriod() public {
        vm.prank(admin);
        simplePP.setValidPeriod(2 days);

        uint256 invoicePrice = 100 ether;

        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(buyerOne);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceIsNoLongerValid.selector);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);
    }

    function test_dynamicAcceptanceDuration() public {
        uint256 invoicePrice = 100 ether;

        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(admin);
        simplePP.setDecisionWindow(1 days);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(admin);
        simplePP.performUpkeep("");

        assertEq(simplePP.getInvoiceData(invoiceId).status, simplePP.REFUNDED());
    }
}
