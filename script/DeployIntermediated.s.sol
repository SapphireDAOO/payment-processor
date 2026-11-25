// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { console } from "forge-std/Script.sol";
import { DeployConfig, Addr, Core } from "./DeployConfig.s.sol";
import { IntermediatedPaymentProcessor } from "../src/IntermediatedPaymentProcessor.sol";
import { OracleManager } from "../src/OracleManager.sol";
import { IOracleManager } from "../src/interface/IOracleManager.sol";
import { PaymentProcessorStorage } from "../src/PaymentProcessorStorage.sol";

/**
 * @title DeployIntermediated
 * @notice Deploys the core (unless reused from env), the OracleManager (unless ORACLE_MANAGER is set) and the
 *         IntermediatedPaymentProcessor, and registers the price feeds.
 */
contract DeployIntermediated is DeployConfig {
    function run() external {
        bytes32 salt = _deploySalt();
        _logHeader("Intermediated Processor Deployment", salt);

        vm.startBroadcast();
        Addr memory addr = _network(salt);
        Core memory core = _deployCore(salt, addr.weth);
        _deployIntermediated(salt, address(core.ppStorage), addr);
        _handover(core);
        vm.stopBroadcast();
    }

    function _deployIntermediated(bytes32 _salt, address _ppStorage, Addr memory _addr)
        internal
        returns (IntermediatedPaymentProcessor processor)
    {
        address existingOracle = _envAddress("ORACLE_MANAGER");

        console.log("--- Intermediated processor ---");

        OracleManager oracle = existingOracle != address(0)
            ? OracleManager(existingOracle)
            : OracleManager(
                _create2(
                    "OracleManager",
                    _salt,
                    abi.encodePacked(
                        type(OracleManager).creationCode, abi.encode(_ppStorage, _addr.sequencerUptimeFeed)
                    )
                )
            );
        if (existingOracle != address(0)) console.log("OracleManager (reused):", existingOracle);

        processor = IntermediatedPaymentProcessor(
            payable(_create2(
                    "IntermediatedPaymentProcessor",
                    _salt,
                    abi.encodePacked(
                        type(IntermediatedPaymentProcessor).creationCode, abi.encode(_ppStorage, address(oracle))
                    )
                ))
        );

        // setPriceFeed is gated on the storage owner; a reused manager keeps its own feeds.
        if (existingOracle != address(0)) {
            console.log("Price feeds left as configured on the existing OracleManager");
        } else if (PaymentProcessorStorage(_ppStorage).owner() != msg.sender) {
            console.log("Storage is owned by another account; set the price feeds through it");
        } else {
            _setPriceFeeds(oracle, _addr);
        }
        console.log("");
    }

    /// @dev Mock feeds (non-mainnet) report a static timestamp, so heartbeat 0 disables the staleness check there.
    function _setPriceFeeds(OracleManager _oracle, Addr memory _addr) private {
        uint96 heartbeat = block.chainid == MAINNET_CHAIN_ID ? FEED_HEARTBEAT : 0;

        _oracle.setPriceFeed(
            address(0),
            IOracleManager.PriceFeedConfig({
                aggregator: _addr.nativeTokenPriceFeed, heartbeat: heartbeat, allowed: true
            })
        );
        _oracle.setPriceFeed(
            _addr.usdc,
            IOracleManager.PriceFeedConfig({ aggregator: _addr.usdcPriceFeed, heartbeat: heartbeat, allowed: true })
        );
        _oracle.setPriceFeed(
            _addr.wbtc,
            IOracleManager.PriceFeedConfig({ aggregator: _addr.wbtcPriceFeed, heartbeat: heartbeat, allowed: true })
        );
        console.log("Price feeds set: ETH/USD, USDC/USD, WBTC/USD");
    }
}
