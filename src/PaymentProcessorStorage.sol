// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentProcessorStorage } from "./interface/IPaymentProcessorStorage.sol";
import { Ownable } from "solady/auth/Ownable.sol";

// what do they have in common
// events
// some state variable
// some set function

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

    constructor(address feeReceiverAddress, uint256 initialFeeRate) {
        feeReceiver = feeReceiverAddress;
        feeRate = initialFeeRate;
        nextInvoiceId = 1;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function updateInvoiceId(uint256 by) external returns (uint256) {
        nextInvoiceId += by;
        return totalInvoiceCreated();
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setFeeReceiver(address feeReceiverAddress) external onlyOwner {
        feeReceiver = feeReceiverAddress;
    }

    /// @inheritdoc IPaymentProcessorStorage
    function setFeeRate(uint256 _feeRate) external onlyOwner {
        feeRate = _feeRate;
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
