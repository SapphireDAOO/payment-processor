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

    /// @notice Platform fee rate in basis points (BPS). 500 BPS = 5%.
    uint96 public constant FEE_RATE = 500;

    /// @notice Minimum gas that must remain to continue processing automated tasks.
    uint96 public constant GAS_THRESHOLD = 100_000;

    /**
     * @notice The next available unique invoice nonce.
     * @dev Used to track and increment standalone or sub-invoice nonces.
     */
    uint216 private nextInvoiceNonce;

    /**
     * @notice Tracks whether an address is authorized to perform restricted actions.
     *  @dev Maps an address to a boolean indicating its authorization status.
     */
    mapping(address caller => bool state) private isAuthorized;

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
     * @notice Ensures that only authorized addresses can call the function.
     * @dev Reverts with `NotAuthorized` if `msg.sender` is not authorized.
     */
    modifier onlyAuthorized() {
        _onlyAuthorized();
        _;
    }

    /**
     * @notice Initializes the contract with the given configuration.
     * @dev The addresses to authorize are fetched from the deployer via
     *      {IAuthorizedAddressProvider.authorizedAddresses} rather than passed in, which keeps them out
     *      of the CREATE2 init code so this contract's address is predictable before the processors
     *      exist. Authorization is fixed here and cannot be changed afterwards.
     * @param _configuration The initial configuration parameters.
     */
    constructor(Configuration memory _configuration) {
        if (_configuration.weth == address(0)) revert InvalidWeth();

        _initializeOwner(_configuration.owner);
        FEE_RECEIVER = _configuration.feeReceiver;
        WETH = _configuration.weth;
        intermediatedPlatformsOperator = _configuration.intermediatedPlatformsOperator;
        nextInvoiceNonce = 1;

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
    function getFeeSigner() external view returns (address feeSignerAddress) {
        return feeSigner;
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
