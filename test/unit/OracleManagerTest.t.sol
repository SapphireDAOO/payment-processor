// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { OracleManager } from "../../src/OracleManager.sol";
import { IOracleManager } from "../../src/interface/IOracleManager.sol";
import { MockV3Aggregator } from "../mock/MockV3Aggregator.sol";
import { BaseSetUp } from "../utils/BaseSetUp.sol";

contract OracleManagerTest is BaseSetUp {
    OracleManager oracle;
    MockV3Aggregator priceFeed;
    MockV3Aggregator seqFeed;

    address constant TOKEN = address(0xdead);
    address constant TOKEN_TWO = address(0xdead2);
    uint96 constant HEARTBEAT = 24 hours;
    int256 constant INITIAL_PRICE = 2000e8; // $2,000 in 8-decimal Chainlink format
    int256 constant INITIAL_PRICE_TWO = 1e8;

    MockV3Aggregator priceFeedTwo;

    function setUp() public {
        initialize();

        // Create feeds before warp so startedAt = 0 (passes grace period check after warp)
        seqFeed = new MockV3Aggregator(8, 0); // answer=0 means sequencer is up
        priceFeed = new MockV3Aggregator(8, INITIAL_PRICE);

        // Warp past the 1-hour sequencer grace period
        vm.warp(2 hours);

        oracle = new OracleManager(address(ppStorage), address(seqFeed));

        vm.prank(admin);
        oracle.setPriceFeed(
            TOKEN,
            IOracleManager.PriceFeedConfig({ aggregator: address(priceFeed), heartbeat: HEARTBEAT, allowed: true })
        );

        priceFeedTwo = new MockV3Aggregator(8, INITIAL_PRICE_TWO);
        vm.prank(admin);
        oracle.setPriceFeed(
            TOKEN_TWO,
            IOracleManager.PriceFeedConfig({ aggregator: address(priceFeedTwo), heartbeat: HEARTBEAT, allowed: true })
        );
    }

    // ── Constructor ──────────────────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(address(oracle.PP_STORAGE()), address(ppStorage));
        assertEq(oracle.SEQUENCER_UPTIME_FEED(), address(seqFeed));
    }

    // ── setPriceFeed ─────────────────────────────────────────────────────────────

    function test_setPriceFeed_revertsForNonOwner() public {
        vm.expectRevert(IOracleManager.NotAuthorized.selector);
        oracle.setPriceFeed(
            TOKEN,
            IOracleManager.PriceFeedConfig({ aggregator: address(priceFeed), heartbeat: HEARTBEAT, allowed: true })
        );
    }

    function test_setPriceFeed_owner() public {
        MockV3Aggregator newFeed = new MockV3Aggregator(8, 3000e8);
        vm.prank(admin);
        oracle.setPriceFeed(
            TOKEN, IOracleManager.PriceFeedConfig({ aggregator: address(newFeed), heartbeat: HEARTBEAT, allowed: true })
        );

        assertEq(oracle.getUsdPerToken(TOKEN), 3000e8);
    }

    function test_setPriceFeed_ppStorageAddressIsAuthorized() public {
        MockV3Aggregator newFeed = new MockV3Aggregator(8, 5000e8);
        vm.prank(address(ppStorage));
        oracle.setPriceFeed(
            TOKEN, IOracleManager.PriceFeedConfig({ aggregator: address(newFeed), heartbeat: HEARTBEAT, allowed: true })
        );

        assertEq(oracle.getUsdPerToken(TOKEN), 5000e8);
    }

    function test_setPriceFeed_removeToken() public {
        // Clearing `allowed` disables the token; the aggregator can stay in place for a later re-enable.
        vm.prank(admin);
        oracle.setPriceFeed(
            TOKEN,
            IOracleManager.PriceFeedConfig({ aggregator: address(priceFeed), heartbeat: HEARTBEAT, allowed: false })
        );

        assertFalse(oracle.isSupportedToken(TOKEN));

        vm.expectRevert(IOracleManager.UnsupportedToken.selector);
        oracle.getUsdPerToken(TOKEN);

        vm.prank(admin);
        oracle.setPriceFeed(
            TOKEN,
            IOracleManager.PriceFeedConfig({ aggregator: address(priceFeed), heartbeat: HEARTBEAT, allowed: true })
        );

        assertTrue(oracle.isSupportedToken(TOKEN));
        assertEq(oracle.getUsdPerToken(TOKEN), uint256(INITIAL_PRICE));
    }

    // ── sequencer uptime feed ─────────────────────────────────────────────────────

    function test_sequencerUptimeFeedIsFixedAtConstruction() public view {
        assertEq(oracle.SEQUENCER_UPTIME_FEED(), address(seqFeed));
    }

    function test_zeroSequencerFeedDisablesTheCheck() public {
        OracleManager noSeqOracle = new OracleManager(address(ppStorage), address(0));
        vm.prank(admin);
        noSeqOracle.setPriceFeed(
            TOKEN,
            IOracleManager.PriceFeedConfig({ aggregator: address(priceFeed), heartbeat: HEARTBEAT, allowed: true })
        );

        assertEq(noSeqOracle.SEQUENCER_UPTIME_FEED(), address(0));
        assertEq(noSeqOracle.getUsdPerToken(TOKEN), uint256(INITIAL_PRICE));
    }

    // ── getUsdPerToken — sequencer validation ─────────────────────────────────────

    function test_getUsdPerToken_sequencerDown() public {
        seqFeed.updateAnswer(1); // answer=1 means sequencer is down

        vm.expectRevert(IOracleManager.SequencerDown.selector);
        oracle.getUsdPerToken(TOKEN);
    }

    function test_getUsdPerToken_sequencerInGracePeriod() public {
        // startedAt == block.timestamp → still within 1-hour grace period
        vm.mockCall(
            address(seqFeed),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(0), block.timestamp, block.timestamp, uint80(1))
        );

        vm.expectRevert(IOracleManager.SequencerDown.selector);
        oracle.getUsdPerToken(TOKEN);
    }

    function test_getUsdPerToken_sequencerFeedReverts() public {
        vm.mockCallRevert(address(seqFeed), abi.encodeWithSignature("latestRoundData()"), "");

        vm.expectRevert(IOracleManager.SequencerDown.selector);
        oracle.getUsdPerToken(TOKEN);
    }

    // ── getUsdPerToken — price feed validation ────────────────────────────────────

    function test_getUsdPerToken_unsupportedToken() public {
        vm.expectRevert(IOracleManager.UnsupportedToken.selector);
        oracle.getUsdPerToken(address(0xdeadbeef));
    }

    function test_getUsdPerToken_staleRound() public {
        // answeredInRound(4) < roundId(5) → stale
        vm.mockCall(
            address(priceFeed),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(5), INITIAL_PRICE, block.timestamp, block.timestamp, uint80(4))
        );

        vm.expectRevert(IOracleManager.StalePrice.selector);
        oracle.getUsdPerToken(TOKEN);
    }

    function test_getUsdPerToken_invalidPrice_zero() public {
        priceFeed.updateAnswer(0);

        vm.expectRevert(IOracleManager.InvalidPrice.selector);
        oracle.getUsdPerToken(TOKEN);
    }

    function test_getUsdPerToken_invalidPrice_negative() public {
        priceFeed.updateAnswer(-1);

        vm.expectRevert(IOracleManager.InvalidPrice.selector);
        oracle.getUsdPerToken(TOKEN);
    }

    function test_getUsdPerToken_stalePriceFeed() public {
        // MockV3Aggregator hardcodes updatedAt = 500 days; heartbeat = 24 hours
        // Need block.timestamp > 500 days + 24 hours = 501 days
        vm.warp(501 days + 1);

        vm.expectRevert(IOracleManager.StalePriceFeed.selector);
        oracle.getUsdPerToken(TOKEN);
    }

    // ── getUsdPerToken — happy path ───────────────────────────────────────────────

    function test_getUsdPerToken_returnsCorrectPrice() public view {
        assertEq(oracle.getUsdPerToken(TOKEN), uint256(INITIAL_PRICE));
    }

    function test_getUsdPerToken_noSequencerFeedConfigured() public {
        OracleManager noSeqOracle = new OracleManager(address(ppStorage), address(0));
        vm.prank(admin);
        noSeqOracle.setPriceFeed(
            TOKEN,
            IOracleManager.PriceFeedConfig({ aggregator: address(priceFeed), heartbeat: HEARTBEAT, allowed: true })
        );

        assertEq(noSeqOracle.getUsdPerToken(TOKEN), uint256(INITIAL_PRICE));
    }

    // ── getUsdPerTokenBatch ────────────────────────────────────────────────────────

    function test_getUsdPerTokenBatch_returnsCorrectPrices() public view {
        address[] memory tokens = new address[](2);
        tokens[0] = TOKEN;
        tokens[1] = TOKEN_TWO;

        uint256[] memory prices = oracle.getUsdPerTokenBatch(tokens);

        assertEq(prices.length, 2);
        assertEq(prices[0], uint256(INITIAL_PRICE));
        assertEq(prices[1], uint256(INITIAL_PRICE_TWO));
    }

    function test_getUsdPerTokenBatch_empty() public view {
        assertEq(oracle.getUsdPerTokenBatch(new address[](0)).length, 0);
    }

    function test_getUsdPerTokenBatch_revertsOnUnsupportedToken() public {
        address[] memory tokens = new address[](2);
        tokens[0] = TOKEN;
        tokens[1] = address(0xdeadbeef);

        vm.expectRevert(IOracleManager.UnsupportedToken.selector);
        oracle.getUsdPerTokenBatch(tokens);
    }

    function test_getUsdPerTokenBatch_revertsWhenSequencerDown() public {
        seqFeed.updateAnswer(1); // answer=1 means sequencer is down

        address[] memory tokens = new address[](2);
        tokens[0] = TOKEN;
        tokens[1] = TOKEN_TWO;

        vm.expectRevert(IOracleManager.SequencerDown.selector);
        oracle.getUsdPerTokenBatch(tokens);
    }

    function test_getUsdPerTokenBatch_revertsOnStalePriceFeed() public {
        // MockV3Aggregator hardcodes updatedAt = 500 days; heartbeat = 24 hours
        vm.warp(501 days + 1);

        address[] memory tokens = new address[](2);
        tokens[0] = TOKEN;
        tokens[1] = TOKEN_TWO;

        vm.expectRevert(IOracleManager.StalePriceFeed.selector);
        oracle.getUsdPerTokenBatch(tokens);
    }
}
