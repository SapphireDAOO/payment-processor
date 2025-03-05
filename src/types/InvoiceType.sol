// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Represents the details of an invoice in the contract.
struct Invoice {
    /// @notice The address of the creator of the invoice.
    address creator;
    /// @notice The address of the payer of the invoice.
    address payer;
    /// @notice The address of the escrow contract managing the funds for this invoice.
    address escrow;
    /// @notice The total price of the invoice in wei.
    uint256 price;
    /// @notice The amount that has been paid.
    uint256 amountPaid;
    /// @notice The Unix timestamp when the invoice was created.
    uint32 createdAt;
    /// @notice The Unix timestamp when the payment was completed.
    uint32 paymentTime;
    /// @notice The hold period for the funds in escrow.
    uint32 holdPeriod;
    /// @notice The current status of the invoice.
    uint32 status;
}
