// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { ISimplePaymentProcessor, SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { BaseSetUp } from "./BaseSetUp.sol";

abstract contract SimplePaymentProcessorSetUp is BaseSetUp {
    SimplePaymentProcessor simplePP;
    uint256 constant MINIMUM_INVOICE_VALUE = 1 ether;
    uint256 constant DEFAULT_HOLD_PERIOD = 1 days;

    function setUp() public virtual {
        address storageAddress = initialize();
        _simplePaymentProcessorSetUp(storageAddress);
    }

    function _simplePaymentProcessorSetUp(address storageAddress) internal virtual returns (SimplePaymentProcessor) {
        vm.prank(admin);
        simplePP = new SimplePaymentProcessor(storageAddress, DEFAULT_HOLD_PERIOD, MINIMUM_INVOICE_VALUE);

        PaymentProcessorStorage(storageAddress).setAuthorizedAddress(address(simplePP), true);

        return simplePP;
    }
}
