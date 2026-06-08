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
     * @dev Only callable by the payment processor. Uses a low-level call for both ETH and ERC20
     *      transfers and does NOT revert on failure — the return value must be checked by the caller.
     *      For ETH (`_token == address(0)`): sends via `.call{value}("")`; returns `false` if the
     *      recipient reverts or runs out of gas.
     *      For ERC20: calls `transfer(address,uint256)` via low-level call; handles both tokens that
     *      return a bool (ERC20 standard) and tokens that return nothing (e.g., USDT).
     * @param _token The address of the ERC20 token to withdraw, or address(0) for ETH.
     * @param _receiver The address that receives the withdrawn funds.
     * @param _amount The amount of ETH (wei) or tokens to transfer.
     * @return success True if the transfer succeeded, false otherwise.
     */
    function withdraw(address _token, address _receiver, uint256 _amount) external returns (bool success);

    /**
     * @notice Emitted when funds are deposited into the escrow for an invoice.
     * @param invoiceId The unique key of the invoice associated with the deposit.
     * @param value The amount of funds deposited in wei.
     */
    event Deposited(uint216 indexed invoiceId, uint256 indexed value);

    /**
     * @notice Emitted when funds are withdrawn from the escrow to a receiver.
     * @param token The address of the ERC20 token withdrawn, or address(0) for ETH.
     * @param receiver The address that received the withdrawn funds.
     * @param amount The amount of ETH (wei) or tokens transferred.
     */
    event Withdrawn(address token, address receiver, uint256 amount);
}
