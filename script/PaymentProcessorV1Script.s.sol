// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PaymentProcessorStorage } from "../src/PaymentProcessorStorage.sol";
import { SimplePaymentProcessor } from "../src/SimplePaymentProcessor.sol";
import { Script } from "forge-std/Script.sol";

contract SimplePaymentProcessorScript is Script {
    uint256 constant FEE_RATE = 700;
    uint256 constant DEFAULT_HOLD_PERIOD = 10 minutes;
    uint256 constant MINIMUM_INVOICE_VALUE = 0.1 ether;

    address FEE_RECEIVER;

    function run() external returns (address) {
        vm.startBroadcast();
        PaymentProcessorStorage ppStorage = new PaymentProcessorStorage(FEE_RECEIVER, FEE_RATE);
        SimplePaymentProcessor pp =
            new SimplePaymentProcessor(address(ppStorage), DEFAULT_HOLD_PERIOD, MINIMUM_INVOICE_VALUE);
        vm.stopBroadcast();
        return address(pp);
    }
}
