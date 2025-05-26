// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor, SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test, console } from "forge-std/Test.sol";

import { BaseSetUp } from "../util/BaseSetUp.sol";

import { SimplePaymentProcessorSetUp } from "../util/SimplePaymentProcessorSetUp.sol";
import { AdvancedPaymentProcessorSetUp } from "../util/AdvancedPaymentProcessorSetUp.sol";

import { SimplePaymentProcessorHandler } from "./handlers/SimplePaymentProcessorHandler.sol";
import { AdvancedPaymentProcessorHandler } from "./handlers/AdvancedPaymentProcessorHandler.sol";

contract Invariant is StdInvariant, Test, SimplePaymentProcessorSetUp, AdvancedPaymentProcessorSetUp {
    SimplePaymentProcessorHandler sHandler;
    AdvancedPaymentProcessorHandler aHandler;

    function setUp() public override(SimplePaymentProcessorSetUp, AdvancedPaymentProcessorSetUp) {
        super.setUp();

        sHandler = new SimplePaymentProcessorHandler(simplePP);
        aHandler = new AdvancedPaymentProcessorHandler(advancedPP);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = sHandler.createInvoice.selector;
        selectors[1] = sHandler.makePayment.selector;
        selectors[2] = sHandler.cancelInvoice.selector;
        selectors[3] = sHandler.rejectInvoice.selector;
        selectors[4] = sHandler.acceptInvoice.selector;
        selectors[5] = sHandler.releaseInvoice.selector;

        targetSelector(FuzzSelector({ addr: address(sHandler), selectors: selectors }));
        targetContract(address(sHandler));
    }
}
