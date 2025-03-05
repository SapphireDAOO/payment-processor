// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { PaymentProcessorV1 } from "../src/PaymentProcessorV1.sol";

contract PaymentProcessorV1Script is Script {
    uint256 constant FEE = 0.1 ether;
    uint256 constant DEFAULT_HOLD_PERIOD = 1 minutes;

    function run() external returns (address) {
        vm.startBroadcast();
        PaymentProcessorV1 pp = new PaymentProcessorV1(msg.sender, FEE, DEFAULT_HOLD_PERIOD);
        vm.stopBroadcast();
        return address(pp);
    }
}
