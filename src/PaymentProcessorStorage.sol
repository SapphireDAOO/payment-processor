// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentProcessorStorage } from "./interface/IPaymentProcessorStorage.sol";
import { IAuthorizedAddressProvider } from "./interface/IMasterDeployer.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/**
 * @title PaymentProcessorStorage
 * @notice Stores global state and metadata for invoices, escrow configurations, and contract parameters.
 * @dev Ownable contract that exposes controlled write access to update internal mappings and counters.
 */
contract PaymentProcessorStorage is IPaymentProcessorStorage, Ownable {
    /// @notice Default time window during which a created invoice remains valid for payment.
    uint256 public constant DEFAULT_PAYMENT_VALIDITY_PERIOD = 7 days;

    /// @notice Total basis points used for percentage calculations. 10_000 = 100%.
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice How long an emergency pause holds without owner approval.
    uint256 public constant EMERGENCY_PAUSE_DURATION = 24 hours;

    /**
     * @notice The next available unique invoice nonce.
     * @dev Used to track and increment standalone or sub-invoice nonces.
     */
    uint216 private nextInvoiceNonce;

    /// @notice Window of time (in seconds) after invoice creation during which a buyer can pay.
    uint256 private paymentValidityDuration;

    /**
     * @notice Tracks whether an address is authorized to perform restricted actions.
     *  @dev Maps an address to a boolean indicating its authorization status.
     */
    mapping(address caller => bool state) private isAuthorized;

    /**
     * @notice Stores the configuration settings for the contract (e.g., default hold period, gas threshold).
     *  @dev Struct containing modifiable parameters used throughout the contract.
     */
    Configuration private config;

    /// @notice Address allowed to trigger an emergency pause.
    address private emergencyPauser;

    /// @notice Start of an unresolved emergency pause; 0 when none is pending.
    uint40 private emergencyPausedAt;

    /// @notice Owner-initiated pause, which never expires on its own.
    bool private ownerPaused;

    /**
     * @notice Ensures that only authorized addresses can call the function.
     * @dev Reverts with `NotAuthorized` if `msg.sender` is not authorized.
     */
    modifier onlyAuthorized() {
        _onlyAuthorized();
        _;
    }

    /**
     * @notice Initializes the contract with the given configuration.
     * @dev Sets the contract owner, stores the initial configuration parameters, and initializes the invoice nonce counter.
     *      The addresses to authorize are fetched from the deployer (`msg.sender`) via
     *      {IAuthorizedAddressProvider.authorizedAddresses}, so the deployer must be a contract implementing that
     *      interface. Keeping the list out of the constructor args keeps it out of the CREATE2 init code, making this
     *      contract's address predictable before the authorized processors are deployed. Authorization is fixed here,
     *      at deployment, and cannot be changed afterwards.
     * @param _configuration The initial configuration parameters including owner, gas threshold, and hold period.
     */
    constructor(Configuration memory _configuration) {
        _initializeOwner(_configuration.owner);
        config = _configuration;
        nextInvoiceNonce = 1;
        paymentValidityDuration = DEFAULT_PAYMENT_VALIDITY_PERIOD;

        address[] memory authorized = IAuthorizedAddressProvider(msg.sender).authorizedAddresses();
        for (uint256 i; i < authorized.length; i++) {
            isAuthorized[authorized[i]] = true;
            emit AuthorizationUpdated(authorized[i], true);
        }

        emit ConfigurationInitialized(_configuration);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function updateInvoiceNonce(uint216 _by) external onlyAuthorized returns (uint216 totalInvoices) {
        nextInvoiceNonce += _by;
        return totalInvoiceCreated();
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setFeeReceiver(address _feeReceiverAddress) external onlyOwner {
        config.feeReceiver = _feeReceiverAddress;
        emit FeeReceiverUpdated(_feeReceiverAddress);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setFeeRate(uint96 _newFeeRate) external onlyOwner {
        if (_newFeeRate > BASIS_POINTS) revert InvalidFeeRate();
        config.feeRate = _newFeeRate;
        emit FeeRateUpdated(_newFeeRate);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setGasThreshold(uint96 _newGasThreshold) external onlyOwner {
        config.gasThreshold = _newGasThreshold;
        emit GasThresholdUpdated(_newGasThreshold);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setPaymentValidityDuration(uint256 _newValidityDuration) external onlyOwner {
        paymentValidityDuration = _newValidityDuration;
        emit PaymentValidityDurationUpdated(_newValidityDuration);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setIntermediatedPlatformsOperator(address _intermediatedPlatformsOperatorWallet) external onlyOwner {
        config.intermediatedPlatformsOperator = _intermediatedPlatformsOperatorWallet;
        emit IntermediatedPlatformsOperatorUpdated(_intermediatedPlatformsOperatorWallet);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function pause() external onlyOwner {
        if (isPaused()) revert AlreadyPaused();
        ownerPaused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function unpause() external onlyOwner {
        if (!ownerPaused && emergencyPausedAt == 0) revert NotPaused();
        ownerPaused = false;
        emergencyPausedAt = 0;
        emit Unpaused(msg.sender);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function emergencyPause() external {
        if (msg.sender != emergencyPauser) revert NotAuthorized();

        bool emergencyPaused = _emergencyPauseActive();
        if (ownerPaused || emergencyPaused) revert AlreadyPaused();

        emergencyPausedAt = uint40(block.timestamp);
        emit EmergencyPaused(msg.sender, block.timestamp + EMERGENCY_PAUSE_DURATION);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function approveEmergencyPause() external onlyOwner {
        if (!_emergencyPauseActive()) revert NoActiveEmergencyPause();
        ownerPaused = true;
        emergencyPausedAt = 0;
        emit EmergencyPauseApproved(msg.sender);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setEmergencyPauser(address _emergencyPauser) external onlyOwner {
        emergencyPauser = _emergencyPauser;
        emit EmergencyPauserUpdated(_emergencyPauser);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function isPaused() public view returns (bool pausedState) {
        return ownerPaused || _emergencyPauseActive();
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getEmergencyPauser() external view returns (address emergencyPauserAddress) {
        return emergencyPauser;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getEmergencyPauseExpiry() external view returns (uint256 expiry) {
        uint40 startedAt = emergencyPausedAt;
        return startedAt == 0 ? 0 : startedAt + EMERGENCY_PAUSE_DURATION;
    }

    /// @dev True while a pending emergency pause is still within its window.
    function _emergencyPauseActive() internal view returns (bool active) {
        uint40 startedAt = emergencyPausedAt;
        return startedAt != 0 && block.timestamp < startedAt + EMERGENCY_PAUSE_DURATION;
    }

    /**
     * @notice Ensures the caller is an authorized address.
     * @dev Reverts with NotAuthorized if the caller is not authorized.
     */
    function _onlyAuthorized() internal view {
        if (!isAuthorized[msg.sender]) {
            revert NotAuthorized();
        }
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getPaymentValidityDuration() external view returns (uint256 validDuration) {
        return paymentValidityDuration;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getNextInvoiceNonce() external view returns (uint216 nextInvoiceNonceValue) {
        return nextInvoiceNonce;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function totalInvoiceCreated() public view returns (uint216 totalInvoices) {
        return nextInvoiceNonce - 1;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getFeeRate() external view returns (uint256 feeRate) {
        return config.feeRate;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getFeeReceiver() external view returns (address feeReceiver) {
        return config.feeReceiver;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getIntermediatedPlatformsOperator() external view returns (address intermediatedPlatformsOperator) {
        return config.intermediatedPlatformsOperator;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getGasThreshold() external view returns (uint256 gasThreshold) {
        return config.gasThreshold;
    }
}
