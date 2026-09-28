// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IOracleManager } from "./interface/IOracleManager.sol";
import { AggregatorV3Interface } from "./interface/AggregatorV3Interface.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";

/**
 * @title OracleManager
 * @notice Manages Chainlink price feeds and sequencer uptime checks for payment token conversions.
 * @dev Deployed as a standalone contract and referenced by IntermediatedPaymentProcessor via IOracleManager.
 *      Ownership is delegated to `PaymentProcessorStorage.owner()`.
 */
contract OracleManager is IOracleManager {
    using { SafeCastLib.toUint256 } for int256;
    using { FixedPointMathLib.mulDiv } for uint256;

    /// @notice Shared storage contract whose owner controls oracle writes.
    PaymentProcessorStorage public immutable PP_STORAGE;

    /// @notice Chainlink L2 sequencer uptime feed. Returns answer=0 when up, answer=1 when down.
    /// @dev address(0) disables the sequencer check (e.g. on L1 or local testnets).
    address public immutable SEQUENCER_UPTIME_FEED;

    /// @notice Default number of decimals used for internal fixed-point arithmetic (e.g., 1e18 = 1.0)
    uint8 public constant DEFAULT_DECIMAL = 18;

    /// @notice Decimals every Chainlink USD feed used here reports its answer in.
    uint8 public constant FEED_DECIMAL = 8;

    /// @notice Minimum time (in seconds) to wait after the sequencer restarts before trusting price data.
    /// @dev Protects against stale prices that accumulated while the sequencer was offline.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    /**
     * @notice Mapping of payment tokens to their Chainlink price feed aggregator.
     * @dev Used for converting USD prices to the appropriate payment token amounts.
     */
    mapping(address token => PriceFeedConfig config) private priceFeeds;

    /**
     * @notice Restricts writes to the owner of the shared storage contract.
     * @dev Reverts with `NotAuthorized` if `msg.sender != ppStorage.owner()`.
     */
    modifier onlyAuthorized() {
        _isAuthorized();
        _;
    }

    /**
     * @notice Deploys OracleManager and sets the initial sequencer uptime feed.
     * @param _paymentProcessorStorageAddress The shared storage contract whose owner governs oracle updates.
     * @param _sequencerUptimeFeed Address of the Chainlink sequencer uptime feed.
     *        Pass address(0) to disable the sequencer check (e.g. on L1 or local testnets).
     */
    constructor(address _paymentProcessorStorageAddress, address _sequencerUptimeFeed) {
        PP_STORAGE = PaymentProcessorStorage(_paymentProcessorStorageAddress);
        SEQUENCER_UPTIME_FEED = _sequencerUptimeFeed;
    }

    /// @inheritdoc IOracleManager
    function getUsdPerToken(address _paymentToken) external view returns (uint256) {
        PriceFeedConfig memory config = priceFeeds[_paymentToken];
        if (!config.allowed) revert UnsupportedToken();

        _checkSequencer();
        return _usdPerToken(config);
    }

    /// @inheritdoc IOracleManager
    function getValueInCurrency(address _paymentToken, uint256 _amount, address _toAggregator)
        external
        view
        returns (uint256 value)
    {
        PriceFeedConfig memory config = priceFeeds[_paymentToken];
        if (!config.allowed) revert UnsupportedToken();
        if (_toAggregator == address(0)) revert InvalidAggregator();

        _checkSequencer();

        uint8 tokenDecimals = _paymentToken == address(0) ? DEFAULT_DECIMAL : _decimalsOf(_paymentToken);
        uint256 usdValue = _amount.mulDiv(_usdPerToken(config), 10 ** tokenDecimals);

        return usdValue.mulDiv(10 ** FEED_DECIMAL, _latestPrice(_toAggregator));
    }

    /// @inheritdoc IOracleManager
    function getUsdPerTokenBatch(address[] calldata _paymentTokens) external view returns (uint256[] memory prices) {
        _checkSequencer();

        uint256 length = _paymentTokens.length;
        prices = new uint256[](length);
        for (uint256 i; i < length; i++) {
            PriceFeedConfig memory config = priceFeeds[_paymentTokens[i]];
            if (!config.allowed) revert UnsupportedToken();

            prices[i] = _usdPerToken(config);
        }
    }

    /// @inheritdoc IOracleManager
    function isSupportedToken(address _token) external view returns (bool supported) {
        return priceFeeds[_token].allowed;
    }

    /// @inheritdoc IOracleManager
    function setPriceFeed(address _token, PriceFeedConfig memory _config) external onlyAuthorized {
        priceFeeds[_token] = _config;
        emit PriceFeedSet(_token, _config.aggregator, _config.heartbeat);
    }

    /**
     * @notice Reverts unless the L2 sequencer is up and past its post-restart grace period.
     * @dev Skipped when `sequencerUptimeFeed == address(0)` (L1 or local testnets). Shared by
     *      {getUsdPerToken} and {getUsdPerTokenBatch} so a batch call checks it only once.
     */
    function _checkSequencer() internal view {
        if (SEQUENCER_UPTIME_FEED == address(0)) return;

        try AggregatorV3Interface(SEQUENCER_UPTIME_FEED).latestRoundData() returns (
            uint80, int256 seqAnswer, uint256 startedAt, uint256, uint80
        ) {
            if (seqAnswer != 0) revert SequencerDown();
            if (block.timestamp < startedAt + SEQUENCER_GRACE_PERIOD) revert SequencerDown();
        } catch {
            revert SequencerDown();
        }
    }

    /**
     * @notice Reads and validates a price straight from an aggregator address.
     * @dev Used for caller-supplied currency feeds, which carry no registered heartbeat, so only
     *      round completeness and a positive answer can be checked here.
     * @param _aggregator The Chainlink aggregator to read.
     * @return price The latest answer, in the feed's own decimals.
     */
    function _latestPrice(address _aggregator) internal view returns (uint256 price) {
        (uint80 roundId, int256 answer,,, uint80 answeredInRound) = AggregatorV3Interface(_aggregator).latestRoundData();
        if (answeredInRound < roundId) revert StalePrice();
        if (answer <= 0) revert InvalidPrice();

        return answer.toUint256();
    }

    /**
     * @notice Reads a token's decimals, falling back to {DEFAULT_DECIMAL} when it reports none.
     * @param _token The token to query.
     * @return tokenDecimals The token's decimals.
     */
    function _decimalsOf(address _token) internal view returns (uint8 tokenDecimals) {
        (bool ok, bytes memory data) = _token.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && data.length > 0) return abi.decode(data, (uint8));

        return DEFAULT_DECIMAL;
    }

    /**
     * @notice Reads and validates a token's Chainlink price, assuming the sequencer was already checked.
     * @param _config The token's price feed configuration.
     * @return The token's USD price with 8 decimals as returned by the Chainlink aggregator.
     */
    function _usdPerToken(PriceFeedConfig memory _config) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(_config.aggregator).latestRoundData();
        if (answeredInRound < roundId) revert StalePrice();
        if (answer <= 0) revert InvalidPrice();
        if (_config.heartbeat != 0 && block.timestamp > updatedAt + _config.heartbeat) revert StalePriceFeed();

        return answer.toUint256(); // 8 decimals from Chainlink
    }

    /**
     * @notice Ensures the caller matches the shared storage owner.
     * @dev Reverts with `NotAuthorized` if the caller is not the storage owner.
     */
    function _isAuthorized() internal view {
        if (msg.sender != _owner() && msg.sender != address(PP_STORAGE)) {
            revert NotAuthorized();
        }
    }

    /**
     * @notice Returns the owner of the PaymentProcessorStorage contract.
     * @dev This helper reads the owner directly from the linked PaymentProcessorStorage instance.
     * @return ownerAddress The address that currently owns the PaymentProcessorStorage contract.
     */
    function _owner() internal view returns (address ownerAddress) {
        ownerAddress = PaymentProcessorStorage(address(PP_STORAGE)).owner();
    }
}
