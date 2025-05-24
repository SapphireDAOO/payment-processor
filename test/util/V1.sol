// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentProcessorV1, PaymentProcessorV1 } from "../../src/PaymentProcessorV1.sol";
import { SetUp } from "./SetUp.sol";

abstract contract V1 is SetUp {
    PaymentProcessorV1 pp;
    uint256 constant MINIMUM_INVOICE_VALUE = 1 ether;
    uint256 constant DEFAULT_HOLD_PERIOD = 1 days;

    function setUp() public virtual {
        initialize();
        vm.prank(admin);
        pp = new PaymentProcessorV1(address(ppStorage), DEFAULT_HOLD_PERIOD, MINIMUM_INVOICE_VALUE);
    }
}
