// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "../src/PaymentProcessorStorage.sol";
import { SimplePaymentProcessor } from "../src/SimplePaymentProcessor.sol";
import { AdvancedPaymentProcessor } from "../src/AdvancedPaymentProcessor.sol";
import { OracleManager } from "../src/OracleManager.sol";
import { IOracleManager } from "../src/interface/IOracleManager.sol";
import { MockUsdc, MockWbtc } from "../test/mock/mERC20.sol";
import { Notes } from "../src/Notes.sol";

struct Addr {
    address usdcPriceFeed;
    address wbtcPriceFeed;
    address nativeTokenPriceFeed;
    address sequencerUptimeFeed;
    address usdc;
    address wbtc;
}

contract Deploy is Script {
    MockUsdc mockUsdc;
    MockWbtc mockWBtc;

    uint96 constant FEE_RATE = 500;
    uint96 constant DEFAULT_HOLD_PERIOD = 10 minutes;
    uint256 constant MINIMUM_INVOICE_VALUE = 0.005 ether;
    uint96 constant DEFAULT_GAS_THRESHOLD = 100_000;

    // Base mainnet tokens
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    // Base mainnet Chainlink price feeds
    address constant USDC_USD_PRICE_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant WBTC_USD_PRICE_FEED = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address constant NATIVE_TOKEN_USD_PRICE_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant MAINNET_SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // Base Sepolia testnet Chainlink price feeds
    address constant TESTNET_USDC_PRICE_FEED = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
    address constant TESTNET_WBTC_PRICE_FEED = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;
    address constant TESTNET_NATIVE_TOKEN_PRICE_FEED = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;

    uint96 constant FEED_HEARTBEAT = 24 hours;

    uint256 constant TESTNET_CHAIN_ID = 84532;
    uint256 constant MAINNET_CHAIN_ID = 8453;

    function run() external {
        console.log("-----Deploying-----");
        console.log("Chain ID:", block.chainid);
        vm.startBroadcast();

        Addr memory addr = _setUp();

        IPaymentProcessorStorage.Configuration memory config = IPaymentProcessorStorage.Configuration({
            owner: msg.sender,
            feeReceiver: msg.sender,
            marketplace: msg.sender,
            feeRate: FEE_RATE,
            defaultHoldPeriod: DEFAULT_HOLD_PERIOD,
            gasThreshold: DEFAULT_GAS_THRESHOLD
        });

        PaymentProcessorStorage ppStorage = new PaymentProcessorStorage(config);

        Notes notes = new Notes(address(ppStorage));

        SimplePaymentProcessor simplePP =
            new SimplePaymentProcessor(address(ppStorage), MINIMUM_INVOICE_VALUE, address(notes));

        OracleManager oracle = new OracleManager(address(ppStorage), addr.sequencerUptimeFeed);

        AdvancedPaymentProcessor advancedPP = new AdvancedPaymentProcessor(address(ppStorage), address(oracle));

        notes.setAuthorized(msg.sender, true);
        notes.setAuthorized(address(simplePP), true);
        notes.setAuthorized(address(advancedPP), true);

        ppStorage.setAuthorizedAddress(address(simplePP), true);
        ppStorage.setAuthorizedAddress(address(advancedPP), true);

        oracle.setPriceFeed(
            address(0),
            IOracleManager.PriceFeedConfig({ aggregator: addr.nativeTokenPriceFeed, heartbeat: FEED_HEARTBEAT })
        );
        oracle.setPriceFeed(
            addr.usdc, IOracleManager.PriceFeedConfig({ aggregator: addr.usdcPriceFeed, heartbeat: FEED_HEARTBEAT })
        );
        oracle.setPriceFeed(
            addr.wbtc, IOracleManager.PriceFeedConfig({ aggregator: addr.wbtcPriceFeed, heartbeat: FEED_HEARTBEAT })
        );

        vm.stopBroadcast();

        console.log("-----Deployed-----");
        console.log("PaymentProcessorStorage:", address(ppStorage));
        console.log("Notes:                 ", address(notes));
        console.log("SimplePaymentProcessor:", address(simplePP));
        console.log("AdvancedPaymentProcessor:", address(advancedPP));
        if (block.chainid != MAINNET_CHAIN_ID) {
            console.log("MockUsdc:              ", addr.usdc);
            console.log("MockWbtc:              ", addr.wbtc);
        }
    }

    function _setUp() internal returns (Addr memory) {
        if (block.chainid == MAINNET_CHAIN_ID) {
            return Addr({
                usdcPriceFeed: USDC_USD_PRICE_FEED,
                wbtcPriceFeed: WBTC_USD_PRICE_FEED,
                nativeTokenPriceFeed: NATIVE_TOKEN_USD_PRICE_FEED,
                sequencerUptimeFeed: MAINNET_SEQUENCER_UPTIME_FEED,
                usdc: USDC,
                wbtc: WBTC
            });
        } else {
            mockUsdc = new MockUsdc("Mock Usdc", "mUsdc");
            mockWBtc = new MockWbtc("Mock WBtc", "mWBtc");

            return Addr({
                usdcPriceFeed: TESTNET_USDC_PRICE_FEED,
                wbtcPriceFeed: TESTNET_WBTC_PRICE_FEED,
                nativeTokenPriceFeed: TESTNET_NATIVE_TOKEN_PRICE_FEED,
                sequencerUptimeFeed: address(0),
                usdc: address(mockUsdc),
                wbtc: address(mockWBtc)
            });
        }
    }
}
