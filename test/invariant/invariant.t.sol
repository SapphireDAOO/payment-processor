// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { BaseSetUp, PaymentProcessorStorage } from "../utils/BaseSetUp.sol";

import { SimplePaymentProcessorSetUp, SimplePaymentProcessor } from "../utils/SimplePaymentProcessorSetUp.sol";
import {
    IntermediatedPaymentProcessorSetUp,
    IntermediatedPaymentProcessor
} from "../utils/IntermediatedPaymentProcessorSetUp.sol";

import { SimplePaymentProcessorHandler } from "./handlers/SimplePaymentProcessorHandler.sol";
import { IntermediatedPaymentProcessorHandler } from "./handlers/IntermediatedPaymentProcessorHandler.sol";
import { ISimplePaymentProcessor } from "../../src/interface/ISimplePaymentProcessor.sol";
import { IIntermediatedPaymentProcessor } from "../../src/interface/IIntermediatedPaymentProcessor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    CREATED,
    PAID,
    CANCELED,
    DISPUTED,
    DISPUTE_RESOLVED,
    DISPUTE_DISMISSED,
    DISPUTE_SETTLED,
    RELEASED,
    REFUNDED as ADV_REFUNDED,
    LOCKED as ADV_LOCKED
} from "src/constants/Intermediated.sol";

import {
    CREATED as SIMPLE_CREATED,
    PAID as SIMPLE_PAID,
    ACCEPTED,
    REJECTED,
    CANCELED as SIMPLE_CANCELED,
    REFUNDED,
    RELEASED as SIMPLE_RELEASED,
    LOCKED
} from "src/constants/Simple.sol";

contract Invariant is StdInvariant, Test, BaseSetUp, SimplePaymentProcessorSetUp, IntermediatedPaymentProcessorSetUp {
    SimplePaymentProcessorHandler sHandler;
    IntermediatedPaymentProcessorHandler aHandler;
    address storageAddress;
    address notesAddress;

    SimplePaymentProcessor simplePaymentProcessor;
    IntermediatedPaymentProcessor intermediatedPaymentProcessor;

    function setUp() public override(SimplePaymentProcessorSetUp, IntermediatedPaymentProcessorSetUp) {
        (storageAddress, notesAddress) = initialize();

        simplePaymentProcessor = _simplePaymentProcessorSetUp(storageAddress, notesAddress);
        intermediatedPaymentProcessor = _intermediatedPaymentProcessorSetUp(storageAddress);

        sHandler = new SimplePaymentProcessorHandler(simplePaymentProcessor, buyerOne, sellerOne, admin);
        aHandler = new IntermediatedPaymentProcessorHandler(intermediatedPaymentProcessor, admin, buyerOne, sellerOne);

        targetContract(address(aHandler));
        targetContract(address(sHandler));
    }

    function invariant_consistentId() external view {
        uint256 totalFromHandlers = sHandler.getTotalInvoiceCreated() + aHandler.getTotalSingleInvoiceCreated();
        uint256 totalInStorage = PaymentProcessorStorage(storageAddress).totalInvoiceCreated();
        assertEq(totalFromHandlers, totalInStorage);
    }

    function invariant_consistentMetaInvoiceId() external view {
        assertEq(aHandler.getTotalMetaInvoiceCreated(), intermediatedPaymentProcessor.totalMetaInvoiceCreated());
    }

    function invariant_simpleInvoiceStateConsistency() external view {
        uint256 count = sHandler.getInvoiceCount();
        for (uint256 i = 0; i < count; i++) {
            uint216 invoiceId = sHandler.getInvoiceId(i);
            ISimplePaymentProcessor.Invoice memory inv = simplePaymentProcessor.getInvoiceData(invoiceId);

            if (inv.state == SIMPLE_CREATED || inv.state == SIMPLE_CANCELED) {
                assertEq(inv.balance, 0);
                assertEq(inv.escrow, address(0));
                assertEq(inv.buyer, address(0));
            }

            if (inv.state == SIMPLE_PAID) {
                assertTrue(inv.escrow != address(0));
                assertEq(inv.balance, inv.price);
                assertTrue(inv.buyer != address(0));
                assertEq(inv.escrow.balance, inv.balance);
            }

            if (inv.state == ACCEPTED) {
                assertEq(inv.balance, inv.price);
                assertEq(inv.escrow.balance, inv.balance);
            }

            if (inv.state == REJECTED || inv.state == REFUNDED || inv.state == SIMPLE_RELEASED) {
                assertEq(inv.balance, 0);
                if (inv.escrow != address(0)) {
                    assertEq(inv.escrow.balance, 0);
                }
            }

            if (inv.state == LOCKED) {
                assertTrue(inv.escrow != address(0));
                assertEq(inv.escrow.balance, inv.price);
            }
        }
    }

    function invariant_intermediatedInvoiceStateConsistency() external view {
        uint256 count = aHandler.getInvoiceCount();
        for (uint256 i = 0; i < count; i++) {
            uint216 invoiceId = aHandler.getInvoiceId(i);
            IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPaymentProcessor.getInvoice(invoiceId);

            if (inv.state == CREATED || inv.state == CANCELED) {
                assertEq(inv.balance, 0);
                assertEq(inv.amountPaid, 0);
                assertEq(inv.escrow, address(0));
                assertEq(inv.buyer, address(0));
                continue;
            }

            assertTrue(inv.escrow != address(0));
            assertTrue(inv.amountPaid > 0);
            assertTrue(inv.buyer != address(0));
            assertLe(inv.balance, inv.amountPaid);

            if (inv.state == RELEASED || inv.state == ADV_REFUNDED || inv.state == DISPUTE_SETTLED) {
                assertEq(inv.balance, 0);
            }

            if (inv.state == ADV_LOCKED) {
                assertTrue(inv.balance > 0);
            }

            if (
                inv.state == PAID || inv.state == DISPUTED || inv.state == DISPUTE_RESOLVED
                    || inv.state == DISPUTE_DISMISSED || inv.state == ADV_LOCKED
            ) {
                if (inv.paymentToken == address(0)) {
                    assertEq(inv.escrow.balance, inv.balance);
                } else {
                    assertEq(IERC20(inv.paymentToken).balanceOf(inv.escrow), inv.balance);
                }
            }
        }
    }

    function invariant_metaInvoicePriceConsistency() external view {
        uint256 metaCount = aHandler.getMetaInvoiceCount();
        for (uint256 i = 0; i < metaCount; i++) {
            uint216 metaInvoiceId = aHandler.getMetaInvoiceId(i);
            IIntermediatedPaymentProcessor.MetaInvoice memory metaInv =
                intermediatedPaymentProcessor.getMetaInvoice(metaInvoiceId);

            uint256 subCount = aHandler.getSubInvoiceCount(metaInvoiceId);
            uint256 sum;
            for (uint256 j = 0; j < subCount; j++) {
                uint216 subId = aHandler.getSubInvoiceId(metaInvoiceId, j);
                IIntermediatedPaymentProcessor.Invoice memory sub = intermediatedPaymentProcessor.getInvoice(subId);
                if (sub.state != CANCELED) {
                    sum += sub.price;
                }
            }
            assertEq(metaInv.price, sum);
        }
    }

    function invariant_simpleProcessorNativeTokenBalanceIsAlwaysZero() external view {
        assertEq(address(simplePaymentProcessor).balance, 0);
    }

    function invariant_intermediatedProcessorNativeTokenBalanceAlwaysZero() external view {
        assertEq(address(intermediatedPaymentProcessor).balance, 0);
    }
}
