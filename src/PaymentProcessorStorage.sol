// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentProcessorStorage } from "./interface/IPaymentProcessorStorage.sol";
import { Ownable } from "solady/auth/Ownable.sol";

contract PaymentProcessorStorage is IPaymentProcessorStorage, Ownable {
    /**
     * @notice The next available unique invoice ID.
     * @dev Used to track and increment standalone or sub-invoice identifiers.
     */
    uint256 private nextInvoiceId;

    /**
     * @notice Platform fee rate in basis points (BPS).
     * @dev 100 BPS = 1%; 10,000 BPS = 100%.
     */
    uint256 private feeRate;

    /**
     * @notice Address that receives platform fees upon seller payout.
     */
    address private feeReceiver;

    /**
     * @notice Tracks whether an address is authorized to perform restricted actions.
     *  @dev Maps an address to a boolean indicating its authorization status.
     */
    mapping(address => bool) private isAuthorized;

    /**
     * @notice Ensures that only authorized addresses can call the function.
     * @dev Reverts with `NotAuthorized` if `msg.sender` is not authorized.
     */
    modifier onlyAuthorized() {
        if (!isAuthorized[msg.sender]) revert NotAuthorized();
        _;
    }

    /**
     *  @notice Initializes the contract with the owner, fee receiver, and initial fee rate.
     * @param ownerAddress The address to be set as the contract owner.
     *  @param feeReceiverAddress The address that will receive platform fees.
     *  @param initialFeeRate The initial fee rate in basis points (e.g., 100 = 1%).
     */
    constructor(address ownerAddress, address feeReceiverAddress, uint256 initialFeeRate) {
        _initializeOwner(ownerAddress);
        feeReceiver = feeReceiverAddress;
        feeRate = initialFeeRate;
        nextInvoiceId = 1;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function updateInvoiceId(uint256 by) external onlyAuthorized returns (uint256) {
        nextInvoiceId += by;
        return totalInvoiceCreated();
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setFeeReceiver(address feeReceiverAddress) external onlyOwner {
        feeReceiver = feeReceiverAddress;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setAuthorizedAddress(address authorizedAddress, bool authorized) external onlyOwner {
        isAuthorized[authorizedAddress] = authorized;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setFeeRate(uint256 newFeeRate) external onlyOwner {
        feeRate = newFeeRate;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getNextInvoiceId() external view returns (uint256) {
        return nextInvoiceId;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function totalInvoiceCreated() public view returns (uint256) {
        return nextInvoiceId - 1;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getFeeRate() external view returns (uint256) {
        return feeRate;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function getFeeReceiver() external view returns (address) {
        return feeReceiver;
    }
}
