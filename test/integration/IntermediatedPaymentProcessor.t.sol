// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    IIntermediatedPaymentProcessor,
    IntermediatedPaymentProcessor
} from "../../src/IntermediatedPaymentProcessor.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IntermediatedPaymentProcessorSetUp } from "../utils/IntermediatedPaymentProcessorSetUp.sol";
import {
    getInvoiceCreationParam,
    getInvoiceCreationParams,
    getEscrowAddress,
    applyBasisPoints
} from "../utils/InvoiceTestHelpers.sol";

import { PAID, CANCELED, DISPUTE_SETTLED, RELEASED, BASIS_POINTS } from "src/constants/Intermediated.sol";

contract IntermediatedPaymentProcessorInteractions is IntermediatedPaymentProcessorSetUp {
    using { getEscrowAddress } for IntermediatedPaymentProcessor;

    string MAINNET_RPC = vm.envString("MAINNET_RPC");

    function setUp() public override {
        uint256 fork = vm.createFork(MAINNET_RPC);
        vm.selectFork(fork);
        super.setUp();
    }

    function test_nativeTokenPaymentForSingleInvoice() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price)
        );

        uint256 amountInToken = intermediatedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(NATIVE_TOKEN_BUYER);
        intermediatedPP.payInvoice{ value: amountInToken }(invoiceId, address(0));

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);

        assertEq(inv.escrow.balance, amountInToken);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, PAID);
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

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(param);

        // make payment
        uint256 tokenAmount = intermediatedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.prank(NATIVE_TOKEN_BUYER);

        intermediatedPP.payMetaInvoiceWithValue{ value: tokenAmount }(metaInvoiceId);

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            IIntermediatedPaymentProcessor.Invoice memory subInvoice = intermediatedPP.getInvoice(invoiceIds[i]);
            address escrow = intermediatedPP.getEscrowAddress(subInvoice.seller, subInvoice.buyer, invoiceIds[i]);

            assertEq(subInvoice.state, PAID);
            assertEq(subInvoice.escrow, escrow);
            assertApproxEqAbs(escrow.balance, intermediatedPP.getTokenValueFromUsd(address(0), prices[i]), 1);
            assertEq(subInvoice.paymentToken, address(0));
        }
    }

    function test_erc20PaymentForSingleInvoice() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price)
        );

        vm.prank(USDC_BUYER);
        intermediatedPP.payInvoice(invoiceId, address(USDC));

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(USDC), price);

        assertEq(IERC20(USDC).balanceOf(inv.escrow), tokenValue);
        assertEq(inv.paymentToken, address(USDC));
        assertEq(inv.state, PAID);
    }

    function test_erc20PaymentForMetaInvoice() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 100e8;
        prices[1] = 200e8;

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(param);

        vm.startPrank(WTBC_BUYER);
        intermediatedPP.payMetaInvoice(metaInvoiceId, address(WBTC));

        vm.stopPrank();

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            IIntermediatedPaymentProcessor.Invoice memory subInvoice = intermediatedPP.getInvoice(invoiceIds[i]);
            address escrow = intermediatedPP.getEscrowAddress(subInvoice.seller, subInvoice.buyer, invoiceIds[i]);

            assertEq(subInvoice.state, PAID);
            assertEq(subInvoice.escrow, escrow);
            assertApproxEqAbs(
                IERC20(WBTC).balanceOf(subInvoice.escrow),
                intermediatedPP.getTokenValueFromUsd(address(WBTC), prices[i]),
                1
            );
            assertEq(subInvoice.paymentToken, address(WBTC));
        }
    }

    function test_sellerCancelInitiatedInvoice() public {
        // single invoice
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price)
        );

        intermediatedPP.cancelInvoice(invoiceId);

        IIntermediatedPaymentProcessor.Invoice memory invOne = intermediatedPP.getInvoice(invoiceId);
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

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        intermediatedPP.createMetaInvoice(param);

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            intermediatedPP.cancelInvoice(invoiceIds[i]);
            assertEq(intermediatedPP.getInvoice(invoiceIds[i]).state, CANCELED);
        }
    }

    function test_settledDispute() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price)
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(USDC), price);

        vm.prank(USDC_BUYER);
        intermediatedPP.payInvoice(invoiceId, address(USDC));

        intermediatedPP.createDispute(invoiceId);

        uint256 buyerBalanceBefore = IERC20(USDC).balanceOf(USDC_BUYER);
        uint256 sellerBalanceBefore = IERC20(USDC).balanceOf(sellerOne);

        uint256 sellerPercentage = 9000;

        uint256 feeReceiverBalanceBefore = IERC20(USDC).balanceOf(feeReceiver);

        intermediatedPP.handleDispute(invoiceId, DISPUTE_SETTLED, sellerPercentage);

        uint256 buyerShare = applyBasisPoints(tokenValue, BASIS_POINTS - sellerPercentage);

        uint256 sellerShare = tokenValue - buyerShare;
        uint256 fee = applyBasisPoints(sellerShare, FEE_RATE);

        assertEq(intermediatedPP.getInvoice(invoiceId).state, DISPUTE_SETTLED);
        assertEq(IERC20(USDC).balanceOf(sellerOne), sellerBalanceBefore + sellerShare - fee);
        assertEq(IERC20(USDC).balanceOf(USDC_BUYER), buyerBalanceBefore + buyerShare);
        assertEq(IERC20(USDC).balanceOf(feeReceiver), feeReceiverBalanceBefore + fee);
    }

    function test_invoiceRelease() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price)
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(WBTC), price);
        uint256 buyerBalanceBefore = IERC20(WBTC).balanceOf(WTBC_BUYER);
        uint256 sellerBalanceBefore = IERC20(WBTC).balanceOf(sellerOne);

        uint256 fee = applyBasisPoints(tokenValue, FEE_RATE);

        vm.prank(WTBC_BUYER);
        intermediatedPP.payInvoice(invoiceId, WBTC);

        vm.warp(block.timestamp + 1 days);
        intermediatedPP.release(invoiceId);

        uint256 buyerBalanceAfter = IERC20(WBTC).balanceOf(WTBC_BUYER);
        uint256 sellerBalanceAfter = IERC20(WBTC).balanceOf(sellerOne);

        assertEq(buyerBalanceAfter, buyerBalanceBefore - tokenValue);
        assertEq(sellerBalanceAfter, sellerBalanceBefore + tokenValue - fee);
        assertEq(intermediatedPP.getInvoice(invoiceId).state, RELEASED);
    }
}
