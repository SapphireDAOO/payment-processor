// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AdvancedPaymentProcessorSetUp } from "../utils/AdvancedPaymentProcessorSetUp.sol";
import {
    getInvoiceCreationParam,
    getInvoiceCreationParams,
    getEscrowAddress,
    applyBasisPoints,
    computeMetaorderId,
    computeSingleorderId
} from "../utils/InvoiceTestHelpers.sol";

contract Interactions is AdvancedPaymentProcessorSetUp {
    using { getEscrowAddress, applyBasisPoints } for AdvancedPaymentProcessor;

    string POLYGON_MAINNET_RPC = vm.envString("MAINNET_RPC");

    function setUp() public override {
        uint256 fork = vm.createFork(POLYGON_MAINNET_RPC);
        vm.selectFork(fork);
        super.setUp();
    }

    function test_nativeTokenPaymentForSingleInvoice() public {
        uint256 price = 100e8;
        bytes32 orderIdId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );

        uint256 amountInToken = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(NATIVE_TOKEN_BUYER);
        advancedPP.paySingleInvoice{ value: amountInToken }(orderIdId, address(0));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(orderIdId);

        assertEq(inv.escrow.balance, amountInToken);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, advancedPP.PAID());
    }

    function test_nativeTokenPaymentForMetaInvoice() public {
        // set up
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 150e8;
        prices[1] = 250e8;

        uint32[] memory responseTime = new uint32[](2);
        responseTime[0] = 1 days;
        responseTime[1] = 5 days;

        uint32[] memory disputeWindow = new uint32[](2);
        disputeWindow[0] = 1 days;
        disputeWindow[1] = 3 days;

        // create invoice

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, bytes32[] memory orderIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceId(), sellers, prices, responseTime, disputeWindow);

        bytes32 metaorderId = advancedPP.createMetaInvoice(param);

        // make payment
        uint256 tokenAmount = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.prank(NATIVE_TOKEN_BUYER);

        advancedPP.payMetaInvoice{ value: tokenAmount }(metaorderId, address(0));

        for (uint256 i = 0; i < orderIds.length; i++) {
            IAdvancedPaymentProcessor.Invoice memory subInvoice = advancedPP.getInvoice(orderIds[i]);
            address escrow = advancedPP.getEscrowAddress(subInvoice.seller, subInvoice.buyer, orderIds[i]);

            assertEq(subInvoice.state, advancedPP.PAID());
            assertEq(subInvoice.escrow, escrow);
            assertEq(escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[i]));
            assertEq(subInvoice.paymentToken, address(0));
        }
    }

    function test_erc20PaymentForSingleInvoice() public {
        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );

        vm.prank(USDC_BUYER);
        advancedPP.paySingleInvoice(orderId, address(USDC));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(orderId);

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(USDC), price);

        assertEq(IERC20(USDC).balanceOf(inv.escrow), tokenValue);
        assertEq(inv.paymentToken, address(USDC));
        assertEq(inv.state, advancedPP.PAID());
    }

    function test_erc20PaymentForMetaInvoice() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 100e8;
        prices[1] = 200e8;

        uint32[] memory responseTime = new uint32[](2);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;

        uint32[] memory disputeWindow = new uint32[](2);
        disputeWindow[0] = 2 days;
        disputeWindow[1] = 2 days;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, bytes32[] memory orderIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceId(), sellers, prices, responseTime, disputeWindow);

        bytes32 metaorderId = advancedPP.createMetaInvoice(param);

        vm.startPrank(WTBC_BUYER);
        advancedPP.payMetaInvoice(metaorderId, address(WBTC));

        vm.stopPrank();

        for (uint256 i = 0; i < orderIds.length; i++) {
            IAdvancedPaymentProcessor.Invoice memory subInvoice = advancedPP.getInvoice(orderIds[i]);
            address escrow = advancedPP.getEscrowAddress(subInvoice.seller, subInvoice.buyer, orderIds[i]);

            assertEq(subInvoice.state, advancedPP.PAID());
            assertEq(subInvoice.escrow, escrow);
            assertEq(
                IERC20(WBTC).balanceOf(subInvoice.escrow), advancedPP.getTokenValueFromUsd(address(WBTC), prices[i])
            );
            assertEq(subInvoice.paymentToken, address(WBTC));
        }
    }

    function test_sellerCancelInitiatedInvoice() public {
        // single invoice
        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(NATIVE_TOKEN_BUYER);
        advancedPP.paySingleInvoice{ value: tokenValue }(orderId, address(0));

        uint256 buyersBalanceBeforeCancellation = NATIVE_TOKEN_BUYER.balance;

        vm.prank(sellerOne);
        advancedPP.cancelInvoice(orderId);

        uint256 buyersBalanceAfterCancellation = NATIVE_TOKEN_BUYER.balance;

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(orderId);
        assertEq(invOne.state, advancedPP.CANCELED());
        assertEq(buyersBalanceAfterCancellation - buyersBalanceBeforeCancellation, tokenValue);

        // meta invoice

        address[] memory sellers = new address[](3);
        sellers[0] = sellerOne;
        sellers[1] = sellerOne;
        sellers[2] = sellerOne;

        uint256[] memory prices = new uint256[](3);
        prices[0] = price;
        prices[1] = 500e8;
        prices[2] = 1400e8;

        uint32[] memory responseTime = new uint32[](3);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;
        responseTime[2] = 1 days;

        uint32[] memory disputeWindow = new uint32[](3);
        disputeWindow[0] = 1 days;
        disputeWindow[1] = 4 days;
        disputeWindow[2] = 5 days;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, bytes32[] memory orderIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceId(), sellers, prices, responseTime, disputeWindow);

        bytes32 metaorderId = advancedPP.createMetaInvoice(param);

        tokenValue = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1] + prices[2]);

        vm.prank(NATIVE_TOKEN_BUYER);
        advancedPP.payMetaInvoice{ value: tokenValue }(metaorderId, address(0));
        buyersBalanceBeforeCancellation = NATIVE_TOKEN_BUYER.balance;

        vm.startPrank(sellerOne);

        for (uint256 i = 0; i < orderIds.length; i++) {
            advancedPP.cancelInvoice(orderIds[i]);
            assertEq(advancedPP.getInvoice(orderIds[i]).state, advancedPP.CANCELED());
        }
        
        vm.stopPrank();

        assertApproxEqAbs(NATIVE_TOKEN_BUYER.balance - buyersBalanceBeforeCancellation, tokenValue, 2);
    }

    function test_handleInvoiceCancelation() public {
        address[] memory sellers = new address[](3);
        sellers[0] = sellerOne;
        sellers[1] = sellerOne;
        sellers[2] = sellerOne;

        uint256[] memory prices = new uint256[](3);
        prices[0] = 50e8;
        prices[1] = 2500e8;
        prices[2] = 100e8;

        uint32[] memory responseTime = new uint32[](3);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;
        responseTime[2] = 1 days;

        uint32[] memory disputeWindow = new uint32[](3);
        disputeWindow[0] = 1 days;
        disputeWindow[1] = 4 days;
        disputeWindow[2] = 5 days;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, bytes32[] memory orderIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceId(), sellers, prices, responseTime, disputeWindow);

        bytes32 metaorderId = advancedPP.createMetaInvoice(param);

        uint256 totalPrice = prices[0] + prices[1] + prices[2];

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), totalPrice);

        vm.startPrank(NATIVE_TOKEN_BUYER);
        advancedPP.payMetaInvoice{ value: tokenValue }(metaorderId, address(0));

        for (uint256 i = 0; i < orderIds.length; ++i) {
            advancedPP.requestCancelation(orderIds[i]);
        }

        vm.startPrank(sellerOne);

        bool[] memory accept = new bool[](orderIds.length);
        accept[0] = true; // + 0.01 ether
        accept[1] = false;
        accept[2] = false;

        uint256 buyersBalanceBefore = NATIVE_TOKEN_BUYER.balance;
        for (uint256 i = 0; i < orderIds.length; ++i) {
            advancedPP.handleCancelationRequest(orderIds[i], accept[i]);
        }

        assertEq(
            NATIVE_TOKEN_BUYER.balance, buyersBalanceBefore + advancedPP.getTokenValueFromUsd(address(0), prices[0])
        );
        assertEq(advancedPP.getInvoice(orderIds[0]).state, advancedPP.CANCELATION_ACCEPTED());
        assertEq(advancedPP.getInvoice(orderIds[1]).state, advancedPP.CANCELATION_REJECTED());
        assertEq(advancedPP.getInvoice(orderIds[2]).state, advancedPP.CANCELATION_REJECTED());
    }

    function test_refundAfterInvoiceExpires() public {
        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.startPrank(NATIVE_TOKEN_BUYER);
        advancedPP.paySingleInvoice{ value: tokenValue }(orderId, address(0));

        uint256 balanceBefore = NATIVE_TOKEN_BUYER.balance;
        vm.warp(block.timestamp + 1 + 1 days);
        advancedPP.claimExpiredInvoiceRefunds(orderId);

        vm.stopPrank();

        assertEq(advancedPP.getInvoice(orderId).state, advancedPP.REFUNDED());
        assertEq(advancedPP.getInvoice(orderId).amountPaid + balanceBefore, NATIVE_TOKEN_BUYER.balance);
    }

    function test_settledDispute() public {
        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(USDC), price);

        vm.prank(USDC_BUYER);
        advancedPP.paySingleInvoice(orderId, address(USDC));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(orderId);

        uint8 settled = advancedPP.DISPUTE_SETTLED();

        vm.prank(USDC_BUYER);
        advancedPP.createDispute(orderId);

        uint256 buyerBalanceBefore = IERC20(USDC).balanceOf(USDC_BUYER);
        uint256 sellerBalanceBefore = IERC20(USDC).balanceOf(sellerOne);

        uint256 sellerPercentage = 9000;

        advancedPP.handleDispute(orderId, settled, sellerPercentage);

        uint256 buyerShare = advancedPP.applyBasisPoints(tokenValue, advancedPP.BASIS_POINTS() - sellerPercentage);

        uint256 sellerShare = advancedPP.applyBasisPoints(tokenValue, sellerPercentage);
        uint256 fee = advancedPP.applyBasisPoints(sellerShare, FEE);

        assertEq(advancedPP.getInvoice(orderId).state, advancedPP.DISPUTE_SETTLED());
        assertEq(IERC20(USDC).balanceOf(sellerOne), sellerBalanceBefore + sellerShare - fee);
        assertEq(IERC20(USDC).balanceOf(USDC_BUYER), buyerBalanceBefore + buyerShare);
        assertEq(IERC20(USDC).balanceOf(feeReceiver), fee);
    }

    function test_invoiceRelease() public {
        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(NATIVE_TOKEN_BUYER);
        advancedPP.paySingleInvoice{ value: tokenValue }(orderId, address(0));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(orderId);

        advancedPP.releasePayment(orderId);

        assertEq(advancedPP.getInvoice(orderId).state, advancedPP.RELEASED());
    }
}
