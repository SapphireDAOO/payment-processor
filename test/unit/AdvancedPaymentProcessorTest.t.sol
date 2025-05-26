// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

import { AdvancedPaymentProcessorSetUp } from "../util/AdvancedPaymentProcessorSetUp.sol";

import {
    getInvoiceCreationParam,
    getInvoiceCreationParams,
    applyBasisPoints,
    getSubInvoiceIdsForMetaInvoice,
    getEscrowAddress
} from "../util/InvoiceTestHelpers.sol";

contract AdvancedPaymentProcessorTest is AdvancedPaymentProcessorSetUp {
    using { applyBasisPoints, getSubInvoiceIdsForMetaInvoice, getEscrowAddress } for AdvancedPaymentProcessor;

    function test_Initialization() public view {
        assertEq(advancedPP.getNextInvoiceId(), 1);
        assertEq(advancedPP.getNextMetaInvoiceId(), 1);
    }

    function test_singleInvoiceCreation() public {
        uint256 price = 100e8;

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.NotAuthorized.selector);
        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        uint256 nextInvoiceId = advancedPP.getNextInvoiceId();
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(nextInvoiceId - 1);
        assertEq(inv.price, price);
        assertEq(inv.buyer, buyerOne);
        assertEq(inv.seller, sellerOne);
        assertEq(inv.createdAt, block.timestamp);
        assertEq(inv.metaInvoiceId, 0);
        assertEq(nextInvoiceId, 2);
    }

    function test_openMultipleInvoiceWithPayment() public {
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
        advancedPP.createMetaInvoice(
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        uint256 thisMetaInvoiceId = advancedPP.getNextMetaInvoiceId() - 1;
        uint256 upper = advancedPP.getNextInvoiceId() - 1;

        IAdvancedPaymentProcessor.MetaInvoice memory metaInv = advancedPP.getMetaInvoice(thisMetaInvoiceId);
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(upper);

        assertEq(inv.price, prices[1]);
        assertEq(inv.buyer, buyerOne);
        assertEq(inv.seller, sellerTwo);
        assertEq(inv.createdAt, block.timestamp);
        assertEq(inv.metaInvoiceId, thisMetaInvoiceId);
        assertEq(advancedPP.getNextInvoiceId(), upper + 1);

        assertEq(thisMetaInvoiceId, 1);
        assertEq(advancedPP.getMetaInvoiceIdForSub(upper), thisMetaInvoiceId);
        assertEq(advancedPP.getMetaInvoiceIdForSub(startInvoiceId), thisMetaInvoiceId);
        assertEq(metaInv.price, prices[0] + prices[1]);
        assertEq(metaInv.upper, upper);
        assertEq(metaInv.lower, startInvoiceId);
    }

    function test_nativeTokenPaymentForSingleInvoice() public {
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        uint256 thisInvoiceId = advancedPP.totalUniqueInvoiceCreated();

        vm.startPrank(buyerOne);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidPaymentToken.selector);
        advancedPP.paySingleInvoice(thisInvoiceId, address(12));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidNativePayment.selector);
        advancedPP.paySingleInvoice{ value: 0.001 ether }(thisInvoiceId, address(0));

        uint256 amountInToken = advancedPP.getTokenValueFromUsd(address(0), price);
        advancedPP.paySingleInvoice{ value: amountInToken }(thisInvoiceId, address(0));
        vm.stopPrank();

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(thisInvoiceId);

        assertEq(inv.escrow.balance, amountInToken);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, advancedPP.PAID());

        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        uint256 currentId = advancedPP.totalUniqueInvoiceCreated();

        vm.warp(block.timestamp + 1 + 1 days);
        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceExpired.selector);
        advancedPP.paySingleInvoice{ value: price }(currentId, address(0));
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
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        uint256 tokenAmount = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceDoesNotExist.selector);
        advancedPP.payMetaInvoice{ value: 0.03 ether }(10, address(0));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidBuyer.selector);
        advancedPP.payMetaInvoice{ value: tokenAmount }(thisInvoiceId, address(0));

        vm.startPrank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidMetaInvoicePayment.selector);
        advancedPP.payMetaInvoice{ value: 0.01 ether }(thisInvoiceId, address(0));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidPaymentToken.selector);
        advancedPP.payMetaInvoice(thisInvoiceId, address(12));

        advancedPP.payMetaInvoice{ value: tokenAmount }(thisInvoiceId, address(0));

        vm.stopPrank();

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(thisInvoiceId);
        address escrowOne = advancedPP.getEscrowAddress(invOne.seller, invOne.buyer, thisInvoiceId);

        assertEq(invOne.state, advancedPP.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(invOne.escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[0]));
        assertEq(invOne.paymentToken, address(0));

        IAdvancedPaymentProcessor.Invoice memory invTwo = advancedPP.getInvoice(advancedPP.getNextInvoiceId() - 1);
        address escrowTwo = advancedPP.getEscrowAddress(invTwo.seller, invTwo.buyer, advancedPP.getNextInvoiceId() - 1);

        assertEq(invTwo.state, advancedPP.PAID());
        assertEq(invTwo.escrow, escrowTwo);
        assertEq(invTwo.escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[1]));
        assertEq(invTwo.paymentToken, address(0));
    }

    function test_erc20PaymentForSingleInvoice() public {
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        uint256 invoiceId = advancedPP.getNextInvoiceId() - 1;

        vm.prank(buyerTwo);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidBuyer.selector);
        advancedPP.paySingleInvoice(invoiceId, address(mockUsdc));

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice(invoiceId, address(mockUsdc));

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.paySingleInvoice(invoiceId, address(mockUsdc));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(mockUsdc), price);

        assertEq(IERC20(mockUsdc).balanceOf(inv.escrow), tokenValue);
        assertEq(inv.paymentToken, address(mockUsdc));
        assertEq(inv.state, advancedPP.PAID());
    }

    function test_erc20PaymentForMetaInvoice() public {
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

        uint256 thisInvoiceId = advancedPP.getNextInvoiceId();
        advancedPP.createMetaInvoice(
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        vm.prank(buyerOne);

        advancedPP.payMetaInvoice(thisInvoiceId, address(mockWBtc));

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(thisInvoiceId);
        address escrowOne = advancedPP.getEscrowAddress(invOne.seller, invOne.buyer, thisInvoiceId);

        assertEq(invOne.state, advancedPP.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(
            IERC20(mockWBtc).balanceOf(invOne.escrow), advancedPP.getTokenValueFromUsd(address(mockWBtc), prices[0])
        );
        assertEq(invOne.paymentToken, address(mockWBtc));

        IAdvancedPaymentProcessor.Invoice memory invTwo = advancedPP.getInvoice(advancedPP.getNextInvoiceId() - 1);
        address escrowTwo = advancedPP.getEscrowAddress(invTwo.seller, invTwo.buyer, advancedPP.getNextInvoiceId() - 1);

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
        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        uint256 currentId = advancedPP.totalUniqueInvoiceCreated();

        vm.prank(sellerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.acceptInvoice(currentId);

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(currentId, address(0));

        assertEq(advancedPP.getInvoice(currentId).state, advancedPP.PAID());

        vm.prank(sellerTwo);
        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedSeller.selector);
        advancedPP.acceptInvoice(currentId);

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(currentId);

        assertEq(advancedPP.getInvoice(currentId).state, advancedPP.ACCEPTED());

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

        advancedPP.createMetaInvoice(
            buyerTwo, getInvoiceCreationParams(buyerTwo, sellers, prices, responseTime, disputeWindow)
        );

        uint256 currentMetaId = advancedPP.totalMetaInvoiceCreated();

        uint256 metaInvoiceTokenValue = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.prank(buyerTwo);
        advancedPP.payMetaInvoice{ value: metaInvoiceTokenValue }(currentMetaId, address(0));

        uint256[] memory ids = advancedPP.getSubInvoiceIdsForMetaInvoice(currentMetaId);

        vm.prank(sellerTwo);
        advancedPP.acceptInvoice(ids);

        for (uint256 i = 0; i < ids.length - 1; i++) {
            assertEq(advancedPP.getInvoice(ids[i]).state, advancedPP.ACCEPTED());
        }

        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        currentId = advancedPP.totalUniqueInvoiceCreated();

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(currentId, address(0));

        vm.warp(block.timestamp + 1 + 1 days);

        vm.prank(sellerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceResponseTimeExpired.selector);
        advancedPP.acceptInvoice(currentId);
    }

    function test_sellerCancelInitiatedInvoice() public {
        // single invoice
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        uint256 currentId = advancedPP.totalUniqueInvoiceCreated();

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(currentId, address(0));

        uint256 buyersBalanceBeforeCancellation = buyerOne.balance;

        vm.prank(sellerTwo);
        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedSeller.selector);
        advancedPP.cancelInvoice(currentId);

        vm.prank(sellerOne);
        advancedPP.cancelInvoice(currentId);

        vm.prank(sellerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.cancelInvoice(currentId);

        uint256 buyersBalanceAfterCancellation = buyerOne.balance;

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
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        uint256 currentMetaInvoiceId = advancedPP.totalMetaInvoiceCreated();

        tokenValue = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1] + prices[2]);

        vm.prank(buyerOne);
        advancedPP.payMetaInvoice{ value: tokenValue }(currentMetaInvoiceId, address(0));
        buyersBalanceBeforeCancellation = buyerOne.balance;

        uint256[] memory ids = advancedPP.getSubInvoiceIdsForMetaInvoice(currentMetaInvoiceId);

        vm.prank(sellerOne);
        advancedPP.cancelInvoice(ids);

        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(advancedPP.getInvoice(ids[i]).state, advancedPP.CANCELED());
        }

        assertApproxEqAbs(buyerOne.balance - buyersBalanceBeforeCancellation, tokenValue, 1);
    }

    function test_invoiceCancelationRequest() public {
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        uint256 currentId = advancedPP.totalUniqueInvoiceCreated();
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedBuyer.selector);
        advancedPP.requestCancelation(currentId);

        vm.startPrank(buyerOne);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.requestCancelation(currentId);

        advancedPP.paySingleInvoice{ value: tokenValue }(currentId, address(0));

        advancedPP.requestCancelation(currentId);

        vm.stopPrank();
        assertEq(advancedPP.getInvoice(currentId).state, advancedPP.CANCELATION_REQUESTED());

        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        currentId = advancedPP.totalUniqueInvoiceCreated();

        vm.startPrank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(currentId, address(0));

        vm.warp(block.timestamp + 1 + 1 days);
        vm.expectRevert(IAdvancedPaymentProcessor.CancelationRequestDeadlinePassed.selector);
        advancedPP.requestCancelation(currentId);

        vm.stopPrank();
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
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        uint256 totalPrice = prices[0] + prices[1] + prices[2];

        uint256 currentMetaInvoiceId = advancedPP.totalMetaInvoiceCreated();
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), totalPrice);

        vm.startPrank(buyerOne);
        advancedPP.payMetaInvoice{ value: tokenValue }(currentMetaInvoiceId, address(0));

        uint256[] memory ids = advancedPP.getSubInvoiceIdsForMetaInvoice(currentMetaInvoiceId);
        advancedPP.requestCancelation(ids);

        vm.startPrank(sellerOne);

        bool[] memory accept = new bool[](ids.length);
        accept[0] = true; // + 0.01 ether
        accept[1] = false;
        accept[2] = false;

        uint256 buyersBalanceBefore = buyerOne.balance;
        for (uint256 i = 0; i < ids.length; ++i) {
            advancedPP.handleCancelationRequest(ids[i], accept[i]);
        }

        assertEq(buyerOne.balance, buyersBalanceBefore + advancedPP.getTokenValueFromUsd(address(0), prices[0]));
        assertEq(advancedPP.getInvoice(ids[0]).state, advancedPP.CANCELATION_ACCEPTED());
        assertEq(advancedPP.getInvoice(ids[1]).state, advancedPP.CANCELATION_REJECTED());
        assertEq(advancedPP.getInvoice(ids[2]).state, advancedPP.CANCELATION_REJECTED());
    }

    function test_refundAfterInvoiceExpires() public {
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        uint256 id = advancedPP.totalUniqueInvoiceCreated();

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(id, address(0));

        vm.prank(buyerTwo);
        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedBuyer.selector);
        advancedPP.claimExpiredInvoiceRefunds(id);

        vm.startPrank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceStillActive.selector);
        advancedPP.claimExpiredInvoiceRefunds(id);

        uint256 balanceBefore = buyerOne.balance;
        vm.warp(block.timestamp + 1 + 1 days);
        advancedPP.claimExpiredInvoiceRefunds(id);

        vm.expectRevert(IAdvancedPaymentProcessor.AlreadyRefunded.selector);
        advancedPP.claimExpiredInvoiceRefunds(id);
        vm.stopPrank();

        assertEq(advancedPP.getInvoice(id).state, advancedPP.REFUNDED());
        assertEq(advancedPP.getInvoice(id).amountPaid + balanceBefore, buyerOne.balance);

        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        id = advancedPP.totalUniqueInvoiceCreated();

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(id, address(0));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(id);

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.claimExpiredInvoiceRefunds(id);
    }

    function test_disputeCreation() public {
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        uint256 id = advancedPP.totalUniqueInvoiceCreated();
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedBuyer.selector);
        advancedPP.createDispute(id);

        vm.startPrank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.createDispute(id);

        advancedPP.paySingleInvoice{ value: tokenValue }(id, address(0));
        vm.stopPrank();

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(id);

        vm.warp(block.timestamp + 25 hours);

        vm.startPrank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.DisputeWindowExpired.selector);
        advancedPP.createDispute(id);

        vm.warp(block.timestamp - 20 hours);
        advancedPP.createDispute(id);
        vm.stopPrank();

        assertEq(advancedPP.getInvoice(id).state, advancedPP.DISPUTED());
    }

    function test_resolvedAndDismissedDispute() public {
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

        advancedPP.createMetaInvoice(
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );
        uint256 metaInvoiceId = advancedPP.totalMetaInvoiceCreated();

        uint256[] memory ids = advancedPP.getSubInvoiceIdsForMetaInvoice(metaInvoiceId);

        vm.prank(buyerOne);
        advancedPP.payMetaInvoice(metaInvoiceId, address(mockUsdc));

        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(id);
            vm.prank(inv.seller);
            advancedPP.acceptInvoice(id);

            vm.prank(buyerOne);
            advancedPP.createDispute(id);
        }

        uint8 dismissed = advancedPP.DISPUTE_DISMISSED();
        uint8 resolved = advancedPP.DISPUTE_RESOLVED();

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.NotAuthorized.selector);
        advancedPP.resolveDispute(ids[0], dismissed, 0);

        advancedPP.resolveDispute(ids[0], dismissed, 0);

        advancedPP.resolveDispute(ids[1], resolved, 0);

        assertEq(advancedPP.getInvoice(ids[0]).state, dismissed);
        assertEq(advancedPP.getInvoice(ids[1]).state, resolved);
    }

    function test_settledDispute() public {
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        uint256 id = advancedPP.totalUniqueInvoiceCreated();
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(mockUsdc), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice(id, address(mockUsdc));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(id);

        uint256 basisPoint = advancedPP.BASIS_POINTS();
        uint8 dismissed = advancedPP.DISPUTE_DISMISSED();
        uint8 settled = advancedPP.DISPUTE_SETTLED();
        uint8 accepted = advancedPP.ACCEPTED();
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.resolveDispute(id, dismissed, basisPoint);

        vm.prank(buyerOne);
        advancedPP.createDispute(id);

        uint256 buyerBalanceBefore = IERC20(mockUsdc).balanceOf(buyerOne);
        uint256 sellerBalanceBefore = IERC20(mockUsdc).balanceOf(sellerOne);

        console.log("balances before", buyerBalanceBefore, sellerBalanceBefore);

        uint256 sellerPercentage = 9000;

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidSellersPayoutShare.selector);
        advancedPP.resolveDispute(id, settled, basisPoint + 1);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidDisputeResolution.selector);
        advancedPP.resolveDispute(id, accepted, sellerPercentage);

        advancedPP.resolveDispute(id, settled, sellerPercentage);

        uint256 buyerShare = advancedPP.applyBasisPoints(tokenValue, advancedPP.BASIS_POINTS() - sellerPercentage);

        uint256 sellerShare = advancedPP.applyBasisPoints(tokenValue, sellerPercentage);
        uint256 fee = advancedPP.applyBasisPoints(sellerShare, FEE);

        console.log("balances after", IERC20(mockUsdc).balanceOf(buyerOne), IERC20(mockUsdc).balanceOf(sellerOne));

        assertEq(advancedPP.getInvoice(id).state, advancedPP.DISPUTE_SETTLED());
        assertEq(IERC20(mockUsdc).balanceOf(sellerOne), sellerBalanceBefore + sellerShare - fee);
        assertEq(IERC20(mockUsdc).balanceOf(buyerOne), buyerBalanceBefore + buyerShare);
        assertEq(IERC20(mockUsdc).balanceOf(feeReceiver), fee);
    }

    // @audit time factor
    function test_invoiceRelease() public {
        uint256 price = 100e8;
        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        uint256 id = advancedPP.totalUniqueInvoiceCreated();

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.releasePayment(id);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(id, address(0));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.releasePayment(id);

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(id);

        advancedPP.releasePayment(id);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.releasePayment(id);

        assertEq(advancedPP.getInvoice(id).state, advancedPP.RELEASED());
    }
}
