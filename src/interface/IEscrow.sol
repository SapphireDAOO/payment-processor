// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IEscrow
 * @notice Interface for escrow contracts managing invoice payments.
 * @dev Defines the required functions for interacting with escrow logic
 */
interface IEscrow {
    /// @notice Thrown when an unauthorized address attempts to perform a restricted action.
    error Unauthorized();

    /**
     * @notice Withdraws ETH or ERC20 tokens from the escrow contract to a specified receiver.
     * @dev Only callable by the payment processor. Transfers ETH if `token` is the zero address,
     * otherwise transfers ERC20 tokens.
     * @param _token The address of the token to withdraw (use address(0) for ETH).
     * @param _receiver The address that receives the withdrawn funds.
     * @param _amount The amount of ETH or tokens to transfer.
     */
    function withdraw(address _token, address _receiver, uint256 _amount) external;

    /**
     * @notice Emitted when funds are deposited into the escrow for an invoice.
     * @param invoiceId The unique key of the invoice associated with the deposit.
     * @param value The amount of funds deposited in wei.
     */
    event FundsDeposited(uint216 indexed invoiceId, uint256 indexed value);
}
