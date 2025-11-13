// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";
import { MockV3Aggregator } from "../mock/MockV3Aggregator.sol";
import { MockUsdc, MockWbtc } from "../mock/mERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseSetUp } from "./BaseSetUp.sol";

struct Addr {
    address usdcPriceFeed;
    address wbtcPriceFeed;
    address nativeTokenPriceFeed;
    address usdc;
    address wbtc;
}

abstract contract AdvancedPaymentProcessorSetUp is BaseSetUp {
    AdvancedPaymentProcessor advancedPP;
    MockUsdc mockUsdc;
    MockWbtc mockWBtc;

    int256 constant INITIAL_USDC_PRICE = 1e8;
    int256 constant INITIAL_WBTC_PRICE = 90_000e8;
    int256 constant INITIAL_POL_PRICE = 0.6e8;

    address constant FORWARDER = address(0xa0);

    address constant USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address constant WBTC = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;

    address constant USDC_USD_PRICE_FEED = 0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7;
    address constant WBTC_USD_PRICE_FEED = 0xDE31F8bFBD8c84b5360CFACCa3539B938dd78ae6;
    address constant POL_USD_PRICE_FEED = 0xAB594600376Ec9fD91F8e885dADF0CE036862dE0;

    uint256 constant LOCAL_CHAIN_ID = 31337;
    uint256 constant MAINNET_CHAIN_ID = 137;

    // fork test
    address constant WTBC_BUYER = 0x0AFF6665bB45bF349489B20E225A6c5D78E2280F;
    address constant USDC_BUYER = 0x166716C2838e182d64886135a96f1AABCA9A9756;
    address constant NATIVE_TOKEN_BUYER = 0x5e86A14B06a4001cA83688cc06568A0c07425f63;

    function setUp() public virtual {
        address storageAddress = initialize();
        _advancedPaymentProcessorSetUp(storageAddress);
    }

    function _advancedPaymentProcessorSetUp(address storageAddress) internal returns (AdvancedPaymentProcessor) {
        Addr memory addr = _setUp();

        vm.startPrank(admin);
        advancedPP = new AdvancedPaymentProcessor(storageAddress, address(addr.nativeTokenPriceFeed));

        PaymentProcessorStorage(storageAddress).setAuthorizedAddress(address(advancedPP), true);

        advancedPP.setPriceFeed(address(addr.usdc), address(addr.usdcPriceFeed));
        advancedPP.setPriceFeed(address(addr.wbtc), address(addr.wbtcPriceFeed));
        vm.stopPrank();

        _mintAndApproveTokens(address(advancedPP));

        if (block.chainid == MAINNET_CHAIN_ID) {
            vm.makePersistent(address(advancedPP), storageAddress);
        }

        vm.prank(storageAddress);
        advancedPP.setForwarderAddress(FORWARDER);

        return advancedPP;
    }

    function _setUp() internal returns (Addr memory) {
        if (block.chainid == LOCAL_CHAIN_ID) {
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

        if (block.chainid == MAINNET_CHAIN_ID) {
            return Addr({
                usdcPriceFeed: USDC_USD_PRICE_FEED,
                wbtcPriceFeed: WBTC_USD_PRICE_FEED,
                nativeTokenPriceFeed: POL_USD_PRICE_FEED,
                usdc: USDC,
                wbtc: WBTC
            });
        }

        revert();
    }

    function _mintAndApproveTokens(address spender) internal {
        if (block.chainid == LOCAL_CHAIN_ID) {
            mockUsdc.mint(buyerOne, INITIAL_BALANCE);
            mockUsdc.mint(buyerTwo, INITIAL_BALANCE);

            mockWBtc.mint(buyerOne, INITIAL_BALANCE);
            mockWBtc.mint(buyerTwo, INITIAL_BALANCE);

            vm.startPrank(buyerOne);
            IERC20(mockUsdc).approve(spender, type(uint256).max);
            IERC20(mockWBtc).approve(spender, type(uint256).max);
            vm.stopPrank();

            vm.startPrank(buyerTwo);
            IERC20(mockUsdc).approve(spender, type(uint256).max);
            IERC20(mockWBtc).approve(spender, type(uint256).max);
            vm.stopPrank();
        }

        if (block.chainid == MAINNET_CHAIN_ID) {
            vm.prank(WTBC_BUYER);
            IERC20(WBTC).approve(spender, type(uint256).max);

            vm.prank(USDC_BUYER);
            IERC20(USDC).approve(spender, type(uint256).max);
        }
    }
}
