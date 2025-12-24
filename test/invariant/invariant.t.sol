// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { BaseSetUp, PaymentProcessorStorage } from "../utils/BaseSetUp.sol";

import { SimplePaymentProcessorSetUp, SimplePaymentProcessor } from "../utils/SimplePaymentProcessorSetUp.sol";
import { AdvancedPaymentProcessorSetUp, AdvancedPaymentProcessor } from "../utils/AdvancedPaymentProcessorSetUp.sol";

import { SimplePaymentProcessorHandler } from "./handlers/SimplePaymentProcessorHandler.sol";
import { AdvancedPaymentProcessorHandler } from "./handlers/AdvancedPaymentProcessorHandler.sol";

contract Invariant is StdInvariant, Test, BaseSetUp, SimplePaymentProcessorSetUp, AdvancedPaymentProcessorSetUp {
    SimplePaymentProcessorHandler sHandler;
    AdvancedPaymentProcessorHandler aHandler;
    address storageAddress;
    address notesAddress;

    SimplePaymentProcessor simplePaymentProcessor;
    AdvancedPaymentProcessor advancedPaymentProcessor;

    function setUp() public override(SimplePaymentProcessorSetUp, AdvancedPaymentProcessorSetUp) {
        (storageAddress, notesAddress) = initialize();

        simplePaymentProcessor = _simplePaymentProcessorSetUp(storageAddress, notesAddress);
        advancedPaymentProcessor = _advancedPaymentProcessorSetUp(storageAddress);

        sHandler = new SimplePaymentProcessorHandler(simplePaymentProcessor, buyerOne, sellerOne);
        aHandler = new AdvancedPaymentProcessorHandler(advancedPaymentProcessor, admin, buyerOne, sellerOne);

        bytes4[] memory sExcludedSelectors = new bytes4[](2);
        sExcludedSelectors[0] = sHandler.callSummary.selector;
        sExcludedSelectors[1] = sHandler.getTotalInvoiceCreated.selector;

        bytes4[] memory aExcludedSelectors = new bytes4[](3);
        aExcludedSelectors[0] = aHandler.callSummary.selector;
        aExcludedSelectors[1] = aHandler.getTotalSingleInvoiceCreated.selector;
        aExcludedSelectors[2] = aHandler.getTotalMetaInvoiceCreated.selector;

        excludeSelector(FuzzSelector({ addr: address(sHandler), selectors: sExcludedSelectors }));
        excludeSelector(FuzzSelector({ addr: address(aHandler), selectors: aExcludedSelectors }));

        targetContract(address(aHandler));
        targetContract(address(sHandler));
    }

    function invariant_consistentId() external view {
        uint256 totalFromHandlers = sHandler.getTotalInvoiceCreated() + aHandler.getTotalSingleInvoiceCreated();
        uint256 totalInStorage = PaymentProcessorStorage(storageAddress).totalInvoiceCreated();
        assertEq(totalFromHandlers, totalInStorage);
    }

    function invariant_consistentMetaInvoiceId() external view {
        assertEq(aHandler.getTotalMetaInvoiceCreated(), advancedPaymentProcessor.totalMetaInvoiceCreated());
    }

    function invariant_handleSimpleCallSummary() public view {
        sHandler.callSummary();
    }

    function invariant_handleAdvancedCallSummary() public view {
        aHandler.callSummary();
    }
}
