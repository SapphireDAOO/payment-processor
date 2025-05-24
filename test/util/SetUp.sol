// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { Test, console } from "forge-std/Test.sol";

abstract contract SetUp is Test {
    PaymentProcessorStorage ppStorage;

    address internal admin = address(1);
    address internal buyerOne = address(2);
    address internal buyerTwo = address(3);
    address internal sellerOne = address(4);
    address internal sellerTwo = address(5);
    address internal feeReceiver = address(6);

    uint256 constant INITIAL_BALANCE = 100_000 ether;
    uint256 public constant FEE = 500;

    function initialize() public virtual {
        vm.deal(buyerOne, INITIAL_BALANCE);
        vm.deal(sellerOne, INITIAL_BALANCE);

        vm.deal(buyerTwo, INITIAL_BALANCE);
        vm.deal(sellerTwo, INITIAL_BALANCE);

        ppStorage = new PaymentProcessorStorage(feeReceiver, FEE);
    }
}
