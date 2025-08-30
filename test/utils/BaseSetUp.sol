// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentProcessorStorage, PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { Test, console } from "forge-std/Test.sol";

abstract contract BaseSetUp is Test {
    PaymentProcessorStorage ppStorage;

    address internal admin = address(1);
    address internal buyerOne = address(2);
    address internal buyerTwo = address(3);
    address internal sellerOne = address(4);
    address internal sellerTwo = address(5);
    address internal feeReceiver = address(6);

    uint256 constant INITIAL_BALANCE = 100_000 ether;
    uint256 public constant FEE_RATE = 500;

    uint256 constant DEFAULT_HOLD_PERIOD = 1 days;

    function initialize() public virtual returns (address) {
        vm.deal(buyerOne, INITIAL_BALANCE);
        vm.deal(sellerOne, INITIAL_BALANCE);

        vm.deal(buyerTwo, INITIAL_BALANCE);
        vm.deal(sellerTwo, INITIAL_BALANCE);

        IPaymentProcessorStorage.Configuration memory config = IPaymentProcessorStorage.Configuration({
            owner: msg.sender,
            feeReceiver: msg.sender,
            marketplace: msg.sender,
            feeRate: FEE_RATE,
            defaultHoldPeriod: DEFAULT_HOLD_PERIOD
        });

        vm.prank(admin);
        ppStorage = new PaymentProcessorStorage(config);

        return address(ppStorage);
    }
}
