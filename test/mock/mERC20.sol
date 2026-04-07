// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUsdc is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 10_000_000 ether;

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    /// @notice Returns the mock token decimals.
    function decimals() public view virtual override returns (uint8 decimalsValue) {
        return 6;
    }
}

contract MockWbtc is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 10_000_000 ether;

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    /// @notice Returns the mock token decimals.
    function decimals() public view virtual override returns (uint8 decimalsValue) {
        return 8;
    }
}
