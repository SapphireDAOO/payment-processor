// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { console } from "forge-std/Script.sol";
import { DeployConfig, Addr, Core } from "./DeployConfig.s.sol";
import { ISimpleDeployer } from "../src/interface/ISimpleDeployer.sol";
import { SimpleDeployer } from "../src/SimpleDeployer.sol";
import { SimplePaymentProcessor } from "../src/SimplePaymentProcessor.sol";
import { PaymentAutomation } from "../src/PaymentAutomation.sol";
import { Notes } from "../src/Notes.sol";

/**
 * @title DeploySimple
 * @notice Deploys the SimplePaymentProcessor, PaymentAutomation and Notes through a {SimpleDeployer}, against the
 *         core {DeployIntermediated} deployed.
 */
contract DeploySimple is DeployConfig {
    function run() external {
        bytes32 salt = _deploySalt();
        _logHeader("Simple Processor Deployment", salt);

        vm.startBroadcast();
        Addr memory addr = _network(salt);
        Core memory core = _existingCore(salt, addr.weth);
        _deploySimple(salt, address(core.ppStorage));
        _handover(core);
        vm.stopBroadcast();
    }

    function _deploySimple(bytes32 _salt, address _ppStorage) internal returns (SimpleDeployer deployer) {
        console.log("--- Simple processor ---");
        console.log("Hold period (s):", _escrowHoldPeriod());

        deployer = SimpleDeployer(
            _create2(
                "SimpleDeployer", _salt, abi.encodePacked(type(SimpleDeployer).creationCode, abi.encode(msg.sender))
            )
        );

        if (address(deployer.simplePaymentProcessor()) == address(0)) {
            deployer.deploy(
                ISimpleDeployer.Params({
                    salt: _salt,
                    ppStorage: _ppStorage,
                    escrowHoldPeriod: _escrowHoldPeriod(),
                    forwarder: vm.envOr("CRE_FORWARDER", DEFAULT_CRE_FORWARDER),
                    workflowOwner: vm.envOr("CRE_WORKFLOW_OWNER", DEFAULT_CRE_WORKFLOW_OWNER)
                }),
                ISimpleDeployer.InitCodes({
                    notes: type(Notes).creationCode,
                    simplePaymentProcessor: type(SimplePaymentProcessor).creationCode,
                    paymentAutomation: type(PaymentAutomation).creationCode
                })
            );
        } else {
            console.log("Simple processor already deployed");
        }

        console.log("SimplePaymentProcessor:", address(deployer.simplePaymentProcessor()));
        console.log("PaymentAutomation:     ", address(deployer.paymentAutomation()));
        console.log("Notes:                 ", address(deployer.notes()));
        console.log("");
    }
}
