// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "../src/PaymentProcessorStorage.sol";
import { SimplePaymentProcessor } from "../src/SimplePaymentProcessor.sol";
import { AdvancedPaymentProcessor } from "../src/AdvancedPaymentProcessor.sol";
import { IAdvancedPaymentProcessor } from "../src/interface/IAdvancedPaymentProcessor.sol";
import { MockUsdc, MockWbtc } from "../test/mock/mERC20.sol";
import { MockV3Aggregator } from "../test/mock/MockV3Aggregator.sol";
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

    uint256 constant FEE_RATE = 500;
    uint256 constant DEFAULT_HOLD_PERIOD = 10 minutes;
    uint256 constant MINIMUM_INVOICE_VALUE = 0.005 ether;
    uint256 constant DEFAULT_GAS_Threshold = 100_000;

    address constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address constant WBTC = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

    address constant USDC_USD_PRICE_FEED = 0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7;
    address constant WBTC_USD_PRICE_FEED = 0xDE31F8bFBD8c84b5360CFACCa3539B938dd78ae6;
    address constant NATIVE_TOKEN_USD_PRICE_FEED = 0xAB594600376Ec9fD91F8e885dADF0CE036862dE0;

    int256 constant MOCK_USDC_PRICE = 1e8;
    int256 constant MOCK_WBTC_PRICE = 90_000e8;
    int256 constant MOCK_NATIVE_TOKEN_PRICE = 1960e8;

    uint96 constant NATIVE_TOKEN_FEED_HEARTBEAT = 24 hours;
    uint96 constant USDC_FEED_HEARTBEAT = 24 hours;
    uint96 constant WBTC_FEED_HEARTBEAT = 24 hours;
    uint96 constant MOCK_FEED_HEARTBEAT = 1 hours;

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
            feeRate: uint96(FEE_RATE),
            defaultHoldPeriod: uint96(DEFAULT_HOLD_PERIOD),
            gasThreshold: uint96(DEFAULT_GAS_Threshold)
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
        PaymentProcessorStorage(ppStorage).setAuthorizedAddress(address(advancedPP), true);

        bool isMainnet = block.chainid == MAINNET_CHAIN_ID;
        uint96 nativeHb = isMainnet ? NATIVE_TOKEN_FEED_HEARTBEAT : MOCK_FEED_HEARTBEAT;
        uint96 usdcHb = isMainnet ? USDC_FEED_HEARTBEAT : MOCK_FEED_HEARTBEAT;
        uint96 wbtcHb = isMainnet ? WBTC_FEED_HEARTBEAT : MOCK_FEED_HEARTBEAT;

        advancedPP.setPriceFeed(
            address(0),
            IAdvancedPaymentProcessor.PriceFeedConfig({ aggregator: addr.nativeTokenPriceFeed, heartbeat: nativeHb })
        );
        advancedPP.setPriceFeed(
            addr.usdc, IAdvancedPaymentProcessor.PriceFeedConfig({ aggregator: addr.usdcPriceFeed, heartbeat: usdcHb })
        );
        advancedPP.setPriceFeed(
            addr.wbtc, IAdvancedPaymentProcessor.PriceFeedConfig({ aggregator: addr.wbtcPriceFeed, heartbeat: wbtcHb })
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
            MockV3Aggregator mockUsdcPriceFeed = new MockV3Aggregator(8, MOCK_USDC_PRICE);
            MockV3Aggregator mockWbtcPriceFeed = new MockV3Aggregator(8, MOCK_WBTC_PRICE);
            MockV3Aggregator mockNativePriceFeed = new MockV3Aggregator(8, MOCK_NATIVE_TOKEN_PRICE);

            mockUsdc = new MockUsdc("Mock Usdc", "mUsdc");
            mockWBtc = new MockWbtc("Mock WBtc", "mWBtc");

            return Addr({
                usdcPriceFeed: address(mockUsdcPriceFeed),
                wbtcPriceFeed: address(mockWbtcPriceFeed),
                nativeTokenPriceFeed: address(mockNativePriceFeed),
                usdc: address(mockUsdc),
                wbtc: address(mockWBtc)
            });
        }
    }
}
