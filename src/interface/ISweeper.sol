// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ISweeper
 * @notice Interface for the contract that collects ERC20 tokens from many holders into one destination.
 */
interface ISweeper {
    /// @notice Thrown when the caller is not the PaymentProcessorStorage owner.
    error NotAuthorized();

    /// @notice Thrown when the source and amount arrays are not the same length.
    error LengthMismatch();

    /// @notice Thrown when a sweep is requested with no source addresses.
    error EmptySweep();

    /// @notice Thrown when the zero address is supplied as the token or the destination.
    error InvalidAddress();

    /**
     * @notice Pulls `_amounts[i]` of `_token` from each `_from[i]` into `_destination`.
     * @dev Callable only by the PaymentProcessorStorage owner, which is what stops anyone else from
     *      redirecting the balances holders approved to this contract. A holder that has not approved
     *      its full amount is skipped rather than reverting the batch, so one stale approval does not
     *      block the rest; a holder short of balance still reverts.
     * @param _token The ERC20 token to sweep.
     * @param _from The holders to pull from.
     * @param _amounts The amount to pull from each holder, index-aligned with `_from`.
     * @param _destination The address to send the collected tokens to.
     * @return total The total amount swept into `_destination`.
     */
    function sweep(address _token, address[] calldata _from, uint256[] calldata _amounts, address _destination)
        external
        returns (uint256 total);

    /**
     * @notice Returns how much of `_token` a sweep can currently pull from `_holder`.
     * @dev The lesser of the holder's balance and the allowance it granted this contract.
     * @param _token The ERC20 token to check.
     * @param _holder The holder to check.
     * @return amount The sweepable amount.
     */
    function sweepable(address _token, address _holder) external view returns (uint256 amount);

    /**
     * @notice Emitted for each holder a sweep pulls tokens from.
     * @param token The ERC20 token swept.
     * @param from The holder the tokens came from.
     * @param destination The address the tokens were sent to.
     * @param amount The amount transferred.
     */
    event Swept(address indexed token, address indexed from, address indexed destination, uint256 amount);
}
