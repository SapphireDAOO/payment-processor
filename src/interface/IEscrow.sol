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
     * @notice Emitted when funds are refunded to the payer.
     * @param _invoiceId The ID of the invoice associated with the refund.
     * @param _payer The address of the payer receiving the refund.
     * @param _amount The amount refunded in wei.
     */
    event FundsRefunded(uint216 indexed _invoiceId, address indexed _payer, uint256 indexed _amount);

    /**
     * @notice Emitted when funds are withdrawn by the creator.
     * @param _invoiceId The ID of the invoice associated with the withdrawal
     * @param _creator The address of the creator receiving the withdrawn funds.
     * @param _amount The amount withdrawn in wei.
     */
    event FundsWithdrawn(uint216 indexed _invoiceId, address indexed _creator, uint256 indexed _amount);

    /**
     * @notice Emitted when funds are deposited into the escrow for an invoice.
     * @param _invoiceId The unique key of the invoice associated with the deposit.
     * @param _value The amount of funds deposited in wei.
     */
    event FundsDeposited(uint216 indexed _invoiceId, uint256 indexed _value);

    /**
     * @notice Emitted when a fee is successfully paid to a payment processor.
     * @param _invoiceId The unique ID of the invoice associated with the fee.
     * @param _amount The fee amount paid (in wei).
     */
    event FeePaid(uint216 indexed _invoiceId, uint256 _amount);
}
