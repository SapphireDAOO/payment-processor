// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { IPaymentProcessorStorage } from "./interface/IPaymentProcessorStorage.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/**
 * @title PaymentProcessorStorage
 * @notice Holds the configuration shared by the payment processors: operator, fee signer, fee receiver,
 *         WETH and pause state.
 * @dev Ownable contract; every setter is owner-only, apart from the emergency pause controls.
 */
contract PaymentProcessorStorage is IPaymentProcessorStorage, Ownable {
    /// @notice Default time window during which a created invoice remains valid for payment.
    uint256 public constant DEFAULT_PAYMENT_VALIDITY_PERIOD = 7 days;

    /// @notice Total basis points used for percentage calculations. 10_000 = 100%.
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice How long an emergency pause holds without owner approval.
    uint256 public constant EMERGENCY_PAUSE_DURATION = 24 hours;

    /// @notice Platform fee rate in basis points (BPS). 500 BPS = 5%.
    uint96 public constant FEE_RATE = 500;

    /// @notice Minimum gas that must remain to continue processing automated tasks.
    uint96 public constant GAS_THRESHOLD = 100_000;

    /// @notice Address that receives platform fees. Fixed at construction.
    address public immutable FEE_RECEIVER;

    /// @notice Wrapped native token both processors pay platform fees in.
    address public immutable WETH;

    /// @notice Address authorized to call the privileged IntermediatedPaymentProcessor functions.
    /// @dev Settable so the operating wallet can be replaced without redeploying.
    address private intermediatedPlatformsOperator;

    /// @notice Address allowed to trigger an emergency pause.
    address private emergencyPauser;

    /// @notice Key whose signature authorizes the fee receiver supplied when an invoice is accepted or paid.
    /// @dev Settable so the signing key can be rotated without redeploying.
    address private feeSigner;

    /// @notice Start of an unresolved emergency pause; 0 when none is pending.
    uint40 private emergencyPausedAt;

    /// @notice Owner-initiated pause, which never expires on its own.
    bool private ownerPaused;

    /**
     * @notice Initializes the contract with the given configuration.
     * @dev The init code holds only the configuration, so this contract's CREATE2 address is
     *      predictable before the processors that reference it exist.
     * @param _configuration The initial configuration parameters.
     */
    constructor(Configuration memory _configuration) {
        if (_configuration.weth == address(0)) revert InvalidWeth();

        _initializeOwner(_configuration.owner);
        FEE_RECEIVER = _configuration.feeReceiver;
        WETH = _configuration.weth;
        intermediatedPlatformsOperator = _configuration.intermediatedPlatformsOperator;

        emit ConfigurationInitialized(_configuration);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setIntermediatedPlatformsOperator(address _intermediatedPlatformsOperatorWallet) external onlyOwner {
        intermediatedPlatformsOperator = _intermediatedPlatformsOperatorWallet;
        emit IntermediatedPlatformsOperatorUpdated(_intermediatedPlatformsOperatorWallet);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setFeeSigner(address _feeSigner) external onlyOwner {
        if (_feeSigner == address(0)) revert InvalidFeeSigner();
        feeSigner = _feeSigner;
        emit FeeSignerUpdated(_feeSigner);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function pause() external onlyOwner {
        if (isPaused()) revert AlreadyPaused();
        ownerPaused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function unpause() external {
        bool isOwner = msg.sender == owner();
        if (!isOwner && msg.sender != emergencyPauser) revert Unauthorized();
        if (!ownerPaused && emergencyPausedAt == 0) revert NotPaused();

        // The pauser lifts only its own emergency pause; an owner pause outranks it.
        if (!isOwner && ownerPaused) revert NotAuthorized();

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

    /// @inheritdoc IPaymentProcessorStorage
    function getPauseState() external view returns (bool pausedState, uint256 expiry) {
        uint40 startedAt = emergencyPausedAt;
        pausedState = ownerPaused || _emergencyPauseActive();
        expiry = startedAt == 0 ? 0 : startedAt + EMERGENCY_PAUSE_DURATION;
    }

    /// @dev True while a pending emergency pause is still within its window.
    function _emergencyPauseActive() internal view returns (bool active) {
        uint40 startedAt = emergencyPausedAt;
        return startedAt != 0 && block.timestamp < startedAt + EMERGENCY_PAUSE_DURATION;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getFeeSigner() external view returns (address feeSignerAddress) {
        return feeSigner;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getIntermediatedPlatformsOperator() external view returns (address operator) {
        return intermediatedPlatformsOperator;
    }
}
