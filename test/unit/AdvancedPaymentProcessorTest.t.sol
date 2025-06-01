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
    getSubInvoiceIdsForMetaInvoice,
    getEscrowAddress,
    getSubInvoiceKeyOfMetaInvoice
} from "../utils/InvoiceTestHelpers.sol";

contract AdvancedPaymentProcessorTest is AdvancedPaymentProcessorSetUp {
    using {
        applyBasisPoints,
        getSubInvoiceIdsForMetaInvoice,
        getEscrowAddress,
        getSubInvoiceKeyOfMetaInvoice
    } for AdvancedPaymentProcessor;

    function test_Initialization() public view {
        assertEq(advancedPP.getNextInvoiceId(), 1);
        assertEq(advancedPP.getNextMetaInvoiceId(), 1);
    }

    function test_singleInvoiceCreation() public {
        uint256 price = 100e8;

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.NotAuthorized.selector);
        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        bytes32 invoiceKey =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        uint256 nextInvoiceId = advancedPP.getNextInvoiceId();
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceKey);
        assertEq(inv.price, price);
        assertEq(inv.buyer, buyerOne);
        assertEq(inv.seller, sellerOne);
        assertEq(inv.createdAt, block.timestamp);
        assertEq(inv.metaInvoiceKey, bytes32(0));
        assertEq(inv.invoiceId, advancedPP.totalUniqueInvoiceCreated());
        assertEq(nextInvoiceId, 2);
    }

    function test_openMultipleInvoiceWithPayment() public {
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

        uint256 startInvoiceId = advancedPP.getNextInvoiceId();

        // create invoice
        bytes32 metaInvoiceKey = advancedPP.createMetaInvoice(
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        uint256 upper = advancedPP.getNextInvoiceId() - 1;

        IAdvancedPaymentProcessor.MetaInvoice memory metaInv = advancedPP.getMetaInvoice(metaInvoiceKey);

        // assertion

        bytes32[] memory keys = advancedPP.getSubInvoiceKeyOfMetaInvoice(buyerOne, metaInvoiceKey);

        for (uint256 i = 0; i < keys.length; i++) {
            IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(keys[i]);
            assertEq(inv.price, prices[i]);
            assertEq(inv.buyer, buyerOne);
            assertEq(inv.seller, sellers[i]);
            assertEq(inv.createdAt, block.timestamp);
            assertEq(inv.metaInvoiceKey, metaInvoiceKey);
            assertEq(advancedPP.getMetaInvoiceIdForSub(keys[i]), metaInvoiceKey);
        }

        assertEq(advancedPP.getNextInvoiceId(), upper + 1);
        assertEq(metaInv.price, prices[0] + prices[1]);
        assertEq(metaInv.upper, upper);
        assertEq(metaInv.lower, startInvoiceId);
        assertEq(metaInv.invoiceId, 1);
    }

    function test_nativeTokenPaymentForSingleInvoice() public {
        uint256 price = 100e8;
        bytes32 invoiceKey =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        vm.startPrank(buyerOne);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidPaymentToken.selector);
        advancedPP.paySingleInvoice(invoiceKey, address(12));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidNativePayment.selector);
        advancedPP.paySingleInvoice{ value: 0.001 ether }(invoiceKey, address(0));

        uint256 amountInToken = advancedPP.getTokenValueFromUsd(address(0), price);
        advancedPP.paySingleInvoice{ value: amountInToken }(invoiceKey, address(0));
        vm.stopPrank();

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceKey);

        assertEq(inv.escrow.balance, amountInToken);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, advancedPP.PAID());

        invoiceKey = advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        vm.warp(block.timestamp + 1 + 1 days);
        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceExpired.selector);
        advancedPP.paySingleInvoice{ value: price }(invoiceKey, address(0));
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

        // create meta invoice
        bytes32 metaInvoiceKey = advancedPP.createMetaInvoice(
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        uint256 tokenAmount = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceDoesNotExist.selector);
        advancedPP.payMetaInvoice{ value: 0.03 ether }(keccak256(""), address(0));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidBuyer.selector);
        advancedPP.payMetaInvoice{ value: tokenAmount }(metaInvoiceKey, address(0));

        vm.startPrank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidMetaInvoicePayment.selector);
        advancedPP.payMetaInvoice{ value: 0.01 ether }(metaInvoiceKey, address(0));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidPaymentToken.selector);
        advancedPP.payMetaInvoice(metaInvoiceKey, address(12));

        advancedPP.payMetaInvoice{ value: tokenAmount }(metaInvoiceKey, address(0));

        vm.stopPrank();

        bytes32[] memory invoiceKeys = advancedPP.getSubInvoiceKeyOfMetaInvoice(buyerOne, metaInvoiceKey);

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(invoiceKeys[0]);
        address escrowOne = advancedPP.getEscrowAddress(invOne.seller, invOne.buyer, invoiceKeys[0]);

        assertEq(invOne.state, advancedPP.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(invOne.escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[0]));
        assertEq(invOne.paymentToken, address(0));

        IAdvancedPaymentProcessor.Invoice memory invTwo = advancedPP.getInvoice(invoiceKeys[1]);
        address escrowTwo = advancedPP.getEscrowAddress(invTwo.seller, invTwo.buyer, invoiceKeys[1]);

        assertEq(invTwo.state, advancedPP.PAID());
        assertEq(invTwo.escrow, escrowTwo);
        assertEq(invTwo.escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[1]));
        assertEq(invTwo.paymentToken, address(0));
    }

    function test_erc20PaymentForSingleInvoice() public {
        uint256 price = 100e8;
        bytes32 invoiceKey =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        vm.prank(buyerTwo);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidBuyer.selector);
        advancedPP.paySingleInvoice(invoiceKey, address(mockUsdc));

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice(invoiceKey, address(mockUsdc));

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.paySingleInvoice(invoiceKey, address(mockUsdc));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceKey);

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
        bytes32 metaInvoiceKey = advancedPP.createMetaInvoice(
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        // make payment
        vm.prank(buyerOne);
        advancedPP.payMetaInvoice(metaInvoiceKey, address(mockWBtc));

        bytes32[] memory invoiceKeys = advancedPP.getSubInvoiceKeyOfMetaInvoice(buyerOne, metaInvoiceKey);

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(invoiceKeys[0]);
        address escrowOne = advancedPP.getEscrowAddress(invOne.seller, invOne.buyer, invoiceKeys[0]);

        assertEq(invOne.state, advancedPP.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(
            IERC20(mockWBtc).balanceOf(invOne.escrow), advancedPP.getTokenValueFromUsd(address(mockWBtc), prices[0])
        );
        assertEq(invOne.paymentToken, address(mockWBtc));

        IAdvancedPaymentProcessor.Invoice memory invTwo = advancedPP.getInvoice(invoiceKeys[1]);
        address escrowTwo = advancedPP.getEscrowAddress(invTwo.seller, invTwo.buyer, invoiceKeys[1]);

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
        bytes32 invoiceKey =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        uint256 currentId = advancedPP.totalUniqueInvoiceCreated();

        vm.prank(sellerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.acceptInvoice(invoiceKey);

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceKey, address(0));

        assertEq(advancedPP.getInvoice(invoiceKey).state, advancedPP.PAID());

        vm.prank(sellerTwo);
        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedSeller.selector);
        advancedPP.acceptInvoice(invoiceKey);

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(invoiceKey);

        assertEq(advancedPP.getInvoice(invoiceKey).state, advancedPP.ACCEPTED());

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

        bytes32 metaInvoiceKey = advancedPP.createMetaInvoice(
            buyerTwo, getInvoiceCreationParams(buyerTwo, sellers, prices, responseTime, disputeWindow)
        );

        uint256 metaInvoiceTokenValue = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.prank(buyerTwo);
        advancedPP.payMetaInvoice{ value: metaInvoiceTokenValue }(metaInvoiceKey, address(0));

        bytes32[] memory keys = advancedPP.getSubInvoiceKeyOfMetaInvoice(buyerTwo, metaInvoiceKey);

        vm.prank(sellerTwo);
        advancedPP.acceptInvoice(keys);

        for (uint256 i = 0; i < keys.length - 1; i++) {
            assertEq(advancedPP.getInvoice(keys[i]).state, advancedPP.ACCEPTED());
        }

        IAdvancedPaymentProcessor.InvoiceCreationParam memory param =
            getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days);
        invoiceKey = advancedPP.createSingleInvoice(param);
        currentId = advancedPP.totalUniqueInvoiceCreated();

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceKey, address(0));

        vm.warp(block.timestamp + 1 + 1 days);

        vm.prank(sellerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceResponseTimeExpired.selector);
        advancedPP.acceptInvoice(invoiceKey);
    }

    function test_sellerCancelInitiatedInvoice() public {
        // single invoice
        uint256 price = 100e8;
        bytes32 invoiceKey =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceKey, address(0));

        uint256 buyersBalanceBeforeCancellation = buyerOne.balance;

        vm.prank(sellerTwo);
        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedSeller.selector);
        advancedPP.cancelInvoice(invoiceKey);

        vm.prank(sellerOne);
        advancedPP.cancelInvoice(invoiceKey);

        vm.prank(sellerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.cancelInvoice(invoiceKey);

        uint256 buyersBalanceAfterCancellation = buyerOne.balance;

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(invoiceKey);
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

        bytes32 metaInvoiceKey = advancedPP.createMetaInvoice(
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        tokenValue = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1] + prices[2]);

        vm.prank(buyerOne);
        advancedPP.payMetaInvoice{ value: tokenValue }(metaInvoiceKey, address(0));
        buyersBalanceBeforeCancellation = buyerOne.balance;

        bytes32[] memory keys = advancedPP.getSubInvoiceKeyOfMetaInvoice(buyerOne, metaInvoiceKey);

        vm.prank(sellerOne);
        advancedPP.cancelInvoice(keys);

        for (uint256 i = 0; i < keys.length; i++) {
            assertEq(advancedPP.getInvoice(keys[i]).state, advancedPP.CANCELED());
        }

        assertApproxEqAbs(buyerOne.balance - buyersBalanceBeforeCancellation, tokenValue, 1);
    }

    function test_invoiceCancelationRequest() public {
        uint256 price = 100e8;
        bytes32 invoiceKey =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        uint256 currentId = advancedPP.totalUniqueInvoiceCreated();
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedBuyer.selector);
        advancedPP.requestCancelation(invoiceKey);

        vm.startPrank(buyerOne);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.requestCancelation(invoiceKey);

        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceKey, address(0));

        advancedPP.requestCancelation(invoiceKey);

        vm.stopPrank();
        assertEq(advancedPP.getInvoice(invoiceKey).state, advancedPP.CANCELATION_REQUESTED());

        invoiceKey = advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        currentId = advancedPP.totalUniqueInvoiceCreated();

        vm.startPrank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceKey, address(0));

        vm.warp(block.timestamp + 1 + 1 days);
        vm.expectRevert(IAdvancedPaymentProcessor.CancelationRequestDeadlinePassed.selector);
        advancedPP.requestCancelation(invoiceKey);

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

        bytes32 metaInvoiceKey = advancedPP.createMetaInvoice(
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        uint256 totalPrice = prices[0] + prices[1] + prices[2];

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), totalPrice);

        vm.startPrank(buyerOne);
        advancedPP.payMetaInvoice{ value: tokenValue }(metaInvoiceKey, address(0));

        bytes32[] memory keys = advancedPP.getSubInvoiceKeyOfMetaInvoice(buyerOne, metaInvoiceKey);
        advancedPP.requestCancelation(keys);

        vm.startPrank(sellerOne);

        bool[] memory accept = new bool[](keys.length);
        accept[0] = true; // + 0.01 ether
        accept[1] = false;
        accept[2] = false;

        uint256 buyersBalanceBefore = buyerOne.balance;
        for (uint256 i = 0; i < keys.length; ++i) {
            advancedPP.handleCancelationRequest(keys[i], accept[i]);
        }

        assertEq(buyerOne.balance, buyersBalanceBefore + advancedPP.getTokenValueFromUsd(address(0), prices[0]));
        assertEq(advancedPP.getInvoice(keys[0]).state, advancedPP.CANCELATION_ACCEPTED());
        assertEq(advancedPP.getInvoice(keys[1]).state, advancedPP.CANCELATION_REJECTED());
        assertEq(advancedPP.getInvoice(keys[2]).state, advancedPP.CANCELATION_REJECTED());
    }

    function test_refundAfterInvoiceExpires() public {
        uint256 price = 100e8;
        bytes32 invoiceKey =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        uint256 id = advancedPP.totalUniqueInvoiceCreated();

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceKey, address(0));

        vm.prank(buyerTwo);
        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedBuyer.selector);
        advancedPP.claimExpiredInvoiceRefunds(invoiceKey);

        vm.startPrank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceStillActive.selector);
        advancedPP.claimExpiredInvoiceRefunds(invoiceKey);

        uint256 balanceBefore = buyerOne.balance;
        vm.warp(block.timestamp + 1 + 1 days);
        advancedPP.claimExpiredInvoiceRefunds(invoiceKey);

        vm.expectRevert(IAdvancedPaymentProcessor.AlreadyRefunded.selector);
        advancedPP.claimExpiredInvoiceRefunds(invoiceKey);
        vm.stopPrank();

        assertEq(advancedPP.getInvoice(invoiceKey).state, advancedPP.REFUNDED());
        assertEq(advancedPP.getInvoice(invoiceKey).amountPaid + balanceBefore, buyerOne.balance);

        invoiceKey = advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        id = advancedPP.totalUniqueInvoiceCreated();

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceKey, address(0));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(invoiceKey);

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.claimExpiredInvoiceRefunds(invoiceKey);
    }

    function test_disputeCreation() public {
        uint256 price = 100e8;
        bytes32 invoiceKey =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.expectRevert(IAdvancedPaymentProcessor.UnauthorizedBuyer.selector);
        advancedPP.createDispute(invoiceKey);

        vm.startPrank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.createDispute(invoiceKey);

        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceKey, address(0));
        vm.stopPrank();

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(invoiceKey);

        vm.warp(block.timestamp + 25 hours);

        vm.startPrank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.DisputeWindowExpired.selector);
        advancedPP.createDispute(invoiceKey);

        vm.warp(block.timestamp - 20 hours);
        advancedPP.createDispute(invoiceKey);
        vm.stopPrank();

        assertEq(advancedPP.getInvoice(invoiceKey).state, advancedPP.DISPUTED());
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

        bytes32 metaInvoiceKey = advancedPP.createMetaInvoice(
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        bytes32[] memory keys = advancedPP.getSubInvoiceKeyOfMetaInvoice(buyerOne, metaInvoiceKey);

        vm.prank(buyerOne);
        advancedPP.payMetaInvoice(metaInvoiceKey, address(mockUsdc));

        for (uint256 i; i < keys.length; i++) {
            bytes32 key = keys[i];
            IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(key);
            vm.prank(inv.seller);
            advancedPP.acceptInvoice(key);

            vm.prank(buyerOne);
            advancedPP.createDispute(key);
        }

        uint8 dismissed = advancedPP.DISPUTE_DISMISSED();
        uint8 resolved = advancedPP.DISPUTE_RESOLVED();

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.NotAuthorized.selector);
        advancedPP.resolveDispute(keys[0], dismissed, 0);

        advancedPP.resolveDispute(keys[0], dismissed, 0);

        advancedPP.resolveDispute(keys[1], resolved, 0);

        assertEq(advancedPP.getInvoice(keys[0]).state, dismissed);
        assertEq(advancedPP.getInvoice(keys[1]).state, resolved);
    }

    function test_settledDispute() public {
        uint256 price = 100e8;
        bytes32 invoiceKey =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(mockUsdc), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice(invoiceKey, address(mockUsdc));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(invoiceKey);

        uint256 basisPoint = advancedPP.BASIS_POINTS();
        uint8 dismissed = advancedPP.DISPUTE_DISMISSED();
        uint8 settled = advancedPP.DISPUTE_SETTLED();
        uint8 accepted = advancedPP.ACCEPTED();
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.resolveDispute(invoiceKey, dismissed, basisPoint);

        vm.prank(buyerOne);
        advancedPP.createDispute(invoiceKey);

        uint256 buyerBalanceBefore = IERC20(mockUsdc).balanceOf(buyerOne);
        uint256 sellerBalanceBefore = IERC20(mockUsdc).balanceOf(sellerOne);

        console.log("balances before", buyerBalanceBefore, sellerBalanceBefore);

        uint256 sellerPercentage = 9000;

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidSellersPayoutShare.selector);
        advancedPP.resolveDispute(invoiceKey, settled, basisPoint + 1);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidDisputeResolution.selector);
        advancedPP.resolveDispute(invoiceKey, accepted, sellerPercentage);

        advancedPP.resolveDispute(invoiceKey, settled, sellerPercentage);

        uint256 buyerShare = advancedPP.applyBasisPoints(tokenValue, advancedPP.BASIS_POINTS() - sellerPercentage);

        uint256 sellerShare = advancedPP.applyBasisPoints(tokenValue, sellerPercentage);
        uint256 fee = advancedPP.applyBasisPoints(sellerShare, FEE);

        console.log("balances after", IERC20(mockUsdc).balanceOf(buyerOne), IERC20(mockUsdc).balanceOf(sellerOne));

        assertEq(advancedPP.getInvoice(invoiceKey).state, advancedPP.DISPUTE_SETTLED());
        assertEq(IERC20(mockUsdc).balanceOf(sellerOne), sellerBalanceBefore + sellerShare - fee);
        assertEq(IERC20(mockUsdc).balanceOf(buyerOne), buyerBalanceBefore + buyerShare);
        assertEq(IERC20(mockUsdc).balanceOf(feeReceiver), fee);
    }

    function test_invoiceRelease() public {
        uint256 price = 100e8;
        bytes32 invoiceKey =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 1 days));
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.releasePayment(invoiceKey);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceKey, address(0));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.releasePayment(invoiceKey);

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(invoiceKey);

        advancedPP.releasePayment(invoiceKey);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.releasePayment(invoiceKey);

        assertEq(advancedPP.getInvoice(invoiceKey).state, advancedPP.RELEASED());
    }
}
