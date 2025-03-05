// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IEscrow {
    /// @notice Thrown when an unauthorized address attempts to perform a restricted action.
    error Unauthorized();

    /// @notice Thrown when the provided value is lower than the required minimum.
    error ValueIsTooLow();

    /// @notice Thrown when a fund transfer fails.
    error TransferFailed();

    /**
     * @notice Refunds the balance held in escrow to the payer when invoice is rejected.
     * @dev Only callable by the payment processor contract.
     * @param _payer The address of the payer to whom the funds will be refunded.
     */
    function refundToPayer(address _payer) external;

    /**
     * @notice Withdraws the balance held in escrow to the creator when the invoice is released.
     * @dev Only callable by the payment processor contract.
     * @param _creator The address of the creator to whom the funds will be withdrawn.
     */
    function withdrawToCreator(address _creator) external;

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
    event FundsWithdrawn(
        uint256 indexed invoiceId, address indexed creator, uint256 indexed amount
    );

    /**
     * @notice Emitted when funds are deposited into the escrow for an invoice.
     * @param invoiceId The unique ID of the invoice associated with the deposit.
     * @param value The amount of funds deposited in wei.
     */
    event FundsDeposited(uint256 indexed invoiceId, uint256 indexed value);
}
