// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { BaseSetUp } from "./BaseSetUp.sol";

abstract contract SimplePaymentProcessorSetUp is BaseSetUp {
    SimplePaymentProcessor simplePP;
    uint256 constant MINIMUM_INVOICE_VALUE = 1 ether;

    address constant FORWARDER_TWO = address(0xb0);

    function setUp() public virtual {
        (address storageAddress, address notesAddress) = initialize();
        _simplePaymentProcessorSetUp(storageAddress, notesAddress);
    }

    function _simplePaymentProcessorSetUp(address storageAddress, address notesAddress)
        internal
        virtual
        returns (SimplePaymentProcessor)
    {
        vm.startPrank(admin);
        simplePP = new SimplePaymentProcessor(storageAddress, MINIMUM_INVOICE_VALUE, notesAddress);

        PaymentProcessorStorage(storageAddress).setAuthorizedAddress(address(simplePP), true);
        vm.stopPrank();

        vm.prank(storageAddress);
        simplePP.setForwarderAddress(FORWARDER_TWO);

        return simplePP;
    }
}
