// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentProcessorStorage } from "./interface/IPaymentProcessorStorage.sol";
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

    /**
     * @notice The next available unique invoice nonce.
     * @dev Used to track and increment standalone or sub-invoice nonces.
     */
    uint216 private nextInvoiceNonce;

    /// @notice Duration (in seconds) for which a payment remains valid.
    uint256 private paymentValidityDuration;

    /**
     * @notice Tracks whether an address is authorized to perform restricted actions.
     *  @dev Maps an address to a boolean indicating its authorization status.
     */
    mapping(address => bool) private isAuthorized;

    /**
     * @notice Stores the configuration settings for the contract (e.g., default hold period, gas threshold).
     *  @dev Struct containing modifiable parameters used throughout the contract.
     */
    Configuration private config;

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
     * @param _configuration The initial configuration parameters including owner, gas threshold, and hold period.
     */
    constructor(Configuration memory _configuration) {
        _initializeOwner(_configuration.owner);
        config = _configuration;
        nextInvoiceNonce = 1;
        paymentValidityDuration = DEFAULT_PAYMENT_VALIDITY_PERIOD;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function updateInvoiceNonce(uint216 _by) external onlyAuthorized returns (uint216 totalInvoices) {
        nextInvoiceNonce += _by;
        return totalInvoiceCreated();
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setFeeReceiver(address _feeReceiverAddress) external onlyOwner {
        config.feeReceiver = _feeReceiverAddress;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setAuthorizedAddress(address _authorizedAddress, bool _authorized) external onlyOwner {
        isAuthorized[_authorizedAddress] = _authorized;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setFeeRate(uint256 _newFeeRate) external onlyOwner {
        if (_newFeeRate > BASIS_POINTS) revert InvalidFeeRate();
        config.feeRate = _newFeeRate;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setGasThreshold(uint256 _newGasThreshold) external onlyOwner {
        config.gasThreshold = _newGasThreshold;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setPaymentValidityDuration(uint256 _newValidityDuration) external onlyOwner {
        paymentValidityDuration = _newValidityDuration;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setDefaultHoldPeriod(uint256 _newDefaultHoldPeriod) public onlyOwner {
        if (_newDefaultHoldPeriod == 0) revert HoldPeriodCanNotBeZero();
        config.defaultHoldPeriod = _newDefaultHoldPeriod;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setMarketplaceAddress(address _marketplaceAddress) external onlyOwner {
        config.marketplace = _marketplaceAddress;
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
    function getMarketplace() external view returns (address marketplace) {
        return config.marketplace;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getDefaultHoldPeriod() external view returns (uint256 defaultHoldPeriod) {
        return config.defaultHoldPeriod;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getGasThreshold() external view returns (uint256 gasThreshold) {
        return config.gasThreshold;
    }
}
