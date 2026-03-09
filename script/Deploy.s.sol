// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "../src/PaymentProcessorStorage.sol";
import { SimplePaymentProcessor } from "../src/SimplePaymentProcessor.sol";
import { AdvancedPaymentProcessor } from "../src/AdvancedPaymentProcessor.sol";
import { IAdvancedPaymentProcessor } from "../src/interface/IAdvancedPaymentProcessor.sol";
import { MockUsdc, MockWbtc } from "../test/mock/mERC20.sol";
import { Notes } from "../src/Notes.sol";

struct Addr {
    address usdcPriceFeed;
    address wbtcPriceFeed;
    address nativeTokenPriceFeed;
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

    // Arbitrum mainnet tokens
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    // Arbitrum mainnet Chainlink price feeds
    address constant USDC_USD_PRICE_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address constant WBTC_USD_PRICE_FEED = 0x6ce185860a4963106506C203335A2910413708e9;
    address constant NATIVE_TOKEN_USD_PRICE_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    // Arbitrum Sepolia testnet Chainlink price feeds
    address constant TESTNET_USDC_PRICE_FEED = 0x0153002d20B96532C639313c2d54c3dA09109309;
    address constant TESTNET_WBTC_PRICE_FEED = 0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69;
    address constant TESTNET_NATIVE_TOKEN_PRICE_FEED = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;

    uint96 constant FEED_HEARTBEAT = 24 hours;

    uint256 constant TESTNET_CHAIN_ID = 421614;
    uint256 constant MAINNET_CHAIN_ID = 42161;

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

        AdvancedPaymentProcessor advancedPP = new AdvancedPaymentProcessor(address(ppStorage));

        notes.setAuthorized(msg.sender, true);
        notes.setAuthorized(address(simplePP), true);
        notes.setAuthorized(address(advancedPP), true);

        ppStorage.setAuthorizedAddress(address(simplePP), true);
        ppStorage.setAuthorizedAddress(address(advancedPP), true);

        advancedPP.setPriceFeed(
            address(0),
            IAdvancedPaymentProcessor.PriceFeedConfig({
                aggregator: addr.nativeTokenPriceFeed, heartbeat: FEED_HEARTBEAT
            })
        );
        advancedPP.setPriceFeed(
            addr.usdc,
            IAdvancedPaymentProcessor.PriceFeedConfig({ aggregator: addr.usdcPriceFeed, heartbeat: FEED_HEARTBEAT })
        );
        advancedPP.setPriceFeed(
            addr.wbtc,
            IAdvancedPaymentProcessor.PriceFeedConfig({ aggregator: addr.wbtcPriceFeed, heartbeat: FEED_HEARTBEAT })
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
                usdc: address(mockUsdc),
                wbtc: address(mockWBtc)
            });
        }
    }
}
