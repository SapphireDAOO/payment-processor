// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test, console } from "forge-std/Test.sol";
import { Invoice } from "../../src/Types/InvoiceType.sol";
import { PaymentProcessorV1 } from "../../src/PaymentProcessorV1.sol";
import {
    CREATED,
    ACCEPTED,
    REJECTED,
    PAID,
    CANCELLED,
    VALID_PERIOD
} from "../../src/utils/Constants.sol";

import { Handler } from "./Handler.t.sol";

contract Invariant is StdInvariant, Test {
    PaymentProcessorV1 pp;
    Handler handler;

    address owner;
    address feeReceiver;

    address creator;
    address payer;

    uint256 constant FEE = 1 ether;
    uint256 constant DEFAULT_HOLD_PERIOD = 1 days;
    uint256 constant PAYER_ONE_INITIAL_BALANCE = 10_000 ether;

    function setUp() public {
        owner = makeAddr("owner");
        feeReceiver = makeAddr("feeReceiver");
        creator = makeAddr("creator");
        payer = makeAddr("payer");
        pp = new PaymentProcessorV1(feeReceiver, FEE, DEFAULT_HOLD_PERIOD);
        handler = new Handler(pp);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.createInvoice.selector;
        selectors[1] = handler.makePayment.selector;
        selectors[2] = handler.cancelInvoice.selector;
        selectors[3] = handler.rejectInvoice.selector;
        selectors[4] = handler.acceptInvoice.selector;
        selectors[5] = handler.releaseInvoice.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function invariant_currentIdIsValid() public view {
        assertEq(handler.totalInvoiceCreated(), pp.getNextInvoiceId());
    }

    function invariant_feeBalance() public view {
        assertEq(handler.balance(), address(pp).balance);
    }

    function invariant_callSummary() public view {
        handler.callSummary();
    }
}
