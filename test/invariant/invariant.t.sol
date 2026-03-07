// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { BaseSetUp, PaymentProcessorStorage } from "../utils/BaseSetUp.sol";

import { SimplePaymentProcessorSetUp, SimplePaymentProcessor } from "../utils/SimplePaymentProcessorSetUp.sol";
import { AdvancedPaymentProcessorSetUp, AdvancedPaymentProcessor } from "../utils/AdvancedPaymentProcessorSetUp.sol";

import { SimplePaymentProcessorHandler } from "./handlers/SimplePaymentProcessorHandler.sol";
import { AdvancedPaymentProcessorHandler } from "./handlers/AdvancedPaymentProcessorHandler.sol";
import { ISimplePaymentProcessor } from "../../src/interface/ISimplePaymentProcessor.sol";
import { IAdvancedPaymentProcessor } from "../../src/interface/IAdvancedPaymentProcessor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Invariant is StdInvariant, Test, BaseSetUp, SimplePaymentProcessorSetUp, AdvancedPaymentProcessorSetUp {
    SimplePaymentProcessorHandler sHandler;
    AdvancedPaymentProcessorHandler aHandler;
    address storageAddress;
    address notesAddress;

    SimplePaymentProcessor simplePaymentProcessor;
    AdvancedPaymentProcessor advancedPaymentProcessor;

    function setUp() public override(SimplePaymentProcessorSetUp, AdvancedPaymentProcessorSetUp) {
        (storageAddress, notesAddress) = initialize();

        simplePaymentProcessor = _simplePaymentProcessorSetUp(storageAddress, notesAddress);
        advancedPaymentProcessor = _advancedPaymentProcessorSetUp(storageAddress);

        sHandler = new SimplePaymentProcessorHandler(simplePaymentProcessor, buyerOne, sellerOne, admin);
        aHandler = new AdvancedPaymentProcessorHandler(advancedPaymentProcessor, admin, buyerOne, sellerOne);

        targetContract(address(aHandler));
        targetContract(address(sHandler));
    }

    function invariant_consistentId() external view {
        uint256 totalFromHandlers = sHandler.getTotalInvoiceCreated() + aHandler.getTotalSingleInvoiceCreated();
        uint256 totalInStorage = PaymentProcessorStorage(storageAddress).totalInvoiceCreated();
        assertEq(totalFromHandlers, totalInStorage);
    }

    function invariant_consistentMetaInvoiceId() external view {
        assertEq(aHandler.getTotalMetaInvoiceCreated(), advancedPaymentProcessor.totalMetaInvoiceCreated());
    }

    function invariant_simpleInvoiceStateConsistency() external view {
        uint256 count = sHandler.getInvoiceCount();
        for (uint256 i = 0; i < count; i++) {
            uint216 invoiceId = sHandler.getInvoiceId(i);
            ISimplePaymentProcessor.Invoice memory inv = simplePaymentProcessor.getInvoiceData(invoiceId);

            if (inv.state == simplePaymentProcessor.CREATED() || inv.state == simplePaymentProcessor.CANCELED()) {
                assertEq(inv.balance, 0);
                assertEq(inv.escrow, address(0));
                assertEq(inv.buyer, address(0));
            }

            if (inv.state == simplePaymentProcessor.PAID()) {
                assertTrue(inv.escrow != address(0));
                assertEq(inv.balance, inv.price);
                assertTrue(inv.buyer != address(0));
                assertEq(inv.escrow.balance, inv.balance);
            }

            if (inv.state == simplePaymentProcessor.ACCEPTED()) {
                uint256 fee = simplePaymentProcessor.calculateFee(inv.price);
                assertEq(inv.balance, inv.price - fee);
                assertEq(inv.escrow.balance, inv.balance);
            }

            if (
                inv.state == simplePaymentProcessor.REJECTED() || inv.state == simplePaymentProcessor.REFUNDED()
                    || inv.state == simplePaymentProcessor.RELEASED()
            ) {
                assertEq(inv.balance, 0);
                if (inv.escrow != address(0)) {
                    assertEq(inv.escrow.balance, 0);
                }
            }
        }
    }

    function invariant_advancedInvoiceStateConsistency() external view {
        uint256 count = aHandler.getInvoiceCount();
        for (uint256 i = 0; i < count; i++) {
            uint216 invoiceId = aHandler.getInvoiceId(i);
            IAdvancedPaymentProcessor.Invoice memory inv = advancedPaymentProcessor.getInvoice(invoiceId);

            if (inv.state == advancedPaymentProcessor.CREATED() || inv.state == advancedPaymentProcessor.CANCELED()) {
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

            if (inv.state == advancedPaymentProcessor.RELEASED()) {
                assertEq(inv.balance, 0);
            }

            if (
                inv.state == advancedPaymentProcessor.PAID() || inv.state == advancedPaymentProcessor.DISPUTED()
                    || inv.state == advancedPaymentProcessor.DISPUTE_RESOLVED()
                    || inv.state == advancedPaymentProcessor.DISPUTE_DISMISSED()
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
            IAdvancedPaymentProcessor.MetaInvoice memory metaInv =
                advancedPaymentProcessor.getMetaInvoice(metaInvoiceId);

            uint256 subCount = aHandler.getSubInvoiceCount(metaInvoiceId);
            uint256 sum;
            for (uint256 j = 0; j < subCount; j++) {
                uint216 subId = aHandler.getSubInvoiceId(metaInvoiceId, j);
                IAdvancedPaymentProcessor.Invoice memory sub = advancedPaymentProcessor.getInvoice(subId);
                if (sub.state != advancedPaymentProcessor.CANCELED()) {
                    sum += sub.price;
                }
            }
            assertEq(metaInv.price, sum);
        }
    }

    function invariant_simpleProcessorNativeTokenBalanceIsAlwaysZero() external view {
        assertEq(address(advancedPaymentProcessor).balance, 0);
    }

    function invariant_advancedProcessorNativeTokenBalanceAlwaysZero() external view {
        assertEq(address(advancedPaymentProcessor).balance, 0);
    }
}
