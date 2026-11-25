// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

contract NoReceiveEther {
    receive() external payable {
        revert();
    }

    constructor() payable { }
}
