// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";
import { IOracleManager } from "../../src/interface/IOracleManager.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

import { AdvancedPaymentProcessorSetUp } from "../utils/AdvancedPaymentProcessorSetUp.sol";

import {
    getInvoiceCreationParam,
    getInvoiceCreationParams,
    applyBasisPoints,
    getEscrowAddress
} from "../utils/InvoiceTestHelpers.sol";

import {
    CREATED,
    PAID,
    CANCELED,
    DISPUTED,
    DISPUTE_RESOLVED,
    DISPUTE_DISMISSED,
    DISPUTE_SETTLED,
    RELEASED,
    BASIS_POINTS
} from "src/constants/Advanced.sol";

import { SafeCastLib } from "solady/utils/SafeCastLib.sol";

contract AdvancedPaymentProcessorTest is AdvancedPaymentProcessorSetUp {
    using { getEscrowAddress } for AdvancedPaymentProcessor;
    using SafeCastLib for uint256;

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
        ppStorage.setGasThreshold(20_000);

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
        IOracleManager oracleManager = advancedPP.oracle();

        vm.expectRevert(IOracleManager.UnsupportedToken.selector);
        oracleManager.getUsdPerToken(address(1));

        vm.prank(admin);
        oracle.setPriceFeed(address(1), IOracleManager.PriceFeedConfig({ aggregator: address(2), heartbeat: 1 hours }));

        vm.expectRevert(IOracleManager.UnsupportedToken.selector);
        oracleManager.getUsdPerToken(address(2));
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
        assertEq(inv.state, CREATED);
        assertEq(inv.price, price);
        assertEq(inv.seller, sellerOne);
        assertEq(inv.createdAt, block.timestamp);
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

        vm.expectRevert(IAdvancedPaymentProcessor.UnsupportedToken.selector);
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
        assertEq(inv.state, PAID);

        invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));
    }

    function test_nativeTokenPaymentForMetaInvoice() public {
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
        advancedPP.payMetaInvoiceWithValue{ value: 0.03 ether }(0);

        vm.startPrank(buyerOne);

        vm.expectRevert(IAdvancedPaymentProcessor.UnsupportedToken.selector);
        advancedPP.payMetaInvoice(metaInvoiceId, address(12));

        advancedPP.payMetaInvoiceWithValue{ value: tokenAmount }(metaInvoiceId);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.payMetaInvoiceWithValue{ value: tokenAmount }(metaInvoiceId);

        vm.stopPrank();

        IAdvancedPaymentProcessor.Invoice memory invOne = advancedPP.getInvoice(invoiceIds[0]);
        address escrowOne = advancedPP.getEscrowAddress(invOne.seller, invOne.buyer, invoiceIds[0]);

        assertEq(invOne.state, PAID);
        assertEq(invOne.escrow, escrowOne);
        assertApproxEqAbs(invOne.escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[0]), 1);
        assertEq(invOne.paymentToken, address(0));

        IAdvancedPaymentProcessor.Invoice memory invTwo = advancedPP.getInvoice(invoiceIds[1]);
        address escrowTwo = advancedPP.getEscrowAddress(invTwo.seller, invTwo.buyer, invoiceIds[1]);

        assertEq(invTwo.state, PAID);
        assertEq(invTwo.escrow, escrowTwo);
        assertApproxEqAbs(invTwo.escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[1]), 1);
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
        advancedPP.payMetaInvoiceWithValue{ value: expected - 1 }(metaInvoiceId);
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
        assertEq(inv.state, PAID);
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

        assertEq(invOne.state, PAID);
        assertEq(invOne.escrow, escrowOne);
        assertApproxEqAbs(
            IERC20(mockWBtc).balanceOf(invOne.escrow), advancedPP.getTokenValueFromUsd(address(mockWBtc), prices[0]), 1
        );
        assertEq(invOne.paymentToken, address(mockWBtc));

        IAdvancedPaymentProcessor.Invoice memory invTwo = advancedPP.getInvoice(invoiceIds[1]);
        address escrowTwo = advancedPP.getEscrowAddress(invTwo.seller, invTwo.buyer, invoiceIds[1]);

        assertEq(invTwo.state, PAID);
        assertEq(invTwo.escrow, escrowTwo);
        assertApproxEqAbs(
            IERC20(mockWBtc).balanceOf(invTwo.escrow), advancedPP.getTokenValueFromUsd(address(mockWBtc), prices[1]), 1
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
        assertEq(invOne.state, CANCELED);

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
            assertEq(advancedPP.getInvoice(invoiceIds[i]).state, CANCELED);
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

        assertEq(advancedPP.getInvoice(invoiceId).state, DISPUTED);
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

        uint8 dismissed = DISPUTE_DISMISSED;

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

        uint256 basisPoint = BASIS_POINTS;
        uint8 dismissed = DISPUTE_DISMISSED;
        uint8 settled = DISPUTE_SETTLED;
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

        uint256 buyerShare = applyBasisPoints(tokenValue, BASIS_POINTS - sellerPercentage);

        uint256 sellerShare = applyBasisPoints(tokenValue, sellerPercentage);
        uint256 fee = applyBasisPoints(sellerShare, FEE_RATE);

        console.log("balances after", IERC20(mockUsdc).balanceOf(buyerOne), IERC20(mockUsdc).balanceOf(sellerOne));

        assertEq(advancedPP.getInvoice(invoiceId).state, DISPUTE_SETTLED);
        assertEq(IERC20(mockUsdc).balanceOf(sellerOne), sellerBalanceBefore + sellerShare - fee);
        assertEq(IERC20(mockUsdc).balanceOf(buyerOne), buyerBalanceBefore + buyerShare);
        assertEq(IERC20(mockUsdc).balanceOf(feeReceiver), fee);
        assertEq(IERC20(mockUsdc).balanceOf(advancedPP.getInvoice(invoiceId).escrow), 0);
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

        assertEq(advancedPP.getInvoice(invoiceId).state, RELEASED);
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
        advancedPP.payMetaInvoiceWithValue{ value: tokenAmount }(metaInvoiceId);

        vm.warp(block.timestamp + 1 days);
        advancedPP.release(invoiceIds[0]);
        advancedPP.release(invoiceIds[1]);

        assertEq(advancedPP.getInvoice(invoiceIds[0]).state, RELEASED);
        assertEq(advancedPP.getInvoice(invoiceIds[1]).state, RELEASED);

        assertApproxEqAbs(balanceBefore - tokenAmount, buyerTwo.balance, 1);

        assertEq(advancedPP.getInvoice(invoiceIds[0]).escrow.balance, 0);
        assertEq(advancedPP.getInvoice(invoiceIds[1]).escrow.balance, 0);
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
        advancedPP.payMetaInvoiceWithValue{ value: tokenAmount }(metaInvoiceId);

        assertApproxEqAbs(balanceBefore - tokenAmount, buyerOne.balance, 1);
    }

    function test_fullRefund() public {
        uint256 price = 1500e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        uint256 refundShare = 10_000;

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.refund(invoiceId, refundShare);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));
        uint256 buyerBalance = buyerOne.balance;

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

        releaseableAmount -= (releaseableAmount * ppStorage.getFeeRate()) / BASIS_POINTS;

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
        advancedPP.payMetaInvoiceWithValue{ value: tokenAmount }(metaInvoiceId);

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
            assertEq(advancedPP.getInvoice(invoiceIds[i]).state, RELEASED);
        }

        assertEq(advancedPP.getInvoice(invoiceIds[length]).state, PAID);

        vm.warp(block.timestamp + 3 days);
        vm.prank(admin);
        advancedPP.performUpkeep("");

        assertEq(advancedPP.getInvoice(invoiceIds[length]).state, RELEASED);
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

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param,) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);

        uint256 tokenAmount = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1] + prices[2] + prices[3]);

        vm.prank(buyerTwo);
        advancedPP.payMetaInvoiceWithValue{ value: tokenAmount }(metaInvoiceId);

        for (uint256 k = 0; k < advancedPP.getItems().length; k++) {
            console.log("invoice", advancedPP.getItems()[k]);
        }
        console.log("");

        advancedPP.createDispute(advancedPP.getItems()[3]);

        vm.warp(block.timestamp + 3 days);

        vm.prank(admin);
        advancedPP.performUpkeep("");
    }

    function test_customEscrowHoldPeriodIsUsedWhenSet() public {
        uint256 price = 100e8;
        uint32 customHold = 7 days;

        IAdvancedPaymentProcessor.InvoiceCreationParam memory param =
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price);
        param.escrowHoldPeriod = customHold;

        uint216 invoiceId = advancedPP.createSingleInvoice(param);

        assertEq(advancedPP.getInvoice(invoiceId).escrowHoldPeriod, customHold);

        uint256 amountInToken = advancedPP.getTokenValueFromUsd(address(0), price);
        uint256 paidAt = block.timestamp;

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: amountInToken }(invoiceId, address(0));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

        assertEq(inv.releaseAt, paidAt + customHold);
        assertEq(inv.state, PAID);
    }

    function test_defaultHoldPeriodUsedWhenEscrowHoldPeriodIsZero() public {
        uint256 price = 100e8;

        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));

        assertEq(advancedPP.getInvoice(invoiceId).escrowHoldPeriod, 0);

        uint256 amountInToken = advancedPP.getTokenValueFromUsd(address(0), price);
        uint256 paidAt = block.timestamp;

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: amountInToken }(invoiceId, address(0));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

        assertEq(inv.releaseAt, paidAt + ppStorage.getDefaultHoldPeriod());
    }

    function test_customEscrowHoldPeriod_cannotReleaseBeforeIt() public {
        uint256 price = 100e8;
        uint32 customHold = 7 days;

        IAdvancedPaymentProcessor.InvoiceCreationParam memory param =
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price);
        param.escrowHoldPeriod = customHold;

        uint216 invoiceId = advancedPP.createSingleInvoice(param);

        uint256 amountInToken = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: amountInToken }(invoiceId, address(0));

        // warp past default hold (1 day) but not past custom hold (7 days)
        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);

        vm.expectRevert(IAdvancedPaymentProcessor.InvalidInvoiceState.selector);
        advancedPP.release(invoiceId);
    }

    function test_customEscrowHoldPeriod_canReleaseAfterIt() public {
        uint256 price = 100e8;
        uint32 customHold = 7 days;

        IAdvancedPaymentProcessor.InvoiceCreationParam memory param =
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price);
        param.escrowHoldPeriod = customHold;

        uint216 invoiceId = advancedPP.createSingleInvoice(param);

        uint256 amountInToken = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: amountInToken }(invoiceId, address(0));

        vm.warp(block.timestamp + customHold + 1);
        advancedPP.release(invoiceId);

        assertEq(advancedPP.getInvoice(invoiceId).state, RELEASED);
    }

    function test_customEscrowHoldPeriodForMetaInvoice() public {
        uint32 customHold = 14 days;

        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 100e8;
        prices[1] = 200e8;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory params, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        params[0].escrowHoldPeriod = customHold;
        params[1].escrowHoldPeriod = customHold;

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(params);

        uint256 totalTokenValue = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);
        uint256 paidAt = block.timestamp;

        vm.prank(buyerOne);
        advancedPP.payMetaInvoiceWithValue{ value: totalTokenValue }(metaInvoiceId);

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceIds[i]);
            assertEq(inv.releaseAt, paidAt + customHold);
            assertEq(inv.state, PAID);
        }
    }

    function test_createSingleInvoice(uint256 _price) public {
        _price = bound(_price, 1e8, type(uint128).max);

        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price));

        uint256 nextInvoiceNonce = advancedPP.getNextInvoiceNonce();
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.price, _price);
        assertEq(inv.seller, sellerOne);
        assertEq(nextInvoiceNonce, 2);
    }

    function test_payInvoice(uint256 _price) public {
        _price = bound(_price, 1e8, 100e8);

        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerTwo, _price));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerTwo);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

        assertEq(inv.escrow.balance, tokenValue);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, PAID);
    }

    function test_createMetaInvoice(
        uint256 _priceO,
        uint256 _priceT,
        uint256 _timeBeforeCancelation,
        uint256 _releaseWindow
    ) public {
        _timeBeforeCancelation = bound(_timeBeforeCancelation, 1 days, type(uint32).max);
        _releaseWindow = bound(_releaseWindow, 1 days, type(uint32).max);

        _priceO = bound(_priceO, 1e8, 100e8);
        _priceT = bound(_priceT, 1e8, 100e8);

        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = _priceO;
        prices[1] = _priceT;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param,) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);

        uint256 id = advancedPP.totalMetaInvoiceCreated();

        IAdvancedPaymentProcessor.MetaInvoice memory metaInv = advancedPP.getMetaInvoice(metaInvoiceId);

        assertEq(id, 1);
        assertEq(metaInv.price, _priceO + _priceT);
    }

    function test_payMetaInvoice(
        uint256 _priceO,
        uint256 _priceT,
        uint256 _timeBeforeCancelation,
        uint256 _releaseWindow
    ) public {
        _timeBeforeCancelation = bound(_timeBeforeCancelation, 1 days, type(uint32).max);
        _releaseWindow = bound(_releaseWindow, 1 days, type(uint32).max);

        _priceO = bound(_priceO, 1e8, 100e8);
        _priceT = bound(_priceT, 1e8, 100e8);

        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = _priceO;
        prices[1] = _priceT;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param,) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 invoiceId = advancedPP.createMetaInvoice(param);

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(mockUsdc), _priceO + _priceT);

        _executePayment(buyerOne, invoiceId, tokenValue);

        assertApproxEqAbs(mockUsdc.allowance(buyerOne, address(advancedPP)), 0, 2);
    }

    function test_releasePayment(uint256 _price, uint256 _sellerShare) public {
        _price = bound(_price, 1e8, 100e8);
        _sellerShare = bound(_sellerShare, 0, BASIS_POINTS);

        uint216 invoiceId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(advancedPP.getNextInvoiceNonce(), sellerOne, _price)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        uint256 balanceBefore = sellerOne.balance;
        vm.warp(block.timestamp + 1 days);
        advancedPP.release(invoiceId);

        uint256 expectedValue = tokenValue - ((tokenValue * FEE_RATE) / BASIS_POINTS);

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, RELEASED);
        assertEq(sellerOne.balance, expectedValue + balanceBefore);
    }

    function test_handleDispute(uint256 _price, uint256 _resolution, uint256 _sellerShare) public {
        _price = bound(_price, 1e8, 100e8);
        _resolution = bound(_resolution, DISPUTE_DISMISSED, DISPUTE_SETTLED);
        _sellerShare = bound(_sellerShare, 0, BASIS_POINTS);

        uint216 invoiceId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(advancedPP.getNextInvoiceNonce(), sellerOne, _price)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        advancedPP.createDispute(invoiceId);

        advancedPP.handleDispute(invoiceId, _resolution.toUint8(), _sellerShare);

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, _resolution);
    }

    function test_getTokenValueFromUsd(uint256 _price) public view {
        _price = bound(_price, 1e8, type(uint256).max / 1e18);
        uint256 val = advancedPP.getTokenValueFromUsd(address(0), _price);
        assertGt(val, 0);
    }

    function test_payInvoiceWithERC20(uint256 _price) public {
        _price = bound(_price, 1e8, 100e8);

        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(mockUsdc), _price);

        vm.prank(buyerOne);
        advancedPP.payInvoice(invoiceId, address(mockUsdc));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, PAID);
        assertEq(inv.buyer, buyerOne);
        assertEq(inv.paymentToken, address(mockUsdc));
        assertEq(inv.amountPaid, tokenValue);
        assertEq(inv.balance, tokenValue);
        assertEq(mockUsdc.balanceOf(inv.escrow), tokenValue);
    }

    function test_payMetaInvoiceWithValue(uint256 _priceO, uint256 _priceT) public {
        _priceO = bound(_priceO, 1e8, 100e8);
        _priceT = bound(_priceT, 1e8, 100e8);

        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = _priceO;
        prices[1] = _priceT;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory subInvoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);
        uint256 totalEth = advancedPP.getTokenValueFromUsd(address(0), _priceO + _priceT);

        vm.prank(buyerOne);
        advancedPP.payMetaInvoiceWithValue{ value: totalEth }(metaInvoiceId);

        IAdvancedPaymentProcessor.Invoice memory inv0 = advancedPP.getInvoice(subInvoiceIds[0]);
        IAdvancedPaymentProcessor.Invoice memory inv1 = advancedPP.getInvoice(subInvoiceIds[1]);

        assertEq(inv0.state, PAID);
        assertEq(inv1.state, PAID);
        assertEq(inv0.buyer, buyerOne);
        assertEq(inv1.buyer, buyerOne);
        assertLe(inv0.escrow.balance + inv1.escrow.balance, totalEth);
    }

    function test_partialRefund(uint256 _price, uint256 _refundShare) public {
        _price = bound(_price, 1e8, 100e8);
        _refundShare = bound(_refundShare, 1, BASIS_POINTS - 1); // partial, not full

        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        uint256 expectedRefund = (tokenValue * _refundShare) / BASIS_POINTS;
        uint256 buyerBefore = buyerOne.balance;

        advancedPP.refund(invoiceId, _refundShare);

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, PAID);
        assertEq(inv.balance, tokenValue - expectedRefund);
        assertEq(buyerOne.balance, buyerBefore + expectedRefund);
    }

    function test_disputeSettledFundDistribution(uint256 _price, uint256 _sellerShare) public {
        _price = bound(_price, 1e8, 100e8);
        _sellerShare = bound(_sellerShare, 0, BASIS_POINTS);

        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        advancedPP.createDispute(invoiceId);

        uint256 sellerBefore = sellerOne.balance;
        uint256 buyerBefore = buyerOne.balance;
        uint256 feeReceiverBefore = feeReceiver.balance;

        advancedPP.handleDispute(invoiceId, uint8(DISPUTE_SETTLED), _sellerShare);

        uint256 buyerRefund = (tokenValue * (BASIS_POINTS - _sellerShare)) / BASIS_POINTS;
        uint256 sellerGross = tokenValue - buyerRefund;
        uint256 fee = (sellerGross * FEE_RATE) / BASIS_POINTS;

        assertEq(sellerOne.balance, sellerBefore + sellerGross - fee);
        assertEq(buyerOne.balance, buyerBefore + buyerRefund);
        assertEq(feeReceiver.balance, feeReceiverBefore + fee);

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, DISPUTE_SETTLED);
        assertEq(inv.balance, 0);
        assertEq(inv.escrow.balance, 0);
    }

    function test_setInvoiceReleaseTime(uint256 _price, uint256 _holdPeriod) public {
        _price = bound(_price, 1e8, 100e8);
        _holdPeriod = bound(_holdPeriod, 1, type(uint32).max / 2);

        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        uint256 expectedReleaseAt = block.timestamp + _holdPeriod;

        vm.prank(admin);
        advancedPP.setInvoiceReleaseTime(invoiceId, _holdPeriod);

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.releaseAt, expectedReleaseAt);

        vm.warp(expectedReleaseAt + 1);
        advancedPP.release(invoiceId);

        inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, RELEASED);
    }

    function test_payInvoiceErc20RejectsNonZeroMsgValue(uint256 _price, uint256 _wrongValue) public {
        _price = bound(_price, 1e8, 100e8);
        _wrongValue = bound(_wrongValue, 1, 100 ether);

        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price));

        vm.prank(buyerOne);
        vm.expectRevert(IAdvancedPaymentProcessor.InvalidNativePayment.selector);
        advancedPP.payInvoice{ value: _wrongValue }(invoiceId, address(mockUsdc));
    }

    function test_resolveDisputeAndRelease(uint256 _price) public {
        _price = bound(_price, 1e8, 100e8);

        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        uint256 originalReleaseAt = inv.releaseAt;

        advancedPP.createDispute(invoiceId);
        advancedPP.resolveDispute(invoiceId);

        inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, DISPUTE_RESOLVED);

        vm.warp(originalReleaseAt + 1);

        uint256 sellerBefore = sellerOne.balance;
        uint256 expectedFee = (tokenValue * FEE_RATE) / BASIS_POINTS;

        advancedPP.release(invoiceId);

        inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, RELEASED);
        assertEq(inv.balance, 0);
        assertEq(sellerOne.balance, sellerBefore + tokenValue - expectedFee);
    }

    function test_USDConversionRoundingDownUnderpaysInvoice() public {
        // Price is $1.00000001 (8 decimals). This should require slightly more than 1 USDC.
        uint256 price = 100_000_001;

        uint216 invoiceId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price)
        );

        // Buyer pays using USDC; token amount is rounded down in getTokenValueFromUsd.
        vm.prank(buyerOne);
        advancedPP.payInvoice(invoiceId, address(mockUsdc));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

        // Compute the USD value represented by the paid USDC amount.
        uint256 paidUsd = (inv.amountPaid * uint256(MOCK_USDC_PRICE)) / (10 ** mockUsdc.decimals());

        // A correct implementation should never accept a payment that converts to less USD than the invoice price.
        assertGe(paidUsd, price);
    }

    function _executePayment(address _buyer, uint216 _invoiceId, uint256 _tokenValue) internal {
        mockUsdc.mint(_buyer, INITIAL_BALANCE);

        vm.startPrank(_buyer);
        mockUsdc.approve(address(advancedPP), _tokenValue);
        advancedPP.payMetaInvoice(_invoiceId, address(mockUsdc));
        vm.stopPrank();
    }
}
