// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { PaymentProcessorStorage } from "../src/PaymentProcessorStorage.sol";
import { SimplePaymentProcessor } from "../src/SimplePaymentProcessor.sol";
import { AdvancedPaymentProcessor } from "../src/AdvancedPaymentProcessor.sol";
import { MockUsdc, MockWbtc } from "../test/mock/mERC20.sol";
import { MockV3Aggregator } from "../test/mock/MockV3Aggregator.sol";

struct Addr {
    address usdcPriceFeed;
    address wbtcPriceFeed;
    address nativeTokenPriceFeed;
    address usdc;
    address wbtc;
}

contract Deployer is Script {
    MockUsdc mockUsdc;
    MockWbtc mockWBtc;

    uint256 constant FEE_RATE = 500;
    uint256 constant DEFAULT_HOLD_PERIOD = 10 minutes;
    uint256 constant MINIMUM_INVOICE_VALUE = 0.005 ether;

    address constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address constant WBTC = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

    address constant USDC_USD_PRICE_FEED = 0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7;
    address constant WBTC_USD_PRICE_FEED = 0xDE31F8bFBD8c84b5360CFACCa3539B938dd78ae6;
    address constant POL_USD_PRICE_FEED = 0xAB594600376Ec9fD91F8e885dADF0CE036862dE0;

    int256 constant INITIAL_USDC_PRICE = 1e8;
    int256 constant INITIAL_WBTC_PRICE = 95_000e8;
    int256 constant INITIAL_POL_PRICE = 0.6e8;

    uint256 constant TESTNET_CHAIN_ID = 11155111;
    uint256 constant MAINNET_CHAIN_ID = 137;

    function run() external {
        console.log("-----Deploying-----");
        vm.startBroadcast();
        Addr memory addr = _setUp();

        PaymentProcessorStorage ppStorage = new PaymentProcessorStorage(msg.sender, FEE_RATE);

        SimplePaymentProcessor simplePP =
            new SimplePaymentProcessor(address(ppStorage), DEFAULT_HOLD_PERIOD, MINIMUM_INVOICE_VALUE);

        AdvancedPaymentProcessor advancedPP =
            new AdvancedPaymentProcessor(address(ppStorage), msg.sender, msg.sender, addr.nativeTokenPriceFeed);

        ppStorage.setAuthorizedAddress(address(simplePP), true);
        ppStorage.setAuthorizedAddress(address(advancedPP), true);

        advancedPP.setPriceFeed(address(addr.usdc), address(addr.usdcPriceFeed));
        advancedPP.setPriceFeed(address(addr.wbtc), address(addr.wbtcPriceFeed));

        vm.stopBroadcast();
    }

    function _setUp() internal returns (Addr memory) {
        if (block.chainid == MAINNET_CHAIN_ID) {
            return Addr({
                usdcPriceFeed: USDC_USD_PRICE_FEED,
                wbtcPriceFeed: WBTC_USD_PRICE_FEED,
                nativeTokenPriceFeed: POL_USD_PRICE_FEED,
                usdc: USDC,
                wbtc: WBTC
            });
        } else {
            MockV3Aggregator mockUsdcPriceFeed = new MockV3Aggregator(8, INITIAL_USDC_PRICE);
            MockV3Aggregator mockWbtcPriceFeed = new MockV3Aggregator(8, INITIAL_WBTC_PRICE);
            MockV3Aggregator mockNativePriceFeed = new MockV3Aggregator(8, INITIAL_POL_PRICE);

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
