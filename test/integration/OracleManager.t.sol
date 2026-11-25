// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { IOracleManager } from "../../src/interface/IOracleManager.sol";
import { AggregatorV3Interface } from "../../src/interface/AggregatorV3Interface.sol";
import { IntermediatedPaymentProcessorSetUp } from "../utils/IntermediatedPaymentProcessorSetUp.sol";

contract OracleManagerInteractions is IntermediatedPaymentProcessorSetUp {
    string MAINNET_RPC = vm.envString("MAINNET_RPC");

    uint256 constant HEARTBEAT = 24 hours;

    function setUp() public override {
        bytes memory latest = vm.rpc(MAINNET_RPC, "eth_blockNumber", "[]");
        uint256 forkBlock = uint256(bytes32(latest)) >> (256 - latest.length * 8);

        uint256 fork = vm.createFork(MAINNET_RPC, forkBlock);
        vm.selectFork(fork);
        super.setUp();
    }

    function test_readsLivePrices() public view {
        uint256 usdcPrice = oracle.getUsdPerToken(USDC);
        assertApproxEqRel(usdcPrice, 1e8, 0.02e18);

        assertGt(oracle.getUsdPerToken(address(0)), 100e8);
        assertGt(oracle.getUsdPerToken(WBTC), 1000e8);
    }

    function test_batchMatchesSinglePrices() public view {
        address[] memory tokens = _tokens();

        (uint256[] memory prices, uint256[] memory validUntil) = oracle.getUsdPerTokenBatch(tokens);

        for (uint256 i; i < tokens.length; i++) {
            assertEq(prices[i], oracle.getUsdPerToken(tokens[i]));
            assertEq(validUntil[i], _updatedAt(_feedOf(tokens[i])) + HEARTBEAT);
            assertGe(validUntil[i], block.timestamp);
        }
    }

    function test_batchIsValidUntilTheEarliestExpiry() public {
        uint256 forkTimestamp = block.timestamp;
        address[] memory tokens = _tokens();
        (, uint256[] memory validUntil) = oracle.getUsdPerTokenBatch(tokens);

        uint256 earliest = validUntil[0];
        for (uint256 i = 1; i < validUntil.length; i++) {
            if (validUntil[i] < earliest) earliest = validUntil[i];
        }

        vm.warp(earliest);
        oracle.getUsdPerTokenBatch(tokens);

        vm.warp(forkTimestamp + HEARTBEAT + 1);
        vm.expectRevert(IOracleManager.StalePriceFeed.selector);
        oracle.getUsdPerTokenBatch(tokens);
    }

    function test_valueInCurrencyUsesLiveRates() public view {
        (uint256 usdcInUsdc, uint256 usdcValidUntil) = oracle.getValueInCurrency(USDC, 1000e6, USDC_USD_PRICE_FEED);
        assertEq(usdcInUsdc, 1000e8);
        assertEq(usdcValidUntil, _updatedAt(USDC_USD_PRICE_FEED) + HEARTBEAT);

        (uint256 ethInUsdc, uint256 ethValidUntil) = oracle.getValueInCurrency(address(0), 1e18, USDC_USD_PRICE_FEED);
        uint256 expected = oracle.getUsdPerToken(address(0)) * 1e8 / oracle.getUsdPerToken(USDC);
        assertEq(ethInUsdc, expected);
        assertEq(ethValidUntil, _updatedAt(NATIVE_TOKEN_USD_PRICE_FEED) + HEARTBEAT);
    }

    function test_valueInCurrencyIsValidUntilItsExpiry() public {
        uint256 forkTimestamp = block.timestamp;
        (, uint256 validUntil) = oracle.getValueInCurrency(WBTC, 1e8, USDC_USD_PRICE_FEED);

        vm.warp(validUntil);
        oracle.getValueInCurrency(WBTC, 1e8, USDC_USD_PRICE_FEED);

        // Not validUntil + 1: the WBTC DualAggregator reveals newer rounds as time passes.
        vm.warp(forkTimestamp + HEARTBEAT + 1);
        vm.expectRevert(IOracleManager.StalePriceFeed.selector);
        oracle.getValueInCurrency(WBTC, 1e8, USDC_USD_PRICE_FEED);
    }

    function test_revertsWhenTheSequencerIsDown() public {
        vm.mockCall(
            SEQUENCER_UPTIME_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), block.timestamp, block.timestamp, uint80(1))
        );

        vm.expectRevert(IOracleManager.SequencerDown.selector);
        oracle.getUsdPerToken(address(0));

        vm.expectRevert(IOracleManager.SequencerDown.selector);
        oracle.getUsdPerTokenBatch(_tokens());

        vm.expectRevert(IOracleManager.SequencerDown.selector);
        oracle.getValueInCurrency(address(0), 1e18, USDC_USD_PRICE_FEED);
    }

    function test_revertsForAnUnregisteredToken() public {
        vm.expectRevert(IOracleManager.UnsupportedToken.selector);
        oracle.getUsdPerToken(address(0xdead));
    }

    function _tokens() internal pure returns (address[] memory tokens) {
        tokens = new address[](3);
        tokens[0] = address(0);
        tokens[1] = USDC;
        tokens[2] = WBTC;
    }

    function _feedOf(address _token) internal pure returns (address feed) {
        if (_token == USDC) return USDC_USD_PRICE_FEED;
        if (_token == WBTC) return WBTC_USD_PRICE_FEED;
        return NATIVE_TOKEN_USD_PRICE_FEED;
    }

    function _updatedAt(address _feed) internal view returns (uint256 updatedAt) {
        (,,, updatedAt,) = AggregatorV3Interface(_feed).latestRoundData();
    }
}
