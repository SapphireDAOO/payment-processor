// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";
import { OracleManager } from "../../src/OracleManager.sol";
import { IOracleManager } from "../../src/interface/IOracleManager.sol";
import { MockV3Aggregator } from "../mock/MockV3Aggregator.sol";
import { MockUsdc, MockWbtc } from "../mock/mERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BaseSetUp } from "./BaseSetUp.sol";
import { Notes } from "src/Notes.sol";

struct Addr {
    address usdcPriceFeed;
    address wbtcPriceFeed;
    address nativeTokenPriceFeed;
    address sequencerUptimeFeed;
    address usdc;
    address wbtc;
}

abstract contract AdvancedPaymentProcessorSetUp is BaseSetUp {
    AdvancedPaymentProcessor advancedPP;
    OracleManager oracle;
    MockUsdc mockUsdc;
    MockWbtc mockWBtc;

    int256 constant MOCK_USDC_PRICE = 1e8;
    int256 constant MOCK_WBTC_PRICE = 90_000e8;
    int256 constant MOCK_NATIVE_TOKEN_PRICE = 1960e8;

    address constant FORWARDER = address(0xa0);

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    address constant USDC_USD_PRICE_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant WBTC_USD_PRICE_FEED = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address constant NATIVE_TOKEN_USD_PRICE_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    uint256 constant LOCAL_CHAIN_ID = 31337;
    uint256 constant MAINNET_CHAIN_ID = 8453;

    address constant WTBC_BUYER = 0x03b69Ae9423DF674eAF396c157a03BE9349208f1;
    address constant USDC_BUYER = 0x5b7AC4a00E5ABf254e5a7FD23c2ee2b34b6a50cE;
    address constant NATIVE_TOKEN_BUYER = 0xBefa750Ed568Cc84970eB4FD506aF4FF599c42D0;

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

        oracle = new OracleManager();
        oracle.setSequencerUptimeFeed(addr.sequencerUptimeFeed);
        oracle.setPriceFeed(
            address(addr.usdc),
            IOracleManager.PriceFeedConfig({ aggregator: address(addr.usdcPriceFeed), heartbeat: 24 hours })
        );
        oracle.setPriceFeed(
            address(addr.wbtc),
            IOracleManager.PriceFeedConfig({ aggregator: address(addr.wbtcPriceFeed), heartbeat: 24 hours })
        );
        oracle.setPriceFeed(
            address(0),
            IOracleManager.PriceFeedConfig({ aggregator: address(addr.nativeTokenPriceFeed), heartbeat: 24 hours })
        );

        vm.startPrank(admin);
        advancedPP = new AdvancedPaymentProcessor(_storageAddress, address(oracle));

        PaymentProcessorStorage(_storageAddress).setAuthorizedAddress(address(advancedPP), true);
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
                SEQUENCER_UPTIME_FEED,
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
                sequencerUptimeFeed: SEQUENCER_UPTIME_FEED,
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
                sequencerUptimeFeed: SEQUENCER_UPTIME_FEED,
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
