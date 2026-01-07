// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { BaseSetUp } from "./BaseSetUp.sol";

abstract contract SimplePaymentProcessorSetUp is BaseSetUp {
    SimplePaymentProcessor simplePP;
    uint256 constant MINIMUM_INVOICE_VALUE = 1 ether;

    address constant FORWARDER_TWO = address(0xb0);

    /// @notice Initializes the base setup and deploys the simple payment processor.
    function setUp() public virtual {
        (address storageAddress, address notesAddress) = initialize();
        _simplePaymentProcessorSetUp(storageAddress, notesAddress);
    }

    /**
     * @notice Deploys and configures the SimplePaymentProcessor for tests.
     * @param _storageAddress The PaymentProcessorStorage address.
     * @param _notesAddress The Notes contract address.
     * @return simplePaymentProcessor The deployed processor instance.
     */
    function _simplePaymentProcessorSetUp(address _storageAddress, address _notesAddress)
        internal
        virtual
        returns (SimplePaymentProcessor simplePaymentProcessor)
    {
        vm.startPrank(admin);
        simplePP = new SimplePaymentProcessor(_storageAddress, MINIMUM_INVOICE_VALUE, _notesAddress);

        PaymentProcessorStorage(_storageAddress).setAuthorizedAddress(address(simplePP), true);
        vm.stopPrank();

        vm.prank(_storageAddress);
        simplePP.setForwarderAddress(FORWARDER_TWO);

        simplePaymentProcessor = simplePP;
    }
}
