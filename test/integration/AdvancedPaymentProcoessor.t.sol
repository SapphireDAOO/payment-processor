// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AdvancedPaymentProcessorSetUp } from "../utils/AdvancedPaymentProcessorSetUp.sol";
import {
    getInvoiceCreationParam,
    getInvoiceCreationParams,
    getEscrowAddress,
    applyBasisPoints
} from "../utils/InvoiceTestHelpers.sol";

contract AdvancedPaymentProcoessorInteractions is AdvancedPaymentProcessorSetUp {
    using { getEscrowAddress, applyBasisPoints } for AdvancedPaymentProcessor;

    string MAINNET_RPC = vm.envString("MAINNET_RPC");

    function setUp() public override {
        uint256 fork = vm.createFork(MAINNET_RPC);
        vm.selectFork(fork);
        super.setUp();
    }

    function test_nativeTokenPaymentForSingleInvoice() public {
        uint256 price = 100e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));

        uint256 amountInToken = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(NATIVE_TOKEN_BUYER);
        advancedPP.payInvoice{ value: amountInToken }(invoiceId, address(0));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

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

        // create invoice

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);

        // make payment
        uint256 tokenAmount = advancedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.prank(NATIVE_TOKEN_BUYER);

        advancedPP.payMetaInvoiceWithValue{ value: tokenAmount }(metaInvoiceId);

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            IAdvancedPaymentProcessor.Invoice memory subInvoice = advancedPP.getInvoice(invoiceIds[i]);
            address escrow = advancedPP.getEscrowAddress(subInvoice.seller, subInvoice.buyer, invoiceIds[i]);

            assertEq(subInvoice.state, advancedPP.PAID());
            assertEq(subInvoice.escrow, escrow);
            assertEq(escrow.balance, advancedPP.getTokenValueFromUsd(address(0), prices[i]));
            assertEq(subInvoice.paymentToken, address(0));
        }
    }

    function test_erc20PaymentForSingleInvoice() public {
        uint256 price = 100e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));

        vm.prank(USDC_BUYER);
        advancedPP.payInvoice(invoiceId, address(USDC));

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

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);

        vm.startPrank(WTBC_BUYER);
        advancedPP.payMetaInvoice(metaInvoiceId, address(WBTC));

        vm.stopPrank();

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            IAdvancedPaymentProcessor.Invoice memory subInvoice = advancedPP.getInvoice(invoiceIds[i]);
            address escrow = advancedPP.getEscrowAddress(subInvoice.seller, subInvoice.buyer, invoiceIds[i]);

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
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));

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
    }

    function test_settledDispute() public {
        uint256 price = 100e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(USDC), price);

        vm.prank(USDC_BUYER);
        advancedPP.payInvoice(invoiceId, address(USDC));

        uint8 settled = advancedPP.DISPUTE_SETTLED();

        advancedPP.createDispute(invoiceId);

        uint256 buyerBalanceBefore = IERC20(USDC).balanceOf(USDC_BUYER);
        uint256 sellerBalanceBefore = IERC20(USDC).balanceOf(sellerOne);

        uint256 sellerPercentage = 9000;

        uint256 feeReceiverBalanceBefore = IERC20(USDC).balanceOf(feeReceiver);

        advancedPP.handleDispute(invoiceId, settled, sellerPercentage);

        uint256 buyerShare = advancedPP.applyBasisPoints(tokenValue, advancedPP.BASIS_POINTS() - sellerPercentage);

        uint256 sellerShare = tokenValue - buyerShare;
        uint256 fee = advancedPP.applyBasisPoints(sellerShare, FEE_RATE);

        assertEq(advancedPP.getInvoice(invoiceId).state, advancedPP.DISPUTE_SETTLED());
        assertEq(IERC20(USDC).balanceOf(sellerOne), sellerBalanceBefore + sellerShare - fee);
        assertEq(IERC20(USDC).balanceOf(USDC_BUYER), buyerBalanceBefore + buyerShare);
        assertEq(IERC20(USDC).balanceOf(feeReceiver), feeReceiverBalanceBefore + fee);
    }

    function test_invoiceRelease() public {
        uint256 price = 100e8;
        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(WBTC), price);
        uint256 buyerBalanceBefore = IERC20(WBTC).balanceOf(WTBC_BUYER);
        uint256 sellerBalanceBefore = IERC20(WBTC).balanceOf(sellerOne);

        uint256 fee = advancedPP.applyBasisPoints(tokenValue, FEE_RATE);

        vm.prank(WTBC_BUYER);
        advancedPP.payInvoice(invoiceId, WBTC);

        vm.warp(block.timestamp + 1 days);
        advancedPP.release(invoiceId);

        uint256 buyerBalanceAfter = IERC20(WBTC).balanceOf(WTBC_BUYER);
        uint256 sellerBalanceAfter = IERC20(WBTC).balanceOf(sellerOne);

        assertEq(buyerBalanceAfter, buyerBalanceBefore - tokenValue);
        assertEq(sellerBalanceAfter, sellerBalanceBefore + tokenValue - fee);
        assertEq(advancedPP.getInvoice(invoiceId).state, advancedPP.RELEASED());
    }
}
