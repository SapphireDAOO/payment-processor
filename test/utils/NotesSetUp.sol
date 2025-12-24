// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseSetUp } from "./BaseSetUp.sol";

contract NotesSetUp is BaseSetUp {
    function setUp() public {
        initialize();
        notes.setAuthorized(address(this), true);
    }
}
