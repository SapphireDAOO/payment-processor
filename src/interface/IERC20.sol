// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IERC20
 * @notice Minimal ERC20 interface exposing the `decimals()` function.
 * @dev Used for retrieving the number of decimals a token uses to represent its balances.
 */
interface IERC20 {
    /**
     * @notice Returns the number of decimals used by the token.
     * @return decimalsValue The number of decimals the token uses.
     */
    function decimals() external view returns (uint8 decimalsValue);
}
