// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

import { AdvancedPaymentProcessorSetUp } from "../utils/AdvancedPaymentProcessorSetUp.sol";

import {
    getInvoiceCreationParam,
    getInvoiceCreationParams,
    applyBasisPoints,
    getEscrowAddress
} from "../utils/InvoiceTestHelpers.sol";

contract AdvancedPaymentProcessorTest is AdvancedPaymentProcessorSetUp {
    using { applyBasisPoints, getEscrowAddress } for AdvancedPaymentProcessor;

    function test_Initialization() public view {
        assertEq(advancedPP.getNextInvoiceId(), 1);
        assertEq(advancedPP.getNextMetaInvoiceId(), 1);
    }

    function test_singleInvoiceCreation() public {
        uint256 price = 100e8;

        uint256 invoiceId = ppStorage.getNextInvoiceId();

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.NotAuthorized.selector);
        advancedPP.createSingleInvoice(getInvoiceCreationParam(invoiceId, sellerOne, price, 1 days, 1 days));

        bytes32 orderId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(invoiceId, sellerOne, price, 1 days, 1 days));

        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceAlreadyExists.selector);
        advancedPP.createSingleInvoice(getInvoiceCreationParam(invoiceId, sellerOne, price, 1 days, 1 days));

        uint256 nextInvoiceId = advancedPP.getNextInvoiceId();
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(orderId);
        assertEq(inv.price, price);
        assertEq(inv.seller, sellerOne);
        assertEq(inv.createdAt, block.timestamp);
        assertEq(inv.metaInvoiceOrderId, bytes32(0));
        assertEq(inv.invoiceId, advancedPP.totalUniqueInvoiceCreated());
        assertEq(nextInvoiceId, 2);
    }

    function test_openMultipleInvoiceWithPayment() public {
        // set up
        uint256 invoiceId = ppStorage.getNextInvoiceId();

        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;

        uint32[] memory responseTime = new uint32[](2);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;

        uint32[] memory disputeWindow = new uint32[](2);
        disputeWindow[0] = 2 days;
        disputeWindow[1] = 2 days;

        uint256 startInvoiceId = advancedPP.getNextInvoiceId();

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, bytes32[] memory keys) =
            getInvoiceCreationParams(invoiceId, sellers, prices, responseTime, disputeWindow);

        // create invoice
        bytes32 metaInvoiceOrderId = advancedPP.createMetaInvoice(param);

        uint256 upper = advancedPP.getNextInvoiceId() - 1;

        IAdvancedPaymentProcessor.MetaInvoice memory metaInv = advancedPP.getMetaInvoice(metaInvoiceOrderId);

        // assertion

        for (uint256 i = 0; i < keys.length; i++) {
            IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(keys[i]);
            assertEq(inv.price, prices[i]);
            assertEq(inv.seller, sellers[i]);
            assertEq(inv.createdAt, block.timestamp);
            assertEq(inv.metaInvoiceOrderId, metaInvoiceOrderId);
            assertEq(advancedPP.getMetaInvoiceIdForSub(keys[i]), metaInvoiceOrderId);
        }

        assertEq(advancedPP.getNextInvoiceId(), upper + 1);
        assertEq(metaInv.price, prices[0] + prices[1]);
        assertEq(metaInv.upper, upper);
        assertEq(metaInv.lower, startInvoiceId);
        assertEq(metaInv.invoiceId, 1);
    }

    function test_nativeTokenPaymentForSingleInvoice() public {
        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );

        vm.startPrank(buyerOne);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidPaymentToken.selector);
        advancedPP.paySingleInvoice(orderId, address(12));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidNativePayment.selector);
        advancedPP.paySingleInvoice{ value: 0.001 ether }(orderId, address(0));

        uint256 amountInToken = advancedPP.getTokenValueFromUsd(address(0), price);
        advancedPP.paySingleInvoice{ value: amountInToken }(orderId, address(0));
        vm.stopPrank();

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(orderId);

        assertEq(inv.escrow.balance, amountInToken);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, advancedPP.PAID());

        orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );

        vm.warp(block.timestamp + 1 + 1 days);
        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceExpired.selector);
        advancedPP.paySingleInvoice{ value: price }(orderId, address(0));
    }

    function test_nativeTokenPaymentForMetaInvoice() public {
        // set up
        uint256 invoiceId = advancedPP.getNextInvoiceId();

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

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, bytes32[] memory orderIds) =
            getInvoiceCreationParams(invoiceId, sellers, prices, responseTime, disputeWindow);

        // create meta invoice
        bytes32 metaInvoiceOrderId = advancedPP.createMetaInvoice(param);

        uint256 tokenAmount = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceDoesNotExist.selector);
        advancedPP.payMetaInvoice{ value: 0.03 ether }(keccak256(""), address(0));

        vm.startPrank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidMetaInvoicePayment.selector);
        advancedPP.payMetaInvoice{ value: 0.01 ether }(metaInvoiceOrderId, address(0));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidPaymentToken.selector);
        advancedPP.payMetaInvoice(metaInvoiceOrderId, address(12));

        advancedPP.payMetaInvoice{ value: tokenAmount }(metaInvoiceOrderId, address(0));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.payMetaInvoice{ value: tokenAmount }(metaInvoiceOrderId, address(0));

        vm.stopPrank();

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(orderIds[0]);
        address escrowOne = advancedPP.getEscrowAddress(invOne.seller, invOne.buyer, orderIds[0]);

        assertEq(invOne.state, advancedPP.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(invOne.escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[0]));
        assertEq(invOne.paymentToken, address(0));

        IAdvancedPaymentProcessor.Invoice memory invTwo = advancedPP.getInvoice(orderIds[1]);
        address escrowTwo = advancedPP.getEscrowAddress(invTwo.seller, invTwo.buyer, orderIds[1]);

        assertEq(invTwo.state, advancedPP.PAID());
        assertEq(invTwo.escrow, escrowTwo);
        assertEq(invTwo.escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[1]));
        assertEq(invTwo.paymentToken, address(0));
    }

    function test_erc20PaymentForSingleInvoice() public {
        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice(orderId, address(mockUsdc));

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.paySingleInvoice(orderId, address(mockUsdc));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(orderId);

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(mockUsdc), price);

        assertEq(IERC20(mockUsdc).balanceOf(inv.escrow), tokenValue);
        assertEq(inv.paymentToken, address(mockUsdc));
        assertEq(inv.state, advancedPP.PAID());
    }

    function test_erc20PaymentForMetaInvoice() public {
        // set up
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;

        uint32[] memory responseTime = new uint32[](2);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;

        uint32[] memory disputeWindow = new uint32[](2);
        disputeWindow[0] = 2 days;
        disputeWindow[1] = 2 days;

        // create meta invoice

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, bytes32[] memory orderIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceId(), sellers, prices, responseTime, disputeWindow);

        bytes32 metaInvoiceOrderId = advancedPP.createMetaInvoice(param);

        // make payment
        vm.prank(buyerOne);
        advancedPP.payMetaInvoice(metaInvoiceOrderId, address(mockWBtc));

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(orderIds[0]);
        address escrowOne = advancedPP.getEscrowAddress(invOne.seller, invOne.buyer, orderIds[0]);

        assertEq(invOne.state, advancedPP.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(
            IERC20(mockWBtc).balanceOf(invOne.escrow), advancedPP.getTokenValueFromUsd(address(mockWBtc), prices[0])
        );
        assertEq(invOne.paymentToken, address(mockWBtc));

        IAdvancedPaymentProcessor.Invoice memory invTwo = advancedPP.getInvoice(orderIds[1]);
        address escrowTwo = advancedPP.getEscrowAddress(invTwo.seller, invTwo.buyer, orderIds[1]);

        assertEq(invTwo.state, advancedPP.PAID());
        assertEq(invTwo.escrow, escrowTwo);
        assertEq(
            IERC20(mockWBtc).balanceOf(invTwo.escrow), advancedPP.getTokenValueFromUsd(address(mockWBtc), prices[1])
        );
        assertEq(invTwo.paymentToken, address(mockWBtc));
    }

    function test_sellerAcceptsInvoice() public {
        // single Invoice

        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );

        uint256 currentId = advancedPP.totalUniqueInvoiceCreated();

        vm.prank(sellerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.acceptInvoice(orderId);

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(orderId, address(0));

        assertEq(advancedPP.getInvoice(orderId).state, advancedPP.PAID());

        vm.prank(sellerTwo);
        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedSeller.selector);
        advancedPP.acceptInvoice(orderId);

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(orderId);

        assertEq(advancedPP.getInvoice(orderId).state, advancedPP.ACCEPTED());

        // meta invoice

        address[] memory sellers = new address[](2);
        sellers[0] = sellerTwo;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 5000e8;
        prices[1] = 3000e8;

        uint32[] memory responseTime = new uint32[](2);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;

        uint32[] memory disputeWindow = new uint32[](2);
        disputeWindow[0] = 2 days;
        disputeWindow[1] = 2 days;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, bytes32[] memory orderIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceId(), sellers, prices, responseTime, disputeWindow);

        bytes32 metaInvoiceOrderId = advancedPP.createMetaInvoice(param);

        uint256 metaInvoiceTokenValue = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.prank(buyerTwo);
        advancedPP.payMetaInvoice{ value: metaInvoiceTokenValue }(metaInvoiceOrderId, address(0));

        vm.startPrank(sellerTwo);
        advancedPP.acceptInvoices(orderIds);

        for (uint256 i = 0; i < orderIds.length - 1; i++) {
            assertEq(advancedPP.getInvoice(orderIds[i]).state, advancedPP.ACCEPTED());
        }

        vm.stopPrank();

        orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, 100e8, 1 days, 1 days)
        );

        currentId = advancedPP.totalUniqueInvoiceCreated();

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(orderId, address(0));

        vm.warp(block.timestamp + 1 + 1 days);

        vm.prank(sellerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceResponseTimeExpired.selector);
        advancedPP.acceptInvoice(orderId);
    }

    function test_cancel_invoice() public {
        // single invoice
        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(orderId, address(0));

        uint256 buyersBalanceBeforeCancellation = buyerOne.balance;

        advancedPP.cancelInvoice(orderId);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.cancelInvoice(orderId);

        uint256 buyersBalanceAfterCancellation = buyerOne.balance;

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

        bytes32 metaInvoiceOrderId = advancedPP.createMetaInvoice(param);

        tokenValue = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1] + prices[2]);

        vm.prank(buyerOne);
        advancedPP.payMetaInvoice{ value: tokenValue }(metaInvoiceOrderId, address(0));
        buyersBalanceBeforeCancellation = buyerOne.balance;

        for (uint256 i = 0; i < orderIds.length; i++) {
            advancedPP.cancelInvoice(orderIds[i]);
            assertEq(advancedPP.getInvoice(orderIds[i]).state, advancedPP.CANCELED());
        }

        vm.stopPrank();

        assertApproxEqAbs(buyerOne.balance - buyersBalanceBeforeCancellation, tokenValue, 1);
    }

    function test_refundAfterInvoiceExpires() public {
        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );
        uint256 id = advancedPP.totalUniqueInvoiceCreated();

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(orderId, address(0));

        vm.startPrank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceStillActive.selector);
        advancedPP.claimExpiredInvoiceRefunds(orderId);

        uint256 balanceBefore = buyerOne.balance;
        vm.warp(block.timestamp + 1 + 1 days);
        advancedPP.claimExpiredInvoiceRefunds(orderId);

        vm.expectRevert(IAdvancedPaymentProcessor.AlreadyRefunded.selector);
        advancedPP.claimExpiredInvoiceRefunds(orderId);
        vm.stopPrank();

        assertEq(advancedPP.getInvoice(orderId).state, advancedPP.REFUNDED());
        assertEq(advancedPP.getInvoice(orderId).amountPaid + balanceBefore, buyerOne.balance);

        orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );
        id = advancedPP.totalUniqueInvoiceCreated();

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(orderId, address(0));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(orderId);

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.claimExpiredInvoiceRefunds(orderId);
    }

    function test_disputeCreation() public {
        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedBuyer.selector);
        advancedPP.createDispute(orderId);

        vm.startPrank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedBuyer.selector);
        advancedPP.createDispute(orderId);

        advancedPP.paySingleInvoice{ value: tokenValue }(orderId, address(0));
        vm.stopPrank();

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(orderId);

        vm.warp(block.timestamp + 25 hours);

        vm.startPrank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.DisputeWindowExpired.selector);
        advancedPP.createDispute(orderId);

        vm.warp(block.timestamp - 20 hours);
        advancedPP.createDispute(orderId);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.createDispute(orderId);
        vm.stopPrank();

        assertEq(advancedPP.getInvoice(orderId).state, advancedPP.DISPUTED());
    }

    function test_dismissedDispute() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;

        uint32[] memory responseTime = new uint32[](2);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;

        uint32[] memory disputeWindow = new uint32[](2);
        disputeWindow[0] = 1 days;
        disputeWindow[1] = 4 days;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, bytes32[] memory orderIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceId(), sellers, prices, responseTime, disputeWindow);

        bytes32 metaInvoiceOrderId = advancedPP.createMetaInvoice(param);

        vm.prank(buyerOne);
        advancedPP.payMetaInvoice(metaInvoiceOrderId, address(mockUsdc));

        for (uint256 i; i < orderIds.length; i++) {
            bytes32 key = orderIds[i];
            IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(key);
            vm.prank(inv.seller);
            advancedPP.acceptInvoice(key);

            vm.prank(buyerOne);
            advancedPP.createDispute(key);
        }

        uint8 dismissed = advancedPP.DISPUTE_DISMISSED();

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.NotAuthorized.selector);
        advancedPP.handleDispute(orderIds[0], dismissed, 0);

        advancedPP.handleDispute(orderIds[0], dismissed, 0);

        assertEq(advancedPP.getInvoice(orderIds[0]).state, dismissed);
    }

    function test_settledDispute() public {
        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(mockUsdc), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice(orderId, address(mockUsdc));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(orderId);

        uint256 basisPoint = advancedPP.BASIS_POINTS();
        uint8 dismissed = advancedPP.DISPUTE_DISMISSED();
        uint8 settled = advancedPP.DISPUTE_SETTLED();
        uint8 accepted = advancedPP.ACCEPTED();
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.handleDispute(orderId, dismissed, basisPoint);

        vm.prank(buyerOne);
        advancedPP.createDispute(orderId);

        uint256 buyerBalanceBefore = IERC20(mockUsdc).balanceOf(buyerOne);
        uint256 sellerBalanceBefore = IERC20(mockUsdc).balanceOf(sellerOne);

        console.log("balances before", buyerBalanceBefore, sellerBalanceBefore);

        uint256 sellerPercentage = 9000;

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidSellersPayoutShare.selector);
        advancedPP.handleDispute(orderId, settled, basisPoint + 1);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidDisputeResolution.selector);
        advancedPP.handleDispute(orderId, accepted, sellerPercentage);

        advancedPP.handleDispute(orderId, settled, sellerPercentage);

        uint256 buyerShare = advancedPP.applyBasisPoints(tokenValue, advancedPP.BASIS_POINTS() - sellerPercentage);

        uint256 sellerShare = advancedPP.applyBasisPoints(tokenValue, sellerPercentage);
        uint256 fee = advancedPP.applyBasisPoints(sellerShare, FEE);

        console.log("balances after", IERC20(mockUsdc).balanceOf(buyerOne), IERC20(mockUsdc).balanceOf(sellerOne));

        assertEq(advancedPP.getInvoice(orderId).state, advancedPP.DISPUTE_SETTLED());
        assertEq(IERC20(mockUsdc).balanceOf(sellerOne), sellerBalanceBefore + sellerShare - fee);
        assertEq(IERC20(mockUsdc).balanceOf(buyerOne), buyerBalanceBefore + buyerShare);
        assertEq(IERC20(mockUsdc).balanceOf(feeReceiver), fee);
    }

    function test_resolveDispute() public {
        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice(orderId, address(mockUsdc));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(orderId);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.resolveDispute(orderId);

        vm.prank(buyerOne);
        advancedPP.createDispute(orderId);

        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedParticipant.selector);
        advancedPP.resolveDispute(orderId);

        vm.prank(buyerOne);
        advancedPP.resolveDispute(orderId);

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(orderId);

        assertEq(inv.resolutionInitiator, buyerOne);
        assertEq(inv.resolutionState, 1);

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.DuplicateResolutionAttempt.selector);
        advancedPP.resolveDispute(orderId);

        vm.prank(sellerOne);
        advancedPP.resolveDispute(orderId);
        assertEq(advancedPP.getInvoice(orderId).state, advancedPP.DISPUTE_RESOLVED());
    }

    function test_invoiceRelease() public {
        uint256 price = 100e8;
        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceId(), sellerOne, price, 1 days, 1 days)
        );
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.releasePayment(orderId);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(orderId, address(0));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.releasePayment(orderId);

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(orderId);

        advancedPP.releasePayment(orderId);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.releasePayment(orderId);

        assertEq(advancedPP.getInvoice(orderId).state, advancedPP.RELEASED());
    }
}
