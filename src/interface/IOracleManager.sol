// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IOracleManager {
    /// @notice Thrown when a payment is attempted with a token that is not supported by the processor.
    error UnsupportedToken();

    /// @notice Thrown when the Chainlink round is incomplete (answeredInRound < roundId).
    error StalePrice();

    /// @notice Thrown when the L2 sequencer is down or still within the post-restart grace period.
    error SequencerDown();

    /// @notice Thrown when a Chainlink price feed is stale and cannot be trusted for conversion.
    error StalePriceFeed();

    /// @notice Thrown when the Chainlink price feed returns a zero or negative answer.
    error InvalidPrice();

    /// @notice Configuration for a Chainlink price feed associated with a payment token.
    /// @param aggregator Address of the Chainlink AggregatorV3 contract. address(0) disables the token.
    /// @param heartbeat Maximum acceptable age (in seconds) of a price update before it is considered stale.
    ///        Should match the feed's documented update interval (e.g. 3600 for a 1-hour feed).
    struct PriceFeedConfig {
        address aggregator;
        uint96 heartbeat;
    }

    function getUsdPerToken(address _paymentToken) external view returns (uint256);

    /**
     * @notice Sets the Chainlink price feed configuration for a specific payment token.
     * @dev Callable only by the owner. Use address(0) for `_token` to set the native currency feed.
     *      Setting `_config.aggregator` to address(0) removes the token from accepted payment methods.
     * @param _token The payment token address, or address(0) for native currency.
     * @param _config The price feed configuration containing the aggregator address and heartbeat interval.
     */
    function setPriceFeed(address _token, PriceFeedConfig memory _config) external;

    /**
     * @notice Sets the Chainlink L2 sequencer uptime feed address.
     * @dev Callable only by the owner. Set to address(0) to disable the sequencer check
     *      (e.g. on L1 deployments or local testnets where no uptime feed exists).
     * @param _sequencerUptimeFeed The sequencer uptime feed address, or address(0) to disable.
     */
    function setSequencerUptimeFeed(address _sequencerUptimeFeed) external;

    /**
     * @notice Returns the configured sequencer uptime feed address.
     * @return feed The sequencer uptime feed address, or address(0) if the check is disabled.
     */
    function getSequencerUptimeFeed() external view returns (address feed);
}
