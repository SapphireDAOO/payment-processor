// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IOracleManager } from "./interface/IOracleManager.sol";
import { AggregatorV3Interface } from "./interface/AggregatorV3Interface.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";

contract OracleManager is IOracleManager {
    using { SafeCastLib.toUint256 } for int256;

    /// @notice Chainlink L2 sequencer uptime feed. Returns answer=0 when up, answer=1 when down.
    /// @dev Set to address(0) to disable the sequencer check (e.g. on L1 or local testnets).
    address private sequencerUptimeFeed;

    /// @notice Default number of decimals used for internal fixed-point arithmetic (e.g., 1e18 = 1.0)
    uint8 public constant DEFAULT_DECIMAL = 18;

    /// @notice Minimum time (in seconds) to wait after the sequencer restarts before trusting price data.
    /// @dev Protects against stale prices that accumulated while the sequencer was offline.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    /**
     * @notice Mapping of payment tokens to their Chainlink price feed aggregator.
     * @dev Used for converting USD prices to the appropriate payment token amounts.
     */
    mapping(address token => PriceFeedConfig config) private priceFeeds;

    //      * @param _sequencerUptimeFeed Address of the Chainlink sequencer uptime feed. Set to address(0) to disable the check.

    /**
     * @notice Fetches the Chainlink USD price for a payment token and validates feed freshness.
     * @dev Performs three layers of validation before returning the price:
     *      1. Sequencer uptime: if `sequencerUptimeFeed` is set, checks that the L2 sequencer is up
     *         (answer == 0) and that `SEQUENCER_GRACE_PERIOD` has elapsed since it last restarted.
     *         A reverting or unavailable feed also reverts with `SequencerDown`.
     *         Skipped when `sequencerUptimeFeed == address(0)` (L1 or local testnets).
     *      2. Round completeness: reverts with `StalePrice` if `answeredInRound < roundId`.
     *      3. Heartbeat: reverts with `StalePriceFeed` if the update is older than `config.heartbeat`.
     * @param _paymentToken The token address (address(0) for native ETH).
     * @return The token's USD price with 8 decimals as returned by the Chainlink aggregator.
     */
    function getUsdPerToken(address _paymentToken) external view returns (uint256) {
        PriceFeedConfig memory config = priceFeeds[_paymentToken];
        if (config.aggregator == address(0)) revert UnsupportedToken();

        if (sequencerUptimeFeed != address(0)) {
            try AggregatorV3Interface(sequencerUptimeFeed).latestRoundData() returns (
                uint80, int256 seqAnswer, uint256 startedAt, uint256, uint80
            ) {
                if (seqAnswer != 0) revert SequencerDown();
                if (block.timestamp < startedAt + SEQUENCER_GRACE_PERIOD) revert SequencerDown();
            } catch {
                revert SequencerDown();
            }
        }

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(config.aggregator).latestRoundData();
        if (answeredInRound < roundId) revert StalePrice();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp > updatedAt + config.heartbeat) revert StalePriceFeed();

        return answer.toUint256(); // 8 decimals from Chainlink
    }

    function setPriceFeed(address _token, PriceFeedConfig memory _config) external {
        priceFeeds[_token] = _config;
    }

    function setSequencerUptimeFeed(address _sequencerUptimeFeed) external {
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    function getSequencerUptimeFeed() external view returns (address feed) {
        return sequencerUptimeFeed;
    }
}
