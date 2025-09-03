// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { BaseSetUp } from "./BaseSetUp.sol";

abstract contract SimplePaymentProcessorSetUp is BaseSetUp {
    SimplePaymentProcessor simplePP;
    uint256 constant MINIMUM_INVOICE_VALUE = 1 ether;

    function setUp() public virtual {
        address storageAddress = initialize();
        _simplePaymentProcessorSetUp(storageAddress);
    }

    function _simplePaymentProcessorSetUp(address storageAddress) internal virtual returns (SimplePaymentProcessor) {
        vm.startPrank(admin);
        simplePP = new SimplePaymentProcessor(storageAddress, MINIMUM_INVOICE_VALUE);

        PaymentProcessorStorage(storageAddress).setAuthorizedAddress(address(simplePP), true);
        vm.stopPrank();

        return simplePP;
    }
}
