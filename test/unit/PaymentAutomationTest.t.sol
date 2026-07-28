// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentAutomation } from "../../src/interface/IPaymentAutomation.sol";
import { ISimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { PaymentAutomation } from "../../src/PaymentAutomation.sol";
import { IERC165, IReceiver } from "../../src/interface/IReceiver.sol";
import { SimplePaymentProcessorSetUp } from "../utils/SimplePaymentProcessorSetUp.sol";

import { CRE_SOURCE, GELATO_SOURCE } from "src/constants/Automation.sol";
import { PAID, REFUNDED, RELEASED } from "src/constants/Simple.sol";

contract PaymentAutomationTest is SimplePaymentProcessorSetUp {
    function test_constructorState() public view {
        assertEq(address(automation.processor()), address(simplePP));
        assertEq(address(automation.ppStorage()), address(ppStorage));
        assertEq(automation.getForwarder(), FORWARDER_TWO);
        assertEq(automation.getWorkflowOwner(), WORKFLOW_OWNER);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(IPaymentAutomation.InvalidAddress.selector);
        new PaymentAutomation(address(0), address(ppStorage));

        vm.expectRevert(IPaymentAutomation.InvalidAddress.selector);
        new PaymentAutomation(address(simplePP), address(0));
    }

    // ================================================================
    //                        CONFIGURATION
    // ================================================================

    function test_setForwarderAuthorized() public {
        vm.prank(buyerOne);
        vm.expectRevert(IPaymentAutomation.NotAuthorized.selector);
        automation.setForwarderAddress(address(2));

        address newForwarder = address(0xcafe);

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit IPaymentAutomation.ForwarderUpdated(newForwarder);
        automation.setForwarderAddress(newForwarder);

        assertEq(automation.getForwarder(), newForwarder);
    }

    function test_setWorkflowOwner() public {
        vm.prank(buyerOne);
        vm.expectRevert(IPaymentAutomation.NotAuthorized.selector);
        automation.setWorkflowOwner(address(2));

        address newWorkflowOwner = address(0xdead);
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit IPaymentAutomation.WorkflowOwnerUpdated(newWorkflowOwner);
        automation.setWorkflowOwner(newWorkflowOwner);

        assertEq(automation.getWorkflowOwner(), newWorkflowOwner);
    }

    function test_supportsInterface() public view {
        assertTrue(automation.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(automation.supportsInterface(type(IERC165).interfaceId));
        assertFalse(automation.supportsInterface(0xffffffff));
    }

    // ================================================================
    //                        CHAINLINK CRE
    // ================================================================

    function test_onReportForwarderCanCall() public {
        uint216 invoiceId = _payInvoiceAndWarpPastDecisionWindow();

        vm.prank(FORWARDER_TWO);
        vm.expectEmit(true, true, false, false);
        emit IPaymentAutomation.DueTasksProcessed(FORWARDER_TWO, CRE_SOURCE);
        automation.onReport(_workflowMetadata(WORKFLOW_OWNER), "");

        assertEq(simplePP.getInvoiceData(invoiceId).state, REFUNDED);
    }

    function test_onReportRevertsForNonForwarder() public {
        vm.prank(admin);
        vm.expectRevert(IPaymentAutomation.NotAuthorized.selector);
        automation.onReport(_workflowMetadata(WORKFLOW_OWNER), "");
    }

    function test_onReportRevertsForUnauthorizedWorkflowOwner() public {
        address rogueOwner = address(0xbad);

        vm.prank(FORWARDER_TWO);
        vm.expectRevert(abi.encodeWithSelector(IPaymentAutomation.UnauthorizedWorkflowOwner.selector, rogueOwner));
        automation.onReport(_workflowMetadata(rogueOwner), "");
    }

    function test_onReportRevertsForMalformedMetadata() public {
        vm.prank(FORWARDER_TWO);
        vm.expectRevert(abi.encodeWithSelector(IPaymentAutomation.UnauthorizedWorkflowOwner.selector, address(0)));
        automation.onReport("", "");
    }

    // ================================================================
    //                            GELATO
    // ================================================================

    function test_checkerReportsNoWorkWhenQueueIsEmpty() public view {
        (bool canExec, bytes memory execPayload) = automation.checker();

        assertFalse(canExec);
        assertEq(execPayload, abi.encodeCall(IPaymentAutomation.processDueTasks, ()));
    }

    function test_checkerReportsNoWorkWhileTaskIsNotYetDue() public {
        _payInvoice();

        (bool canExec,) = automation.checker();
        assertFalse(canExec);
    }

    function test_checkerExecPayloadDrainsTheQueue() public {
        uint216 invoiceId = _payInvoiceAndWarpPastDecisionWindow();

        (bool canExec, bytes memory execPayload) = automation.checker();
        assertTrue(canExec);

        // Gelato submits the returned payload verbatim to this contract.
        vm.prank(buyerTwo);
        (bool success,) = address(automation).call(execPayload);

        assertTrue(success);
        assertEq(simplePP.getInvoiceData(invoiceId).state, REFUNDED);

        (canExec,) = automation.checker();
        assertFalse(canExec);
    }

    function test_processDueTasksIsPermissionless() public {
        uint216 invoiceId = _payInvoiceAndWarpPastDecisionWindow();

        vm.prank(buyerTwo);
        vm.expectEmit(true, true, false, false);
        emit IPaymentAutomation.DueTasksProcessed(buyerTwo, GELATO_SOURCE);
        automation.processDueTasks();

        assertEq(simplePP.getInvoiceData(invoiceId).state, REFUNDED);
    }

    function test_processDueTasksIsANoOpWhenNothingIsDue() public {
        uint216 invoiceId = _payInvoice();

        vm.prank(buyerTwo);
        automation.processDueTasks();

        assertEq(simplePP.getItems().length, 1);
        assertEq(simplePP.getInvoiceData(invoiceId).state, PAID);
    }

    function test_hasDueTasksMirrorsTheProcessor() public {
        assertFalse(automation.hasDueTasks());

        _payInvoice();
        assertFalse(automation.hasDueTasks());

        vm.warp(block.timestamp + simplePP.decisionWindow() + 1);
        assertTrue(automation.hasDueTasks());
        assertEq(automation.hasDueTasks(), simplePP.hasDueTasks());
    }

    function test_processDueTasksRevertsOnceDeregistered() public {
        _payInvoiceAndWarpPastDecisionWindow();

        vm.prank(admin);
        simplePP.setAutomation(address(0));

        vm.expectRevert(ISimplePaymentProcessor.NotAuthorized.selector);
        automation.processDueTasks();
    }

    function test_automatedReleaseAfterHoldPeriod() public {
        uint256 invoicePrice = 10 ether;

        vm.prank(sellerOne);
        uint216 invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);

        vm.prank(sellerOne);
        simplePP.acceptPayment(invoiceId);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);

        (bool canExec,) = automation.checker();
        assertTrue(canExec);

        uint256 sellerBalanceBefore = sellerOne.balance;
        uint256 fee = simplePP.calculateFee(invoicePrice);

        automation.processDueTasks();

        assertEq(simplePP.getInvoiceData(invoiceId).state, RELEASED);
        assertEq(sellerOne.balance, sellerBalanceBefore + invoicePrice - fee);
    }

    // ================================================================
    //                            HELPERS
    // ================================================================

    /// @dev Creates and pays an invoice, leaving it scheduled for auto-refund at `expiresAt`.
    function _payInvoice() internal returns (uint216 invoiceId) {
        uint256 invoicePrice = 10 ether;

        vm.prank(sellerOne);
        invoiceId = simplePP.createInvoice(invoicePrice, "", false);

        vm.prank(buyerOne);
        simplePP.pay{ value: invoicePrice }(invoiceId, "", false);
    }

    /// @dev Same as {_payInvoice}, then warps past the seller's decision window so the task is due.
    function _payInvoiceAndWarpPastDecisionWindow() internal returns (uint216 invoiceId) {
        invoiceId = _payInvoice();
        vm.warp(block.timestamp + simplePP.decisionWindow() + 1);
    }
}
