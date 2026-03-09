// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";
import { IAdvancedPaymentProcessor } from "../../src/interface/IAdvancedPaymentProcessor.sol";
import { MockV3Aggregator } from "../mock/MockV3Aggregator.sol";
import { MockUsdc, MockWbtc } from "../mock/mERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseSetUp } from "./BaseSetUp.sol";
import { Notes } from "src/Notes.sol";

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

    int256 constant MOCK_USDC_PRICE = 1e8;
    int256 constant MOCK_WBTC_PRICE = 90_000e8;
    int256 constant MOCK_NATIVE_TOKEN_PRICE = 1960e8;

    address constant FORWARDER = address(0xa0);

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    address constant USDC_USD_PRICE_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address constant WBTC_USD_PRICE_FEED = 0x6ce185860a4963106506C203335A2910413708e9;
    address constant NATIVE_TOKEN_USD_PRICE_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    uint256 constant LOCAL_CHAIN_ID = 31337;
    uint256 constant MAINNET_CHAIN_ID = 42161;

    // fork test
    address constant WTBC_BUYER = 0x5d962D08Ecf162E6471D14D252462D9A165f1a59;
    address constant USDC_BUYER = 0xfFbD3E51Ae0e2c4407434E157965C064F2A11628;
    address constant NATIVE_TOKEN_BUYER = 0xF268e45E467a3A5AC265CFaeDA4443052BC31dD2;

    /// @notice Initializes the base setup and deploys the advanced processor.
    function setUp() public virtual {
        (address storageAddress, address notesAddress) = initialize();

        address ca = address(_advancedPaymentProcessorSetUp(storageAddress));
        vm.prank(admin);
        Notes(notesAddress).setAuthorized(ca, true);
    }

    /**
     * @notice Deploys and configures the AdvancedPaymentProcessor for tests.
     * @param _storageAddress The PaymentProcessorStorage address.
     * @return advancedPaymentProcessor The deployed processor instance.
     */
    function _advancedPaymentProcessorSetUp(address _storageAddress)
        internal
        returns (AdvancedPaymentProcessor advancedPaymentProcessor)
    {
        Addr memory addr = _setUp();

        vm.startPrank(admin);
        advancedPP = new AdvancedPaymentProcessor(_storageAddress);

        PaymentProcessorStorage(_storageAddress).setAuthorizedAddress(address(advancedPP), true);

        advancedPP.setPriceFeed(
            address(addr.usdc),
            IAdvancedPaymentProcessor.PriceFeedConfig({ aggregator: address(addr.usdcPriceFeed), heartbeat: 24 hours })
        );
        advancedPP.setPriceFeed(
            address(addr.wbtc),
            IAdvancedPaymentProcessor.PriceFeedConfig({ aggregator: address(addr.wbtcPriceFeed), heartbeat: 24 hours })
        );
        advancedPP.setPriceFeed(
            address(0),
            IAdvancedPaymentProcessor.PriceFeedConfig({
                aggregator: address(addr.nativeTokenPriceFeed), heartbeat: 24 hours
            })
        );
        vm.stopPrank();

        _mintAndApproveTokens(address(advancedPP));

        if (block.chainid == MAINNET_CHAIN_ID) {
            vm.makePersistent(address(advancedPP), _storageAddress);
        }

        vm.prank(admin);
        advancedPP.setForwarderAddress(FORWARDER);

        advancedPaymentProcessor = advancedPP;
    }

    /**
     * @notice Initializes price feeds and tokens for the current chain.
     * @return addresses The deployed or configured addresses for feeds and tokens.
     */
    function _setUp() internal returns (Addr memory addresses) {
        if (block.chainid == LOCAL_CHAIN_ID) {
            vm.warp(2 hours);

            vm.mockCall(
                0xFdB631F5EE196F0ed6FAa767959853A9F217697D,
                abi.encodeWithSignature("latestRoundData()"),
                abi.encode(uint80(1), 0, 0, block.timestamp, uint80(1))
            );

            MockV3Aggregator mockUsdcPriceFeed = new MockV3Aggregator(8, MOCK_USDC_PRICE);
            MockV3Aggregator mockWbtcPriceFeed = new MockV3Aggregator(8, MOCK_WBTC_PRICE);
            MockV3Aggregator mockNativePriceFeed = new MockV3Aggregator(8, MOCK_NATIVE_TOKEN_PRICE);

            mockUsdc = new MockUsdc("Mock Usdc", "mUsdc");
            mockWBtc = new MockWbtc("Mock WBtc", "mWBtc");

            addresses = Addr({
                usdcPriceFeed: address(mockUsdcPriceFeed),
                wbtcPriceFeed: address(mockWbtcPriceFeed),
                nativeTokenPriceFeed: address(mockNativePriceFeed),
                usdc: address(mockUsdc),
                wbtc: address(mockWBtc)
            });
            return addresses;
        }

        if (block.chainid == MAINNET_CHAIN_ID) {
            addresses = Addr({
                usdcPriceFeed: USDC_USD_PRICE_FEED,
                wbtcPriceFeed: WBTC_USD_PRICE_FEED,
                nativeTokenPriceFeed: NATIVE_TOKEN_USD_PRICE_FEED,
                usdc: USDC,
                wbtc: WBTC
            });
            return addresses;
        }

        revert();
    }

    /**
     * @notice Mints and approves mock tokens when running on a local chain.
     * @param _spender The address to grant maximum token approvals to.
     */
    function _mintAndApproveTokens(address _spender) internal {
        if (block.chainid == LOCAL_CHAIN_ID) {
            mockUsdc.mint(buyerOne, INITIAL_BALANCE);
            mockUsdc.mint(buyerTwo, INITIAL_BALANCE);

            mockWBtc.mint(buyerOne, INITIAL_BALANCE);
            mockWBtc.mint(buyerTwo, INITIAL_BALANCE);

            vm.startPrank(buyerOne);
            IERC20(mockUsdc).approve(_spender, type(uint256).max);
            IERC20(mockWBtc).approve(_spender, type(uint256).max);
            vm.stopPrank();

            vm.startPrank(buyerTwo);
            IERC20(mockUsdc).approve(_spender, type(uint256).max);
            IERC20(mockWBtc).approve(_spender, type(uint256).max);
            vm.stopPrank();
        }

        if (block.chainid == MAINNET_CHAIN_ID) {
            vm.prank(WTBC_BUYER);
            IERC20(WBTC).approve(_spender, type(uint256).max);

            vm.prank(USDC_BUYER);
            IERC20(USDC).approve(_spender, type(uint256).max);
        }
    }
}
