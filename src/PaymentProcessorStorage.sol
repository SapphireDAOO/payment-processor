// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentProcessorStorage } from "./interface/IPaymentProcessorStorage.sol";
import { LibCall } from "solady/utils/LibCall.sol";
import { Ownable } from "solady/auth/Ownable.sol";

/**
 * @title PaymentProcessorStorage
 * @notice Stores global state and metadata for invoices, escrow configurations, and contract parameters.
 * @dev Ownable contract that exposes controlled write access to update internal mappings and counters.
 */
contract PaymentProcessorStorage is IPaymentProcessorStorage, Ownable {
    using LibCall for address;

    /**
     * @notice The next available unique invoice ID.
     * @dev Used to track and increment standalone or sub-invoice identifiers.
     */
    uint216 private nextInvoiceId;

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
        if (!isAuthorized[msg.sender]) {
            revert NotAuthorized();
        }
        _;
    }

    /**
     * @notice Initializes the contract with the given configuration.
     * @dev Sets the contract owner, stores the initial configuration parameters, and initializes the invoice ID counter.
     * @param configuration The initial configuration parameters including owner, gas threshold, and hold period.
     */
    constructor(Configuration memory configuration) {
        _initializeOwner(configuration.owner);
        config = configuration;
        nextInvoiceId = 1;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function updateInvoiceId(uint216 by) external onlyAuthorized returns (uint216) {
        nextInvoiceId += by;
        return totalInvoiceCreated();
    }

    /// @inheritdoc IPaymentProcessorStorage
    function execute(address target, bytes calldata data) external onlyOwner returns (bytes memory) {
        return target.callContract(data);
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setFeeReceiver(address feeReceiverAddress) external onlyOwner {
        config.feeReceiver = feeReceiverAddress;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setAuthorizedAddress(address authorizedAddress, bool authorized) external onlyOwner {
        isAuthorized[authorizedAddress] = authorized;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setFeeRate(uint256 newFeeRate) external onlyOwner {
        config.feeRate = newFeeRate;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setGasThresold(uint256 newGasThresold) external onlyOwner {
        config.gasThresold = newGasThresold;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setDefaultHoldPeriod(uint256 newDefaultHoldPeriod) public onlyOwner {
        if (newDefaultHoldPeriod == 0) revert HoldPeriodCanNotBeZero();
        config.defaultHoldPeriod = newDefaultHoldPeriod;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setMarketplaceAddress(address marketplaceAddress) external onlyOwner {
        config.marketplace = marketplaceAddress;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getNextInvoiceId() external view returns (uint216) {
        return nextInvoiceId;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function totalInvoiceCreated() public view returns (uint216) {
        return nextInvoiceId - 1;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getFeeRate() external view returns (uint256) {
        return config.feeRate;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getFeeReceiver() external view returns (address) {
        return config.feeReceiver;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getMarketplace() external view returns (address) {
        return config.marketplace;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getDefaultHoldPeriod() external view returns (uint256) {
        return config.defaultHoldPeriod;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getGasThreshold() external view returns (uint256) {
        return config.gasThresold;
    }
}
