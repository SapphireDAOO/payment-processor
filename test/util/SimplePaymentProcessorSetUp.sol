// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor, SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { BaseSetUp } from "./BaseSetUp.sol";

abstract contract SimplePaymentProcessorSetUp is BaseSetUp {
    SimplePaymentProcessor simplePP;
    uint256 constant MINIMUM_INVOICE_VALUE = 1 ether;
    uint256 constant DEFAULT_HOLD_PERIOD = 1 days;

    function setUp() public virtual {
        initialize();
        vm.prank(admin);
        simplePP = new SimplePaymentProcessor(address(ppStorage), DEFAULT_HOLD_PERIOD, MINIMUM_INVOICE_VALUE);
    }
}
