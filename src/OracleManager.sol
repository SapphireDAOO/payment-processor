// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IOracleManager } from "./interface/IOracleManager.sol";
import { AggregatorV3Interface } from "./interface/AggregatorV3Interface.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";

/**
 * @title OracleManager
 * @notice Manages Chainlink price feeds and sequencer uptime checks for payment token conversions.
 * @dev Deployed as a standalone contract and referenced by AdvancedPaymentProcessor via IOracleManager.
 *      Ownership is delegated to `PaymentProcessorStorage.owner()`.
 */
contract OracleManager is IOracleManager {
    using { SafeCastLib.toUint256 } for int256;

    /// @notice Shared storage contract whose owner controls oracle writes.
    PaymentProcessorStorage public immutable ppStorage;

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
        ppStorage = PaymentProcessorStorage(_paymentProcessorStorageAddress);
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    /// @inheritdoc IOracleManager
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

    /// @inheritdoc IOracleManager
    function setPriceFeed(address _token, PriceFeedConfig memory _config) external onlyAuthorized {
        priceFeeds[_token] = _config;
    }

    /// @inheritdoc IOracleManager
    function setSequencerUptimeFeed(address _sequencerUptimeFeed) external onlyAuthorized {
        sequencerUptimeFeed = _sequencerUptimeFeed;
    }

    /// @inheritdoc IOracleManager
    function getSequencerUptimeFeed() external view returns (address feed) {
        return sequencerUptimeFeed;
    }

    /**
     * @notice Ensures the caller matches the shared storage owner.
     * @dev Reverts with `NotAuthorized` if the caller is not the storage owner.
     */
    function _isAuthorized() internal view {
        if (msg.sender != _owner() && msg.sender != address(ppStorage)) {
            revert NotAuthorized();
        }
    }

    /**
     * @notice Returns the owner of the PaymentProcessorStorage contract.
     * @dev This helper reads the owner directly from the linked PaymentProcessorStorage instance.
     * @return ownerAddress The address that currently owns the PaymentProcessorStorage contract.
     */
    function _owner() internal view returns (address ownerAddress) {
        ownerAddress = PaymentProcessorStorage(address(ppStorage)).owner();
    }
}
