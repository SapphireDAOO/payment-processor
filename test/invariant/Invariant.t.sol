// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor, SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test, console } from "forge-std/Test.sol";

import { AdvancedPaymentProcessorHandler } from "./handlers/AdvancedPaymentProcessorHandler.sol";
import { SimplePaymentProcessorHandler } from "./handlers/SimplePaymentProcessorHandler.sol";

import { SimplePaymentProcessorSetUp } from "../util/SimplePaymentProcessorSetUp.sol";

contract Invariant is StdInvariant, Test, SimplePaymentProcessorSetUp {
    SimplePaymentProcessorHandler handler;
    

    address creator;
    address payer;

    function setUp() public override {
        super.setUp();
        handler = new SimplePaymentProcessorHandler(simplePP);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.createInvoice.selector;
        selectors[1] = handler.makePayment.selector;
        selectors[2] = handler.cancelInvoice.selector;
        selectors[3] = handler.rejectInvoice.selector;
        selectors[4] = handler.acceptInvoice.selector;
        selectors[5] = handler.releaseInvoice.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function invariant_currentIdIsValid() public view {
        assertEq(handler.totalInvoiceCreated(), simplePP.getNextInvoiceId());
    }

    function invariant_feeBalance() public view {
        assertEq(handler.balance(), feeReceiver.balance);
    }

    function invariant_invoiceStatusDoesNotRevert() public view {
        uint256 count = simplePP.totalInvoiceCreated();
        for (uint256 invoiceId = 1; invoiceId <= count; invoiceId++) {
            ISimplePaymentProcessor.Invoice memory i = simplePP.getInvoiceData(invoiceId);
            assertTrue(i.status >= simplePP.CREATED());
            assertTrue(i.status <= simplePP.RELEASED());
        }
    }

    function invariant_callSummary() public view {
        handler.callSummary();
    }
}
