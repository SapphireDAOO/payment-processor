// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IWETH {
    function deposit() external payable;

    function transfer(address _to, uint256 _amount) external returns (bool success);

    function balanceOf(address _account) external view returns (uint256 balance);
}
