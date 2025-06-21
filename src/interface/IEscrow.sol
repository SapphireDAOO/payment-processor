// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IEscrow {
    /// @notice Thrown when an unauthorized address attempts to perform a restricted action.
    error Unauthorized();

    /**
     * @notice Withdraws ETH or ERC20 tokens from the escrow contract to a specified receiver.
     * @dev Only callable by the payment processor. Transfers ETH if `token` is the zero address,
     *      otherwise transfers ERC20 tokens.
     * @param token The address of the token to withdraw (use address(0) for ETH).
     * @param receiver The address to receive the withdrawn funds.
     * @param amount The amount of ETH or tokens to transfer.
     */
    function withdraw(address token, address receiver, uint256 amount) external;

    /**
     * @notice Emitted when funds are refunded to the payer.
     * @param invoiceId The ID of the invoice associated with the refund.
     * @param payer The address of the payer receiving the refund.
     * @param amount The amount refunded in wei.
     */
    event FundsRefunded(uint256 indexed invoiceId, address indexed payer, uint256 indexed amount);

    /**
     * @notice Emitted when funds are withdrawn by the creator.
     * @param invoiceId The ID of the invoice associated with the withdrawal
     * @param creator The address of the creator receiving the withdrawn funds.
     * @param amount The amount withdrawn in wei.
     */
    event FundsWithdrawn(uint256 indexed invoiceId, address indexed creator, uint256 indexed amount);

    /**
     * @notice Emitted when funds are deposited into the escrow for an invoice.
     * @param orderId The unique key of the invoice associated with the deposit.
     * @param value The amount of funds deposited in wei.
     */
    event FundsDeposited(bytes32 indexed orderId, uint256 indexed value);

    /**
     * @notice Emitted when a fee is successfully paid to a payment processor.
     * @param invoiceId The unique ID of the invoice associated with the fee.
     * @param amount The fee amount paid (in wei).
     */
    event FeePaid(uint256 indexed invoiceId, uint256 amount);
}
