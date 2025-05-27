// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AdvancedPaymentProcessorSetUp } from "../utils/AdvancedPaymentProcessorSetUp.sol";
import {
    getInvoiceCreationParam,
    getInvoiceCreationParams,
    getEscrowAddress,
    getSubInvoiceIdsForMetaInvoice,
    applyBasisPoints
} from "../utils/InvoiceTestHelpers.sol";

contract Interactions is AdvancedPaymentProcessorSetUp {
    using { getEscrowAddress, getSubInvoiceIdsForMetaInvoice, applyBasisPoints } for AdvancedPaymentProcessor;

    string POLYGON_MAINNET_RPC = vm.envString("MAINNET_RPC");

    function setUp() public override {
        uint256 fork = vm.createFork(POLYGON_MAINNET_RPC);
        vm.selectFork(fork);
        super.setUp();
    }

    function test_nativeTokenPaymentForSingleInvoice() public {
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(NATIVE_TOKEN_BUYER, sellerOne, price, 1 days, 1 days));
        uint256 thisInvoiceId = advancedPP.totalUniqueInvoiceCreated();

        uint256 amountInToken = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(NATIVE_TOKEN_BUYER);
        advancedPP.paySingleInvoice{ value: amountInToken }(thisInvoiceId, address(0));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(thisInvoiceId);

        assertEq(inv.escrow.balance, amountInToken);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, advancedPP.PAID());
    }

    function test_nativeTokenPaymentForMetaInvoice() public {
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

        uint256 thisInvoiceId = advancedPP.getNextInvoiceId();
        advancedPP.createMetaInvoice(
            NATIVE_TOKEN_BUYER,
            getInvoiceCreationParams(NATIVE_TOKEN_BUYER, sellers, prices, responseTime, disputeWindow)
        );

        uint256 tokenAmount = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.prank(NATIVE_TOKEN_BUYER);

        advancedPP.payMetaInvoice{ value: tokenAmount }(thisInvoiceId, address(0));

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(thisInvoiceId);
        address escrowOne =
            advancedPP.getEscrowAddress(invOne.seller, invOne.buyer, thisInvoiceId, invOne.metaInvoiceId);

        assertEq(invOne.state, advancedPP.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(invOne.escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[0]));
        assertEq(invOne.paymentToken, address(0));

        IAdvancedPaymentProcessor.Invoice memory invTwo = advancedPP.getInvoice(advancedPP.getNextInvoiceId() - 1);
        address escrowTwo = advancedPP.getEscrowAddress(
            invTwo.seller, invTwo.buyer, advancedPP.getNextInvoiceId() - 1, invTwo.metaInvoiceId
        );

        assertEq(invTwo.state, advancedPP.PAID());
        assertEq(invTwo.escrow, escrowTwo);
        assertEq(invTwo.escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[1]));
        assertEq(invTwo.paymentToken, address(0));
    }

    function test_erc20PaymentForSingleInvoice() public {
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(USDC_BUYER, sellerOne, price, 1 days, 1 days));
        uint256 invoiceId = advancedPP.getNextInvoiceId() - 1;

        vm.prank(USDC_BUYER);
        advancedPP.paySingleInvoice(invoiceId, address(USDC));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

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

        uint256 thisInvoiceId = advancedPP.getNextInvoiceId();
        advancedPP.createMetaInvoice(
            WTBC_BUYER, getInvoiceCreationParams(WTBC_BUYER, sellers, prices, responseTime, disputeWindow)
        );

        vm.startPrank(WTBC_BUYER);
        advancedPP.payMetaInvoice(thisInvoiceId, address(WBTC));

        vm.stopPrank();

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(thisInvoiceId);
        address escrowOne =
            advancedPP.getEscrowAddress(invOne.seller, invOne.buyer, thisInvoiceId, invOne.metaInvoiceId);

        assertEq(invOne.state, advancedPP.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(IERC20(WBTC).balanceOf(invOne.escrow), advancedPP.getTokenValueFromUsd(address(WBTC), prices[0]));
        assertEq(invOne.paymentToken, address(WBTC));

        IAdvancedPaymentProcessor.Invoice memory invTwo = advancedPP.getInvoice(advancedPP.getNextInvoiceId() - 1);
        address escrowTwo = advancedPP.getEscrowAddress(
            invTwo.seller, invTwo.buyer, advancedPP.getNextInvoiceId() - 1, invTwo.metaInvoiceId
        );

        assertEq(invTwo.state, advancedPP.PAID());
        assertEq(invTwo.escrow, escrowTwo);
        assertEq(IERC20(WBTC).balanceOf(invTwo.escrow), advancedPP.getTokenValueFromUsd(address(WBTC), prices[1]));
        assertEq(invTwo.paymentToken, address(WBTC));
    }

    function test_sellerCancelInitiatedInvoice() public {
        // single invoice
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(NATIVE_TOKEN_BUYER, sellerOne, price, 1 days, 1 days));

        uint256 currentId = advancedPP.totalUniqueInvoiceCreated();

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(NATIVE_TOKEN_BUYER);
        advancedPP.paySingleInvoice{ value: tokenValue }(currentId, address(0));

        uint256 buyersBalanceBeforeCancellation = NATIVE_TOKEN_BUYER.balance;

        vm.prank(sellerOne);
        advancedPP.cancelInvoice(currentId);

        uint256 buyersBalanceAfterCancellation = NATIVE_TOKEN_BUYER.balance;

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(currentId);
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

        advancedPP.createMetaInvoice(
            NATIVE_TOKEN_BUYER,
            getInvoiceCreationParams(NATIVE_TOKEN_BUYER, sellers, prices, responseTime, disputeWindow)
        );

        uint256 currentMetaInvoiceId = advancedPP.totalMetaInvoiceCreated();

        tokenValue = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1] + prices[2]);

        vm.prank(NATIVE_TOKEN_BUYER);
        advancedPP.payMetaInvoice{ value: tokenValue }(currentMetaInvoiceId, address(0));
        buyersBalanceBeforeCancellation = NATIVE_TOKEN_BUYER.balance;

        uint256[] memory ids = advancedPP.getSubInvoiceIdsForMetaInvoice(currentMetaInvoiceId);

        vm.prank(sellerOne);
        advancedPP.cancelInvoice(ids);

        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(advancedPP.getInvoice(ids[i]).state, advancedPP.CANCELED());
        }

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

        advancedPP.createMetaInvoice(
            NATIVE_TOKEN_BUYER,
            getInvoiceCreationParams(NATIVE_TOKEN_BUYER, sellers, prices, responseTime, disputeWindow)
        );

        uint256 totalPrice = prices[0] + prices[1] + prices[2];

        uint256 currentMetaInvoiceId = advancedPP.totalMetaInvoiceCreated();
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), totalPrice);

        vm.startPrank(NATIVE_TOKEN_BUYER);
        advancedPP.payMetaInvoice{ value: tokenValue }(currentMetaInvoiceId, address(0));

        uint256[] memory ids = advancedPP.getSubInvoiceIdsForMetaInvoice(currentMetaInvoiceId);
        advancedPP.requestCancelation(ids);

        vm.startPrank(sellerOne);

        bool[] memory accept = new bool[](ids.length);
        accept[0] = true; // + 0.01 ether
        accept[1] = false;
        accept[2] = false;

        uint256 buyersBalanceBefore = NATIVE_TOKEN_BUYER.balance;
        for (uint256 i = 0; i < ids.length; ++i) {
            advancedPP.handleCancelationRequest(ids[i], accept[i]);
        }

        assertEq(
            NATIVE_TOKEN_BUYER.balance, buyersBalanceBefore + advancedPP.getTokenValueFromUsd(address(0), prices[0])
        );
        assertEq(advancedPP.getInvoice(ids[0]).state, advancedPP.CANCELATION_ACCEPTED());
        assertEq(advancedPP.getInvoice(ids[1]).state, advancedPP.CANCELATION_REJECTED());
        assertEq(advancedPP.getInvoice(ids[2]).state, advancedPP.CANCELATION_REJECTED());
    }

    function test_refundAfterInvoiceExpires() public {
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(NATIVE_TOKEN_BUYER, sellerOne, price, 1 days, 1 days));
        uint256 id = advancedPP.totalUniqueInvoiceCreated();

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.startPrank(NATIVE_TOKEN_BUYER);
        advancedPP.paySingleInvoice{ value: tokenValue }(id, address(0));

        uint256 balanceBefore = NATIVE_TOKEN_BUYER.balance;
        vm.warp(block.timestamp + 1 + 1 days);
        advancedPP.claimExpiredInvoiceRefunds(id);

        vm.stopPrank();

        assertEq(advancedPP.getInvoice(id).state, advancedPP.REFUNDED());
        assertEq(advancedPP.getInvoice(id).amountPaid + balanceBefore, NATIVE_TOKEN_BUYER.balance);
    }

    function test_settledDispute() public {
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(USDC_BUYER, sellerOne, price, 1 days, 1 days));
        uint256 id = advancedPP.totalUniqueInvoiceCreated();
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(USDC), price);

        vm.prank(USDC_BUYER);
        advancedPP.paySingleInvoice(id, address(USDC));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(id);

        uint8 settled = advancedPP.DISPUTE_SETTLED();

        vm.prank(USDC_BUYER);
        advancedPP.createDispute(id);

        uint256 buyerBalanceBefore = IERC20(USDC).balanceOf(USDC_BUYER);
        uint256 sellerBalanceBefore = IERC20(USDC).balanceOf(sellerOne);

        uint256 sellerPercentage = 9000;

        advancedPP.resolveDispute(id, settled, sellerPercentage);

        uint256 buyerShare = advancedPP.applyBasisPoints(tokenValue, advancedPP.BASIS_POINTS() - sellerPercentage);

        uint256 sellerShare = advancedPP.applyBasisPoints(tokenValue, sellerPercentage);
        uint256 fee = advancedPP.applyBasisPoints(sellerShare, FEE);

        assertEq(advancedPP.getInvoice(id).state, advancedPP.DISPUTE_SETTLED());
        assertEq(IERC20(USDC).balanceOf(sellerOne), sellerBalanceBefore + sellerShare - fee);
        assertEq(IERC20(USDC).balanceOf(USDC_BUYER), buyerBalanceBefore + buyerShare);
        assertEq(IERC20(USDC).balanceOf(feeReceiver), fee);
    }

    function test_invoiceRelease() public {
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(NATIVE_TOKEN_BUYER, sellerOne, price, 1 days, 1 days));
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        uint256 id = advancedPP.totalUniqueInvoiceCreated();

        vm.prank(NATIVE_TOKEN_BUYER);
        advancedPP.paySingleInvoice{ value: tokenValue }(id, address(0));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(id);

        advancedPP.releasePayment(id);

        assertEq(advancedPP.getInvoice(id).state, advancedPP.RELEASED());
    }
}
