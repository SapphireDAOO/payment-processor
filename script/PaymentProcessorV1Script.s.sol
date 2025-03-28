// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { PaymentProcessorV1 } from "../src/PaymentProcessorV1.sol";

contract PaymentProcessorV1Script is Script {
    uint256 constant FEE_RATE = 700;
    uint256 constant DEFAULT_HOLD_PERIOD = 5 minutes;

    function run() external returns (address) {
        vm.startBroadcast();
        PaymentProcessorV1 pp = new PaymentProcessorV1(msg.sender, FEE_RATE, DEFAULT_HOLD_PERIOD);
        vm.stopBroadcast();
        return address(pp);
    }
}
