// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal WETH9 stand-in: wraps native currency 1:1 and unwraps on withdraw.
contract MockWeth is ERC20 {
    constructor() ERC20("Mock Wrapped Ether", "mWETH") { }

    /// @notice Wraps the native currency sent with the call.
    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    /// @notice Unwraps `_amount` back to native currency.
    function withdraw(uint256 _amount) external {
        _burn(msg.sender, _amount);
        (bool ok,) = msg.sender.call{ value: _amount }("");
        require(ok, "MockWeth: unwrap failed");
    }

    receive() external payable {
        deposit();
    }
}
