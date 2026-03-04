// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title Chainlink Aggregator V3 Interface
 *  @notice Interface for fetching the latest price data from a Chainlink price feed.
 *  @dev This is a minimal version focusing on `latestRoundData`.
 *  @custom:source https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol
 */
interface AggregatorV3Interface {
    /**
     * @notice Returns data for the latest round of the aggregator.
     * @return roundId The unique identifier for the round.
     * @return answer The latest price value reported by the aggregator (8 decimals).
     * @return startedAt The timestamp when the round started.
     * @return updatedAt The timestamp when the answer was last updated.
     * @return answeredInRound The round ID in which the answer was computed.
     */
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
