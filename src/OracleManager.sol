// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

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
     * @notice Restricts writes to the storage owner or the storage contract itself.
     * @dev Reverts with `NotAuthorized` otherwise.
     */
    modifier onlyAuthorized() {
        _isAuthorized();
        _;
    }

    /**
     * @notice Deploys OracleManager with a fixed sequencer uptime feed.
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
        (uint256 price,) = _usdPerToken(config);
        return price;
    }

    /// @inheritdoc IOracleManager
    function getValueInCurrency(address _paymentToken, uint256 _amount, address _toAggregator)
        external
        view
        returns (uint256 value, uint256 validUntil)
    {
        PriceFeedConfig memory config = priceFeeds[_paymentToken];
        if (!config.allowed) revert UnsupportedToken();
        if (_toAggregator == address(0)) revert InvalidAggregator();

        _checkSequencer();

        uint8 tokenDecimals = _paymentToken == address(0) ? DEFAULT_DECIMAL : _decimalsOf(_paymentToken);
        (uint256 usdPerToken, uint256 tokenPriceValidUntil) = _usdPerToken(config);
        uint256 usdValue = _amount.mulDiv(usdPerToken, 10 ** tokenDecimals);

        value = usdValue.mulDiv(10 ** FEED_DECIMAL, _latestPrice(_toAggregator));
        validUntil = tokenPriceValidUntil;
    }

    /// @inheritdoc IOracleManager
    function getUsdPerTokenBatch(address[] calldata _paymentTokens)
        external
        view
        returns (uint256[] memory prices, uint256[] memory validUntil)
    {
        _checkSequencer();

        uint256 length = _paymentTokens.length;
        prices = new uint256[](length);
        validUntil = new uint256[](length);
        for (uint256 i; i < length; i++) {
            PriceFeedConfig memory config = priceFeeds[_paymentTokens[i]];
            if (!config.allowed) revert UnsupportedToken();

            (prices[i], validUntil[i]) = _usdPerToken(config);
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
     * @dev Skipped when `SEQUENCER_UPTIME_FEED == address(0)` (L1 or local testnets). Shared by every
     *      price read, so a batch call checks it only once.
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
     * @return price The token's USD price with 8 decimals as returned by the Chainlink aggregator.
     * @return validUntil `updatedAt + heartbeat`; `type(uint256).max` with no heartbeat.
     */
    function _usdPerToken(PriceFeedConfig memory _config) internal view returns (uint256 price, uint256 validUntil) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(_config.aggregator).latestRoundData();
        if (answeredInRound < roundId) revert StalePrice();
        if (answer <= 0) revert InvalidPrice();

        if (_config.heartbeat == 0) {
            validUntil = type(uint256).max;
        } else {
            validUntil = updatedAt + _config.heartbeat;
            if (block.timestamp > validUntil) revert StalePriceFeed();
        }

        price = answer.toUint256(); // 8 decimals from Chainlink
    }

    /**
     * @notice Ensures the caller is the storage owner or the storage contract itself.
     * @dev Reverts with `NotAuthorized` otherwise.
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
