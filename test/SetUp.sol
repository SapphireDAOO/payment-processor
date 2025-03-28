// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { IPaymentProcessorV1, PaymentProcessorV1 } from "../src/PaymentProcessorV1.sol";

abstract contract SetUp is Test {
    PaymentProcessorV1 pp;

    address owner;
    address feeReceiver;

    address creatorOne;
    address creatorTwo;
    address payerOne;
    address payerTwo;

    uint256 constant DEFAULT_HOLD_PERIOD = 1 days;
    uint256 constant PAYER_ONE_INITIAL_BALANCE = 10_000 ether;
    uint256 constant FEE_RATE = 700;
    uint256 constant PAYER_TWO_INITIAL_BALANCE = 5_000 ether;

    function setUp() public {
        owner = makeAddr("owner");
        feeReceiver = makeAddr("feeReceiver");
        creatorOne = makeAddr("creatorOne");
        creatorTwo = makeAddr("creatorTwo");
        payerOne = makeAddr("payerOne");
        payerTwo = makeAddr("payerTwo");

        vm.deal(payerOne, PAYER_ONE_INITIAL_BALANCE);
        vm.deal(payerTwo, PAYER_TWO_INITIAL_BALANCE);

        vm.prank(owner);
        pp = new PaymentProcessorV1(feeReceiver, FEE_RATE, DEFAULT_HOLD_PERIOD);
        vm.stopPrank();
    }
}
