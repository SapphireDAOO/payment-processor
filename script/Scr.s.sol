// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";

import { AdvancedPaymentProcessor } from "../src/AdvancedPaymentProcessor.sol";

contract Scr is Script {
    function run() external {
        console.log("----------");
        // vm.startBroadcast();

        AdvancedPaymentProcessor advancedPP = AdvancedPaymentProcessor(0xf041a2Cd5f87fC7d02C3A42B02dC479582538D26);

        vm.startBroadcast(0xCdB1Fc39E18C0d0A10c99Cc84e13d595d34d56A5);
        advancedPP.createDispute(
            0xc279c50e455fb7b90dc9398151a2ce5925c0c5df4b701d99022f219c221a53ec
        );

        vm.stopBroadcast();
    }
}
