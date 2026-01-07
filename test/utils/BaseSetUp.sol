// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Notes } from "src/Notes.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { Test } from "forge-std/Test.sol";

abstract contract BaseSetUp is Test {
    PaymentProcessorStorage ppStorage;
    Notes notes;

    address internal admin = address(1);
    address internal buyerOne = address(2);
    address internal buyerTwo = address(3);
    address internal sellerOne = address(4);
    address internal sellerTwo = address(5);
    address internal feeReceiver = address(6);

    uint256 constant INITIAL_BALANCE = 100_000 ether;
    uint256 public constant FEE_RATE = 500;

    uint256 constant DEFAULT_HOLD_PERIOD = 1 days;
    uint256 constant DEFAULT_GAS_THRESOLD = 100_000;

    function initialize() public virtual returns (address, address) {
        vm.deal(buyerOne, INITIAL_BALANCE);
        vm.deal(sellerOne, INITIAL_BALANCE);

        vm.deal(buyerTwo, INITIAL_BALANCE);
        vm.deal(sellerTwo, INITIAL_BALANCE);

        IPaymentProcessorStorage.Configuration memory config = IPaymentProcessorStorage.Configuration({
            owner: admin,
            feeReceiver: feeReceiver,
            marketplace: address(this),
            feeRate: FEE_RATE,
            defaultHoldPeriod: DEFAULT_HOLD_PERIOD,
            gasThresold: DEFAULT_GAS_THRESOLD
        });

        vm.prank(admin);
        ppStorage = new PaymentProcessorStorage(config);
        notes = new Notes(address(ppStorage));

        return (address(ppStorage), address(notes));
    }
}
