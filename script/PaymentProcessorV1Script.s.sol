// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { PaymentProcessorV1 } from "../src/PaymentProcessorV1.sol";
import { PaymentProcessorStorage } from "../src/PaymentProcessorStorage.sol";

contract PaymentProcessorV1Script is Script {
    uint256 constant FEE_RATE = 700;
    uint256 constant DEFAULT_HOLD_PERIOD = 10 minutes;
    uint256 constant MINIMUM_INVOICE_VALUE = 0.1 ether;

    address FEE_RECEIVER;

    function run() external returns (address) {
        vm.startBroadcast();
        PaymentProcessorStorage ppStorage = new PaymentProcessorStorage(FEE_RECEIVER, FEE_RATE);
        PaymentProcessorV1 pp = new PaymentProcessorV1(address(ppStorage), DEFAULT_HOLD_PERIOD, MINIMUM_INVOICE_VALUE);
        vm.stopBroadcast();
        return address(pp);
    }
}
