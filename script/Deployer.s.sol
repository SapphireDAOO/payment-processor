// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { PaymentProcessorStorage } from "../src/PaymentProcessorStorage.sol";
import { SimplePaymentProcessor } from "../src/SimplePaymentProcessor.sol";
import { AdvancedPaymentProcessor } from "../src/AdvancedPaymentProcessor.sol";

contract Deployer is Script {
    uint256 constant FEE_RATE = 500;
    uint256 constant DEFAULT_HOLD_PERIOD = 10 minutes;
    uint256 constant MINIMUM_INVOICE_VALUE = 0.1 ether;

    address constant POL_USD_PRICE_FEED = 0xAB594600376Ec9fD91F8e885dADF0CE036862dE0;

    function run() external {
        vm.startBroadcast();

        PaymentProcessorStorage ppStorage = new PaymentProcessorStorage(msg.sender, FEE_RATE);

        new SimplePaymentProcessor(address(ppStorage), DEFAULT_HOLD_PERIOD, MINIMUM_INVOICE_VALUE);

        new AdvancedPaymentProcessor(address(ppStorage), msg.sender, msg.sender, POL_USD_PRICE_FEED);
        vm.stopBroadcast();
    }
}
