// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { IERC165, IReceiver } from "../../src/interface/IReceiver.sol";
import { SimplePaymentProcessorSetUp } from "../utils/SimplePaymentProcessorSetUp.sol";
import { console } from "forge-std/console.sol";
import { IEscrow } from "src/interface/IEscrow.sol";
import { NoReceiveEther } from "../utils/NoReceiveEther.sol";

import {
    CREATED,
    PAID,
    ACCEPTED,
    REJECTED,
    CANCELED,
    REFUNDED,
    RELEASED,
    LOCKED,
    BASIS_POINTS
} from "src/constants/Simple.sol";

error NotAuthorized();

contract SimplePaymentProcessorTest is SimplePaymentProcessorSetUp {
    function test_storageState() public view {
        assertEq(ppStorage.getFeeRate(), FEE_RATE);
        assertEq(ppStorage.getFeeReceiver(), feeReceiver);
        assertEq(simplePP.getNextInvoiceNonce(), 1);
        assertEq(ppStorage.getDefaultHoldPeriod(), DEFAULT_HOLD_PERIOD);
        assertEq(simplePP.getMinimumInvoiceValue(), MINIMUM_INVOICE_VALUE);
        assertEq(simplePP.getForwarder(), FORWARDER_TWO);
        assertEq(simplePP.getWorkflowOwner(), WORKFLOW_OWNER);
    }

    function test_setForwarder() public {
        vm.expectRevert(ISimplePaymentProcessor.NotAuthorized.selector);
        simplePP.setForwarderAddress(address(2));
    }

    function test_setMinimumInvoiceValue() public {
        vm.expectRevert(ISimplePaymentProcessor.NotAuthorized.selector);
        simplePP.setMinimumInvoiceValue(1 ether);
    }

    function test_setForwarderAuthorizedCanSet() public {
        address newForwarder = address(0xcafe);
        vm.prank(admin);
        simplePP.setForwarderAddress(newForwarder);

        assertEq(simplePP.getForwarder(), newForwarder);
    }

    function test_setMinimumInvoiceValueAuthorizedCanSet() public {
        vm.prank(admin);
        simplePP.setMinimumInvoiceValue(2 ether);

        assertEq(simplePP.getMinimumInvoiceValue(), 2 ether);

        vm.prank(sellerOne);
        vm.expectRevert(ISimplePaymentProcessor.ValueIsTooLow.selector);
        simplePP.createInvoice(1 ether, "", false);
    }

    function test_setDecisionWindow() public {
        vm.expectRevert(ISimplePaymentProcessor.NotAuthorized.selector);
        simplePP.setDecisionWindow(1 days);

        vm.startPrank(admin);
        vm.expectRevert(ISimplePaymentProcessor.InvalidDecisionWindow.selector);
        simplePP.setDecisionWindow(0);

        simplePP.setDecisionWindow(1 days);
        vm.stopPrank();

        assertEq(simplePP.decisionWindow(), 1 days);
    }

    function test_invoiceCreation() public {
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
        assertEq(invoiceDataOne.state, CREATED);
        assertEq(invoiceDataOne.escrow, address(0));
        assertEq(invoiceDataOne.invoiceNonce, 1);
        assertEq(simplePP.getNextInvoiceNonce(), 2);

        vm.prank(sellerTwo);
        invoiceId = simplePP.createInvoice(25 ether, "hello", false);

        ISimplePaymentProcessor.Invoice memory invoiceDataTwo = simplePP.getInvoiceData(invoiceId);
        assertEq(invoiceDataTwo.seller, sellerTwo);
        assertEq(invoiceDataTwo.createdAt, block.timestamp);
        assertEq(invoiceDataTwo.paidAt, 0);
        assertEq(invoiceDataTwo.price, 25 ether);
        assertEq(invoiceDataTwo.balance, 0);
        assertEq(invoiceDataTwo.buyer, address(0));
        assertEq(invoiceDataTwo.state, CREATED);
        assertEq(invoiceDataTwo.escrow, address(0));
        assertEq(invoiceDataTwo.invoiceNonce, 2);
        assertEq(simplePP.getNextInvoiceNonce(), 3);
    }

    function test_cancelInvoice() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.expectRevert(NotAuthorized.selector);
        simplePP.cancelInvoice(invoiceId);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        uint256 currentInvoiceStatus = simplePP.getInvoiceData(invoiceId).state;

        vm.expectRevert(
            abi.encodeWithSelector(ISimplePaymentProcessor.InvalidInvoiceState.selector, currentInvoiceStatus)
        );
        vm.startPrank(sellerOne);
        simplePP.cancelInvoice(invoiceId);

        invoiceId = simplePP.createInvoice(invoicePrice, "", false);
        simplePP.cancelInvoice(invoiceId);
        vm.stopPrank();

        assertEq(simplePP.getInvoiceData(invoiceId).state, CANCELED);
    }

    function test_payment() public {
        // CREATE INVOICE
        uint256 invoicePrice = 100 ether;
        vm.deal(sellerOne, 1);
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
        vm.warp(block.timestamp + ppStorage.getPaymentValidityDuration() + 1);
        vm.expectRevert(ISimplePaymentProcessor.InvoiceIsNoLongerValid.selector);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        // MAKE VALID PAYMENT
        vm.warp(block.timestamp - ppStorage.getPaymentValidityDuration());
        address escrowAddress = simplePP.pay{ value: invoicePrice }(invoiceId, "correct", false);

        uint256 currentInvoiceStatus = simplePP.getInvoiceData(invoiceId).state;
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
        assertEq(invoiceData.state, PAID);
        assertEq(invoiceData.buyer, buyerOne);
    }

    function test_paymentAcceptance() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.expectRevert(NotAuthorized.selector);
        vm.prank(sellerTwo);
        simplePP.acceptPayment(invoiceId);

        vm.warp(block.number + 10);

        vm.expectRevert(abi.encodeWithSelector(ISimplePaymentProcessor.InvalidInvoiceState.selector, CREATED));
        vm.prank(sellerOne);
        simplePP.acceptPayment(invoiceId);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        vm.prank(sellerOne);
        simplePP.acceptPayment(invoiceId);
        ISimplePaymentProcessor.Invoice memory i = simplePP.getInvoiceData(invoiceId);

        assertEq(i.state, ACCEPTED);
    }

    function test_paymentAcceptanceAfterDecisionWindow() public {
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

    function test_payerRefundDecisionWindow() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        // 10000
        uint256 balanceBeforePayment = buyerOne.balance;
        vm.startPrank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        vm.expectRevert(ISimplePaymentProcessor.InvoiceNotEligibleForRefund.selector);
        simplePP.refundBuyer(invoiceId);

        vm.warp(block.timestamp + simplePP.decisionWindow() + 1);
        simplePP.refundBuyer(invoiceId);
        vm.stopPrank();

        uint256 balanceAfterRefund = buyerOne.balance;

        assertEq(simplePP.getInvoiceData(invoiceId).state, REFUNDED);
        assertEq(balanceBeforePayment, balanceAfterRefund);
    }

    function test_refundMaliciousBuyer() public {
        NoReceiveEther a = new NoReceiveEther{ value: 100 ether }();
        address thisBuyer = address(a);
        uint256 invoicePrice = 100 ether;

        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.startPrank(thisBuyer);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);
        vm.warp(block.timestamp + simplePP.decisionWindow() + 1);
        simplePP.refundBuyer(invoiceId);

        assertEq(simplePP.getInvoiceData(invoiceId).withdrawalRetries, 1);

        simplePP.refundBuyer(invoiceId);
        simplePP.refundBuyer(invoiceId);
        simplePP.refundBuyer(invoiceId);

        vm.stopPrank();

        assertEq(simplePP.getInvoiceData(invoiceId).state, LOCKED);
    }

    function test_paymentRejection() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);
        uint256 buyerOneBalanceAfterPayment = address(buyerOne).balance;
        assertEq(buyerOneBalanceAfterPayment, INITIAL_BALANCE - invoicePrice);

        vm.prank(sellerOne);
        simplePP.rejectPayment(invoiceId);

        assertEq(simplePP.getInvoiceData(invoiceId).state, REJECTED);
        assertEq(buyerOne.balance, buyerOneBalanceAfterPayment + invoicePrice);
    }

    function test_defaultHoldReleaseInvoice() public {
        // CREATE
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        uint256 fee = simplePP.calculateFee(invoicePrice);

        // PAY
        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        vm.prank(sellerOne);
        vm.expectRevert(abi.encodeWithSelector(ISimplePaymentProcessor.InvalidInvoiceState.selector, PAID));
        simplePP.release(invoiceId);

        // // ACCEPT
        vm.prank(sellerOne);
        simplePP.acceptPayment(invoiceId);

        //RELEASE
        vm.expectRevert(NotAuthorized.selector);
        simplePP.release(invoiceId);

        vm.startPrank(sellerOne);
        vm.expectRevert(ISimplePaymentProcessor.HoldPeriodHasNotBeenExceeded.selector);
        simplePP.release(invoiceId);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);
        simplePP.release(invoiceId);

        vm.expectRevert(abi.encodeWithSelector(ISimplePaymentProcessor.InvalidInvoiceState.selector, RELEASED));
        simplePP.release(invoiceId);
        vm.stopPrank();

        assertEq(sellerOne.balance, INITIAL_BALANCE + invoicePrice - fee);
        assertEq(simplePP.getInvoiceData(invoiceId).state, RELEASED);
    }

    function test_feeRateSnapshotAtCreationIsUsedOnRelease() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        assertEq(simplePP.getInvoiceData(invoiceId).feeRate, FEE_RATE);
        uint256 expectedFee = (invoicePrice * FEE_RATE) / BASIS_POINTS;

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);
        vm.prank(sellerOne);
        simplePP.acceptPayment(invoiceId);

        vm.prank(admin);
        ppStorage.setFeeRate(uint96(FEE_RATE * 4));

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);
        vm.prank(sellerOne);
        simplePP.release(invoiceId);

        assertEq(sellerOne.balance, INITIAL_BALANCE + invoicePrice - expectedFee);
        assertEq(feeReceiver.balance, expectedFee);
    }

    function test_dynamicHoldReleaseInvoice() public {
        uint32 adminHoldPeriod = 25 days;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISimplePaymentProcessor.InvalidInvoiceState.selector, 0));
        simplePP.setInvoiceReleaseTime(0, adminHoldPeriod);

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

        vm.expectRevert(ISimplePaymentProcessor.NotAuthorized.selector);
        simplePP.setInvoiceReleaseTime(invoiceId, adminHoldPeriod);

        vm.prank(admin);
        simplePP.setInvoiceReleaseTime(invoiceId, adminHoldPeriod);

        vm.warp(block.timestamp + adminHoldPeriod);
        vm.prank(sellerOne);
        simplePP.release(invoiceId);

        assertEq(sellerOne.balance, INITIAL_BALANCE + invoicePrice - fee);
        assertEq(simplePP.getInvoiceData(invoiceId).state, RELEASED);
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
        simplePP.setInvoiceReleaseTime(invoiceIds[2], 12 hours);

        simplePP.setInvoiceReleaseTime(invoiceIds[9], 1000 hours);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days);

        bool dueTasksExist = simplePP.hasDueTasks();
        assertTrue(dueTasksExist);

        uint216[] memory o = simplePP.getItems();

        assertEq(o[0], invoiceIds[2]);
        for (uint256 i = 0; i < o.length; i++) {
            console.log("items in heap before up keep", o[i]);
        }

        vm.prank(buyerOne);
        vm.expectRevert(ISimplePaymentProcessor.NotAuthorized.selector);
        simplePP.processDueTasks();

        vm.prank(admin);
        simplePP.processDueTasks();
        for (uint256 i = 0; i < numberOfInvoice; i++) {
            console.log("order:", invoiceIds[i], simplePP.getInvoiceData(invoiceIds[i]).state, i);
        }
        assertEq(simplePP.getInvoiceData(invoiceIds[9]).state, ACCEPTED);
    }

    function test_automatedRefund() public {
        uint256 invoicePrice = 100 ether;

        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        uint256 buyerBalanceBeforeRefund = address(buyerOne).balance;

        vm.warp(block.timestamp + 3 days);

        vm.prank(admin);
        simplePP.processDueTasks();

        uint256 buyerBalanceAfterRefund = address(buyerOne).balance;

        assertEq(simplePP.getInvoiceData(invoiceId).state, REFUNDED);
        assertEq(buyerBalanceBeforeRefund + invoicePrice, buyerBalanceAfterRefund);
        assertEq(simplePP.getItems().length, 0);
    }

    function test_dynamicInvalidationPeriod() public {
        vm.prank(admin);
        ppStorage.setPaymentValidityDuration(2 days);

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
        simplePP.processDueTasks();

        assertEq(simplePP.getInvoiceData(invoiceId).state, REFUNDED);
    }

    function test_ineligibleRelease() public {
        uint256 invoicePrice = 100 ether;

        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        simplePP.acceptPayment(invoiceId);

        vm.prank(admin);
        simplePP.processDueTasks();
    }

    function test_directEscrowWithdrawal() public {
        uint256 invoicePrice = 100 ether;
        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        address escrow = simplePP.getInvoiceData(invoiceId).escrow;

        vm.expectRevert(IEscrow.Unauthorized.selector);
        IEscrow(escrow).withdraw(address(0), address(this), escrow.balance);
    }

    function test_hasDueTasksReturnsFalseWhenEmpty() public view {
        bool dueTasksExist = simplePP.hasDueTasks();
        assertFalse(dueTasksExist);
    }

    function test_onReportForwarderCanCall() public {
        uint256 invoicePrice = 10 ether;

        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        vm.warp(block.timestamp + simplePP.decisionWindow() + 1);

        vm.prank(FORWARDER_TWO);
        simplePP.onReport(_workflowMetadata(WORKFLOW_OWNER), "");

        assertEq(simplePP.getInvoiceData(invoiceId).state, REFUNDED);
    }

    function test_onReportRevertsForNonForwarder() public {
        vm.prank(admin);
        vm.expectRevert(ISimplePaymentProcessor.NotAuthorized.selector);
        simplePP.onReport(_workflowMetadata(WORKFLOW_OWNER), "");
    }

    function test_onReportRevertsForUnauthorizedWorkflowOwner() public {
        address rogueOwner = address(0xbad);

        vm.prank(FORWARDER_TWO);
        vm.expectRevert(abi.encodeWithSelector(ISimplePaymentProcessor.UnauthorizedWorkflowOwner.selector, rogueOwner));
        simplePP.onReport(_workflowMetadata(rogueOwner), "");
    }

    function test_onReportRevertsForMalformedMetadata() public {
        vm.prank(FORWARDER_TWO);
        vm.expectRevert(abi.encodeWithSelector(ISimplePaymentProcessor.UnauthorizedWorkflowOwner.selector, address(0)));
        simplePP.onReport("", "");
    }

    function test_setWorkflowOwner() public {
        vm.expectRevert(ISimplePaymentProcessor.NotAuthorized.selector);
        simplePP.setWorkflowOwner(address(2));

        address newWorkflowOwner = address(0xdead);
        vm.prank(admin);
        simplePP.setWorkflowOwner(newWorkflowOwner);

        assertEq(simplePP.getWorkflowOwner(), newWorkflowOwner);
    }

    function test_supportsInterface() public view {
        assertTrue(simplePP.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(simplePP.supportsInterface(type(IERC165).interfaceId));
        assertFalse(simplePP.supportsInterface(0xffffffff));
    }

    function test_rejectPaymentRevertsAfterWindowExpires() public {
        uint256 invoicePrice = 10 ether;

        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        vm.warp(block.timestamp + simplePP.decisionWindow() + 1);

        vm.prank(sellerOne);
        vm.expectRevert(ISimplePaymentProcessor.AcceptanceWindowExceeded.selector);
        simplePP.rejectPayment(invoiceId);
    }

    function test_releaseLockedRevertsIfNotLocked() public {
        uint256 invoicePrice = 10 ether;

        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        uint256 paidState = simplePP.getInvoiceData(invoiceId).state;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISimplePaymentProcessor.InvalidInvoiceState.selector, paidState));
        simplePP.releaseLocked(invoiceId, admin, invoicePrice);
    }

    function test_releaseLocked() public {
        uint256 invoicePrice = 10 ether;
        uint216 invoiceId = _getLockedInvoice(invoicePrice);

        vm.expectRevert(ISimplePaymentProcessor.NotAuthorized.selector);
        simplePP.releaseLocked(invoiceId, buyerOne, 10 ether);

        assertEq(simplePP.getInvoiceData(invoiceId).state, LOCKED);

        uint256 adminBalanceBefore = admin.balance;

        vm.prank(admin);
        simplePP.releaseLocked(invoiceId, admin, invoicePrice);

        assertEq(simplePP.getInvoiceData(invoiceId).state, LOCKED);
        assertEq(admin.balance, adminBalanceBefore + invoicePrice);
    }

    function test_releaseLockedPartialAmount() public {
        uint256 invoicePrice = 10 ether;
        uint216 invoiceId = _getLockedInvoice(invoicePrice);

        uint256 partialAmount = invoicePrice / 2;
        uint256 adminBefore = admin.balance;

        vm.prank(admin);
        simplePP.releaseLocked(invoiceId, admin, partialAmount);

        assertEq(simplePP.getInvoiceData(invoiceId).state, LOCKED);
        assertEq(admin.balance, adminBefore + partialAmount);
    }

    function test_releaseLockedEscrowWithdrawFails() public {
        uint256 invoicePrice = 10 ether;
        uint216 invoiceId = _getLockedInvoice(invoicePrice);

        NoReceiveEther noReceiveRecipient = new NoReceiveEther();

        vm.prank(admin);
        vm.expectRevert(ISimplePaymentProcessor.EscrowWithdrawFailed.selector);
        simplePP.releaseLocked(invoiceId, address(noReceiveRecipient), invoicePrice);
    }

    function test_releaseLockedPpStorageCanCall() public {
        uint256 invoicePrice = 10 ether;
        uint216 invoiceId = _getLockedInvoice(invoicePrice);

        vm.prank(address(ppStorage));
        simplePP.releaseLocked(invoiceId, admin, invoicePrice);

        assertEq(simplePP.getInvoiceData(invoiceId).state, LOCKED);
    }

    function test_automatedSellerReleaseRetry() public {
        uint256 invoicePrice = 10 ether;
        NoReceiveEther noReceiveSeller = new NoReceiveEther();

        vm.prank(address(noReceiveSeller));
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        vm.prank(address(noReceiveSeller));
        simplePP.acceptPayment(invoiceId);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);

        uint256 buyerBefore = buyerOne.balance;
        vm.prank(admin);
        simplePP.processDueTasks();

        assertEq(simplePP.getInvoiceData(invoiceId).state, REFUNDED);
        assertEq(simplePP.getInvoiceData(invoiceId).withdrawalRetries, 3);
        assertEq(buyerOne.balance, buyerBefore + invoicePrice);
    }

    function test_automatedLockedFromAcceptedInvoice() public {
        // processDueTask loops: 3 seller retries + 3 buyer retries all fail → LOCKED
        // in a single performUpkeep call (task stays at heap top until removed).
        uint256 invoicePrice = 10 ether;
        NoReceiveEther noReceiveSeller = new NoReceiveEther();
        NoReceiveEther noReceiveBuyer = new NoReceiveEther();

        vm.prank(address(noReceiveSeller));
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.deal(address(noReceiveBuyer), invoicePrice);
        vm.prank(address(noReceiveBuyer));
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        vm.prank(address(noReceiveSeller));
        simplePP.acceptPayment(invoiceId);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);

        vm.prank(admin);
        simplePP.processDueTasks();

        assertEq(simplePP.getInvoiceData(invoiceId).state, LOCKED);
        assertEq(simplePP.getInvoiceData(invoiceId).withdrawalRetries, 6);
    }

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
        assertEq(invoiceData.state, CREATED);
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
        assertEq(invoice.state, CREATED);

        vm.prank(buyerOne);
        address escrow = simplePP.pay{ value: _invoicePrice }(invoiceId, "", false);

        ISimplePaymentProcessor.Invoice memory updated = simplePP.getInvoiceData(invoiceId);
        assertEq(updated.buyer, buyerOne);
        assertEq(updated.balance, _invoicePrice);
        assertEq(updated.state, PAID);
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

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);

        uint256 sellerBefore = sellerOne.balance;

        vm.prank(sellerOne);
        simplePP.release(invoiceId);

        ISimplePaymentProcessor.Invoice memory inv = simplePP.getInvoiceData(invoiceId);
        assertEq(inv.state, RELEASED);
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
        assertEq(inv.state, REJECTED);
        assertEq(buyerOne.balance, buyerBefore + _invoicePrice);
    }

    function test_cancelInvoice(uint256 _invoicePrice) public {
        _invoicePrice = bound(_invoicePrice, 1 ether, 1000 ether);

        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(_invoicePrice, "", false);

        vm.prank(sellerOne);
        simplePP.cancelInvoice(invoiceId);

        ISimplePaymentProcessor.Invoice memory inv = simplePP.getInvoiceData(invoiceId);
        assertEq(inv.state, CANCELED);
        assertEq(inv.escrow, address(0));
    }

    function test_calculateFee(uint256 _amount) public view {
        _amount = bound(_amount, 0, type(uint256).max / FEE_RATE);

        uint256 fee = simplePP.calculateFee(_amount);
        uint256 expected = (_amount * FEE_RATE) / BASIS_POINTS;

        assertEq(fee, expected);
    }

    // Helper: drive a buyer-locked invoice by exhausting manual refundBuyer retries.
    // Uses a NoReceiveEther buyer so every withdraw attempt fails.
    function _getLockedInvoice(uint256 _price) internal returns (uint216 invoiceId) {
        NoReceiveEther noReceiveBuyer = new NoReceiveEther{ value: _price }();

        vm.prank(sellerOne);
        invoiceId = simplePP.createInvoice(_price, "", false);

        vm.deal(address(noReceiveBuyer), _price);
        vm.prank(address(noReceiveBuyer));
        simplePP.pay{ value: _price }(invoiceId, "", false);

        vm.warp(block.timestamp + simplePP.decisionWindow() + 1);

        // 4 calls: retries 0 -> 1, 1 -> 2, 2 -> 3, then 3+1 > MAX_WITHDRAWAL_RETRIES -> LOCKED
        vm.startPrank(address(noReceiveBuyer));
        simplePP.refundBuyer(invoiceId);
        simplePP.refundBuyer(invoiceId);
        simplePP.refundBuyer(invoiceId);
        simplePP.refundBuyer(invoiceId);
        vm.stopPrank();
    }
}
