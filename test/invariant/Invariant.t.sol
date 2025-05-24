// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentProcessorV1, PaymentProcessorV1 } from "../../../src/PaymentProcessorV1.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test, console } from "forge-std/Test.sol";

import { HandlerV1 } from "./handlers/HandlerV1.sol";

import { V1 } from "../util/V1.sol";

contract Invariant is StdInvariant, Test, V1 {
    HandlerV1 handler;

    address creator;
    address payer;

    function setUp() public override {
        super.setUp();
        handler = new HandlerV1(pp);

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
        assertEq(handler.totalInvoiceCreated(), pp.getNextInvoiceId());
    }

    function invariant_feeBalance() public view {
        assertEq(handler.balance(), feeReceiver.balance);
    }

    function invariant_invoiceStatusDoesNotRevert() public view {
        uint256 count = pp.totalInvoiceCreated();
        for (uint256 invoiceId = 1; invoiceId <= count; invoiceId++) {
            IPaymentProcessorV1.Invoice memory i = pp.getInvoiceData(invoiceId);
            assertTrue(i.status >= pp.CREATED());
            assertTrue(i.status <= pp.RELEASED());
        }
    }

    function invariant_callSummary() public view {
        handler.callSummary();
    }
}
