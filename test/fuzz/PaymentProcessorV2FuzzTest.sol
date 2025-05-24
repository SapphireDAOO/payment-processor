// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IPaymentProcessorV2, PaymentProcessorV2 } from "../../src/PaymentProcessorV2.sol";
import { MockUsdc, MockWbtc } from "../mock/mERC20.sol";
import { PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";

import { V2 } from "../util/V2.sol";

contract PaymentProcessorFuzzTest is V2 { }
