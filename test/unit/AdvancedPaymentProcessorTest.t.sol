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

    error NotAuthorized();
    error HoldPeriodCanNotBeZero();

    function test_Initialization() public view {
        assertEq(advancedPP.getNextInvoiceNonce(), 1);
        assertEq(advancedPP.getNextMetaInvoiceNonce(), 1);
        assertEq(advancedPP.getForwarder(), FORWARDER);
    }

    function test_storageConfig() public {
        vm.startPrank(admin);
        ppStorage.setFeeReceiver(address(0xa0));

        ppStorage.setFeeRate(100);
        ppStorage.setGasThresold(20_000);

        vm.expectRevert(HoldPeriodCanNotBeZero.selector);
        ppStorage.setDefaultHoldPeriod(0);
        ppStorage.setDefaultHoldPeriod(1 days);

        ppStorage.setMarketplaceAddress(address(0xb0));
        vm.stopPrank();

        assertEq(address(0xa0), ppStorage.getFeeReceiver());
        assertEq(100, ppStorage.getFeeRate());
        assertEq(20_000, ppStorage.getGasThreshold());
        assertEq(1 days, ppStorage.getDefaultHoldPeriod());
        assertEq(address(0xb0), ppStorage.getMarketplace());
    }

    function test_updateInvoiceNonce() public {
        vm.expectRevert(NotAuthorized.selector);
        ppStorage.updateInvoiceNonce(1);
    }

    function test_setForwarder() public {
        vm.expectRevert(IAdvancedPaymentProcessor.NotAuthorized.selector);
        advancedPP.setForwarderAddress(address(2));
    }

    function test_setPriceFeed() public {
        vm.expectRevert(IAdvancedPaymentProcessor.NotAuthorized.selector);
        advancedPP.setPriceFeed(address(1), address(2));
    }

    function test_singleInvoiceCreation() public {
        uint256 price = 100e8;

        uint256 invoiceNonce = ppStorage.getNextInvoiceNonce();

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.NotAuthorized.selector);
        advancedPP.createSingleInvoice(getInvoiceCreationParam(invoiceNonce, sellerOne, price));

        vm.expectRevert(IAdvancedPaymentProcessor.PriceCannotBeZero.selector);
        advancedPP.createSingleInvoice(getInvoiceCreationParam(invoiceNonce, sellerOne, 0));

        vm.expectRevert(IAdvancedPaymentProcessor.PriceIsTooLow.selector);
        advancedPP.createSingleInvoice(getInvoiceCreationParam(invoiceNonce, sellerOne, 1));

        uint216 invoiceId = advancedPP.createSingleInvoice(getInvoiceCreationParam(invoiceNonce, sellerOne, price));

        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceAlreadyExists.selector);
        advancedPP.createSingleInvoice(getInvoiceCreationParam(invoiceNonce, sellerOne, price));

        uint256 nextInvoiceNonce = advancedPP.getNextInvoiceNonce();
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.price, price);
        assertEq(inv.seller, sellerOne);
        assertEq(inv.createdAt, block.timestamp);
        // assertEq(inv.invoiceId, uint256(0));
        assertEq(inv.invoiceNonce, advancedPP.totalUniqueInvoiceCreated());
        assertEq(nextInvoiceNonce, 2);
    }

    function test_createMultipleInvoiceWithPayment() public {
        // set up
        uint256 invoiceNonce = ppStorage.getNextInvoiceNonce();

        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory keys) =
            getInvoiceCreationParams(invoiceNonce, sellers, prices);

        // create invoice
        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);

        uint256 upper = advancedPP.getNextInvoiceNonce() - 1;

        IAdvancedPaymentProcessor.MetaInvoice memory metaInv = advancedPP.getMetaInvoice(metaInvoiceId);

        // assertion

        for (uint256 i = 0; i < keys.length; i++) {
            IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(keys[i]);

            assertEq(inv.price, prices[i]);
            assertEq(inv.seller, sellers[i]);
            assertEq(inv.createdAt, block.timestamp);
            assertEq(inv.metaInvoiceId, metaInvoiceId);
            // assertEq(inv.invoiceNonce, invoiceNonce + i);
        }

        assertEq(advancedPP.getNextInvoiceNonce(), upper + 1);
        assertEq(metaInv.price, prices[0] + prices[1]);
    }

    function test_nativeTokenPaymentForSingleInvoice() public {
        uint256 price = 100e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));

        vm.startPrank(buyerOne);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidPaymentToken.selector);
        advancedPP.payInvoice(invoiceId, address(12));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidNativePayment.selector);
        advancedPP.payInvoice{ value: 0.001 ether }(invoiceId, address(0));
        vm.stopPrank();

        uint256 amountInToken = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(sellerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.BuyerCannotBeSeller.selector);
        advancedPP.payInvoice{ value: amountInToken }(invoiceId, address(0));

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: amountInToken }(invoiceId, address(0));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

        assertEq(inv.escrow.balance, amountInToken);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, advancedPP.PAID());

        invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));
    }

    function test_nativeTokenPaymentForMetaInvoice() public {
        // set up
        uint256 invoiceNonce = advancedPP.getNextInvoiceNonce();

        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 150e8;
        prices[1] = 250e8;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(invoiceNonce, sellers, prices);

        // create meta invoice
        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);

        uint256 tokenAmount = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.expectRevert(IAdvancedPaymentProcessor.InvoiceDoesNotExist.selector);
        advancedPP.payMetaInvoice{ value: 0.03 ether }(0, address(0));

        vm.startPrank(buyerOne);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidPaymentToken.selector);
        advancedPP.payMetaInvoice(metaInvoiceId, address(12));

        advancedPP.payMetaInvoice{ value: tokenAmount }(metaInvoiceId, address(0));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.payMetaInvoice{ value: tokenAmount }(metaInvoiceId, address(0));

        vm.stopPrank();

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(invoiceIds[0]);
        address escrowOne = advancedPP.getEscrowAddress(invOne.seller, invOne.buyer, invoiceIds[0]);

        assertEq(invOne.state, advancedPP.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(invOne.escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[0]));
        assertEq(invOne.paymentToken, address(0));

        IAdvancedPaymentProcessor.Invoice memory invTwo = advancedPP.getInvoice(invoiceIds[1]);
        address escrowTwo = advancedPP.getEscrowAddress(invTwo.seller, invTwo.buyer, invoiceIds[1]);

        assertEq(invTwo.state, advancedPP.PAID());
        assertEq(invTwo.escrow, escrowTwo);
        assertEq(invTwo.escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[1]));
        assertEq(invTwo.paymentToken, address(0));
    }

    function test_payMetaInvoice_revertsOnIncorrectMsgValue() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 100e8;
        prices[1] = 200e8;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param,) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);
        uint256 expected = advancedPP.getMetaInvoice(metaInvoiceId).price;

        vm.prank(buyerOne);
        vm.expectRevert();
        advancedPP.payMetaInvoice{ value: expected - 1 }(metaInvoiceId, address(0));
    }

    function test_erc20PaymentForSingleInvoice() public {
        uint256 price = 100e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));

        vm.prank(buyerOne);
        advancedPP.payInvoice(invoiceId, address(mockUsdc));

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.payInvoice(invoiceId, address(mockUsdc));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

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

        // create meta invoice

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);

        // make payment
        vm.prank(buyerOne);
        advancedPP.payMetaInvoice(metaInvoiceId, address(mockWBtc));

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(invoiceIds[0]);
        address escrowOne = advancedPP.getEscrowAddress(invOne.seller, invOne.buyer, invoiceIds[0]);

        assertEq(invOne.state, advancedPP.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(
            IERC20(mockWBtc).balanceOf(invOne.escrow), advancedPP.getTokenValueFromUsd(address(mockWBtc), prices[0])
        );
        assertEq(invOne.paymentToken, address(mockWBtc));

        IAdvancedPaymentProcessor.Invoice memory invTwo = advancedPP.getInvoice(invoiceIds[1]);
        address escrowTwo = advancedPP.getEscrowAddress(invTwo.seller, invTwo.buyer, invoiceIds[1]);

        assertEq(invTwo.state, advancedPP.PAID());
        assertEq(invTwo.escrow, escrowTwo);
        assertEq(
            IERC20(mockWBtc).balanceOf(invTwo.escrow), advancedPP.getTokenValueFromUsd(address(mockWBtc), prices[1])
        );
        assertEq(invTwo.paymentToken, address(mockWBtc));
    }

    function test_cancel_invoice() public {
        // single invoice
        uint256 price = 100e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));

        advancedPP.cancelInvoice(invoiceId);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.cancelInvoice(invoiceId);

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(invoiceId);
        assertEq(invOne.state, advancedPP.CANCELED());

        // meta invoice

        address[] memory sellers = new address[](3);
        sellers[0] = sellerOne;
        sellers[1] = sellerOne;
        sellers[2] = sellerOne;

        uint256[] memory prices = new uint256[](3);
        prices[0] = price;
        prices[1] = 500e8;
        prices[2] = 1400e8;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        advancedPP.createMetaInvoice(param);

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            advancedPP.cancelInvoice(invoiceIds[i]);
            assertEq(advancedPP.getInvoice(invoiceIds[i]).state, advancedPP.CANCELED());
        }

        vm.stopPrank();
    }

    function test_disputeCreation() public {
        uint256 price = 100e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(sellerOne);
        vm.expectRevert(NotAuthorized.selector);
        advancedPP.createDispute(invoiceId);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        vm.warp(block.timestamp + 25 hours);

        advancedPP.createDispute(invoiceId);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.createDispute(invoiceId);

        assertEq(advancedPP.getInvoice(invoiceId).state, advancedPP.DISPUTED());
    }

    function test_dismissedDispute() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);

        vm.prank(buyerOne);
        advancedPP.payMetaInvoice(metaInvoiceId, address(mockUsdc));

        for (uint256 i; i < invoiceIds.length; i++) {
            uint216 key = invoiceIds[i];

            advancedPP.createDispute(key);
        }

        uint8 dismissed = advancedPP.DISPUTE_DISMISSED();

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.NotAuthorized.selector);
        advancedPP.handleDispute(invoiceIds[0], dismissed, 0);

        advancedPP.handleDispute(invoiceIds[0], dismissed, 0);

        assertEq(advancedPP.getInvoice(invoiceIds[0]).state, dismissed);
    }

    function test_settledDispute() public {
        uint256 price = 100e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(mockUsdc), price);

        vm.prank(buyerOne);
        advancedPP.payInvoice(invoiceId, address(mockUsdc));

        uint256 basisPoint = advancedPP.BASIS_POINTS();
        uint8 dismissed = advancedPP.DISPUTE_DISMISSED();
        uint8 settled = advancedPP.DISPUTE_SETTLED();
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.handleDispute(invoiceId, dismissed, basisPoint);

        advancedPP.createDispute(invoiceId);

        uint256 buyerBalanceBefore = IERC20(mockUsdc).balanceOf(buyerOne);
        uint256 sellerBalanceBefore = IERC20(mockUsdc).balanceOf(sellerOne);

        console.log("balances before", buyerBalanceBefore, sellerBalanceBefore);

        uint256 sellerPercentage = 9000;

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidSellersPayoutShare.selector);
        advancedPP.handleDispute(invoiceId, settled, basisPoint + 1);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidDisputeResolution.selector);
        advancedPP.handleDispute(invoiceId, 12, sellerPercentage);

        advancedPP.handleDispute(invoiceId, settled, sellerPercentage);

        uint256 buyerShare = advancedPP.applyBasisPoints(tokenValue, advancedPP.BASIS_POINTS() - sellerPercentage);

        uint256 sellerShare = advancedPP.applyBasisPoints(tokenValue, sellerPercentage);
        uint256 fee = advancedPP.applyBasisPoints(sellerShare, FEE_RATE);

        console.log("balances after", IERC20(mockUsdc).balanceOf(buyerOne), IERC20(mockUsdc).balanceOf(sellerOne));

        assertEq(advancedPP.getInvoice(invoiceId).state, advancedPP.DISPUTE_SETTLED());
        assertEq(IERC20(mockUsdc).balanceOf(sellerOne), sellerBalanceBefore + sellerShare - fee);
        assertEq(IERC20(mockUsdc).balanceOf(buyerOne), buyerBalanceBefore + buyerShare);
        assertEq(IERC20(mockUsdc).balanceOf(feeReceiver), fee);
    }

    function test_resolveDispute() public {
        uint256 price = 100e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));

        vm.prank(buyerOne);
        advancedPP.payInvoice(invoiceId, address(mockUsdc));

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.resolveDispute(invoiceId);

        advancedPP.createDispute(invoiceId);

        advancedPP.resolveDispute(invoiceId);
    }

    function test_invoiceRelease() public {
        uint256 price = 100e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.release(invoiceId);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        vm.warp(block.timestamp + 1 days);
        advancedPP.release(invoiceId);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.release(invoiceId);

        assertEq(advancedPP.getInvoice(invoiceId).state, advancedPP.RELEASED());
    }

    function test_releasePayment() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerOne;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 100e8;
        prices[1] = 100e8;

        uint32[] memory responseTime = new uint32[](2);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;

        uint32[] memory disputeWindow = new uint32[](2);
        disputeWindow[0] = 1 days;
        disputeWindow[1] = 4 days;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);

        uint256 tokenAmount = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        uint256 balanceBefore = buyerTwo.balance;

        vm.prank(buyerTwo);
        advancedPP.payMetaInvoice{ value: tokenAmount }(metaInvoiceId, address(0));

        console.log("length", advancedPP.getItems().length, invoiceIds.length);

        vm.warp(block.timestamp + 1 days);
        for (uint256 i = 0; i < invoiceIds.length; i++) {
            advancedPP.release(invoiceIds[i]);
        }

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            assertEq(advancedPP.getInvoice(invoiceIds[i]).state, advancedPP.RELEASED());
        }

        assertApproxEqAbs(balanceBefore - tokenAmount, buyerTwo.balance, 1);
    }

    function test_release_after_cancelation_for_meta_invoice() public {
        address[] memory sellers = new address[](3);
        sellers[0] = sellerOne;
        sellers[1] = sellerOne;
        sellers[2] = sellerOne;

        uint256[] memory prices = new uint256[](3);
        prices[0] = 100e8;
        prices[1] = 200e8;
        prices[2] = 200e8;

        uint32[] memory responseTime = new uint32[](3);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;
        responseTime[2] = 1 days;

        uint32[] memory disputeWindow = new uint32[](3);
        disputeWindow[0] = 1 days;
        disputeWindow[1] = 4 days;
        disputeWindow[2] = 3 days;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);

        advancedPP.cancelInvoice(invoiceIds[0]);

        uint256 tokenAmount = advancedPP.getTokenValueFromUsd(address(0), prices[1] + prices[2]);
        uint256 balanceBefore = buyerOne.balance;

        vm.prank(buyerOne);
        advancedPP.payMetaInvoice{ value: tokenAmount }(metaInvoiceId, address(0));

        assertEq(balanceBefore - tokenAmount, buyerOne.balance);
    }

    function test_fullRefund() public {
        uint256 price = 1500e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);
        console.log(tokenValue);

        uint256 refundShare = 10_000;

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.refund(invoiceId, refundShare);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));
        uint256 buyerBalance = buyerOne.balance;
        console.log(buyerBalance);

        vm.expectRevert(IAdvancedPaymentProcessor.InsufficientBalance.selector);
        advancedPP.refund(invoiceId, refundShare + 1);

        advancedPP.refund(invoiceId, refundShare);

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.balance, 0);

        assertEq(buyerOne.balance, buyerBalance + tokenValue);
    }

    function test_refund_and_release() public {
        uint256 price = 1500e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        uint256 buyerBalance = buyerOne.balance;

        uint256 refundableAmount = (tokenValue * 67) / 100;
        uint256 releaseableAmount = tokenValue - refundableAmount;

        uint256 refundShare = 6700;

        advancedPP.refund(invoiceId, refundShare);

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.balance, releaseableAmount);
        assertEq(buyerOne.balance, buyerBalance + refundableAmount);

        releaseableAmount -= (releaseableAmount * ppStorage.getFeeRate()) / advancedPP.BASIS_POINTS();

        uint256 sellerBalance = sellerOne.balance;

        vm.warp(block.timestamp + 1 days);
        advancedPP.release(invoiceId);
        assertEq(sellerBalance + releaseableAmount, sellerOne.balance);
    }

    function test_MetaInvoiceTotalPrice() public {
        address[] memory sellers = new address[](3);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;
        sellers[2] = sellerTwo;

        uint256[] memory prices = new uint256[](3);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;
        prices[2] = 0.02 ether;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param,) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);
        IAdvancedPaymentProcessor.MetaInvoice memory metaInv = advancedPP.getMetaInvoice(metaInvoiceId);
        assertEq(metaInv.price, prices[0] + prices[1] + prices[2]);
    }

    function test_automatedReleaseViaUpkeep() public {
        address[] memory sellers = new address[](3);
        sellers[0] = sellerOne;
        sellers[1] = sellerOne;
        sellers[2] = sellerTwo;

        uint256[] memory prices = new uint256[](3);
        prices[0] = 100e8;
        prices[1] = 100e8;
        prices[2] = 300e8;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint256 length = invoiceIds.length - 1;

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);

        uint256 tokenAmount = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1] + prices[2]);

        vm.prank(admin);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.setInvoiceReleaseTime(invoiceIds[length], 3 days);

        vm.prank(buyerTwo);
        advancedPP.payMetaInvoice{ value: tokenAmount }(metaInvoiceId, address(0));

        (bool upkeepNeeded,) = advancedPP.checkUpkeep("");
        assertFalse(upkeepNeeded);

        vm.warp(block.timestamp + 1 days);

        (upkeepNeeded,) = advancedPP.checkUpkeep("");
        assertTrue(upkeepNeeded);

        vm.expectRevert(IAdvancedPaymentProcessor.NotAuthorized.selector);
        advancedPP.setInvoiceReleaseTime(invoiceIds[length], 3 days);

        vm.prank(admin);
        advancedPP.setInvoiceReleaseTime(invoiceIds[length], 3 days);

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.NotAuthorized.selector);
        advancedPP.performUpkeep("");

        vm.prank(admin);
        advancedPP.performUpkeep("");

        for (uint256 i = 0; i < length; i++) {
            assertEq(advancedPP.getInvoice(invoiceIds[i]).state, advancedPP.RELEASED());
        }

        assertEq(advancedPP.getInvoice(invoiceIds[length]).state, advancedPP.PAID());

        vm.warp(block.timestamp + 3 days);
        vm.prank(admin);
        advancedPP.performUpkeep("");

        assertEq(advancedPP.getInvoice(invoiceIds[length]).state, advancedPP.RELEASED());
    }

    function test_automatedReleaseAfterDispute() public {
        address[] memory sellers = new address[](4);
        sellers[0] = sellerOne;
        sellers[1] = sellerOne;
        sellers[2] = sellerTwo;
        sellers[3] = sellerTwo;

        uint256[] memory prices = new uint256[](4);
        prices[0] = 100e8;
        prices[1] = 100e8;
        prices[2] = 300e8;
        prices[3] = 300e8;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint256 length = invoiceIds.length;

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);

        uint256 tokenAmount = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1] + prices[2] + prices[3]);

        vm.prank(buyerTwo);
        advancedPP.payMetaInvoice{ value: tokenAmount }(metaInvoiceId, address(0));

        for (uint256 k = 0; k < advancedPP.getItems().length; k++) {
            console.log("invoice", advancedPP.getItems()[k]);
        }
        console.log("");

        advancedPP.createDispute(advancedPP.getItems()[3]);

        vm.warp(block.timestamp + 3 days);

        vm.prank(admin);
        advancedPP.performUpkeep("");

        for (uint256 i = 0; i < length; i++) {
            console.log(invoiceIds[i], advancedPP.getInvoice(invoiceIds[i]).state);
        }
    }
}
