// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    IIntermediatedPaymentProcessor,
    IntermediatedPaymentProcessor
} from "../../src/IntermediatedPaymentProcessor.sol";
import { IOracleManager } from "../../src/interface/IOracleManager.sol";
import { IPaymentProcessorStorage } from "../../src/interface/IPaymentProcessorStorage.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

import { IntermediatedPaymentProcessorSetUp } from "../utils/IntermediatedPaymentProcessorSetUp.sol";

import {
    getInvoiceCreationParam,
    getInvoiceCreationParams,
    applyBasisPoints,
    TEST_ESCROW_HOLD_PERIOD,
    getEscrowAddress
} from "../utils/InvoiceTestHelpers.sol";

import {
    CREATED,
    PAID,
    CANCELED,
    DISPUTED,
    REFUNDED,
    DISPUTE_RESOLVED,
    DISPUTE_DISMISSED,
    DISPUTE_SETTLED,
    RELEASED,
    BASIS_POINTS,
    DEFAULT_DECIMAL
} from "src/constants/Intermediated.sol";

import { SafeCastLib } from "solady/utils/SafeCastLib.sol";

error InvalidFeeRate();

contract IntermediatedPaymentProcessorTest is IntermediatedPaymentProcessorSetUp {
    using { getEscrowAddress } for IntermediatedPaymentProcessor;
    using SafeCastLib for uint256;

    error NotAuthorized();
    error HoldPeriodCanNotBeZero();

    function test_Initialization() public view {
        assertEq(intermediatedPP.getNextInvoiceNonce(), 1);
        assertEq(intermediatedPP.getNextMetaInvoiceNonce(), 1);
    }

    function test_storageConfig() public {
        vm.startPrank(admin);
        ppStorage.setFeeReceiver(address(0xa0));

        vm.expectRevert(InvalidFeeRate.selector);
        ppStorage.setFeeRate(uint96(BASIS_POINTS + 1));

        ppStorage.setFeeRate(100);
        ppStorage.setGasThreshold(20_000);

        ppStorage.setIntermediatedPlatformsOperator(address(0xb0));
        vm.stopPrank();

        assertEq(address(0xa0), ppStorage.getFeeReceiver());
        assertEq(100, ppStorage.getFeeRate());
        assertEq(20_000, ppStorage.getGasThreshold());
        assertEq(address(0xb0), ppStorage.getIntermediatedPlatformsOperator());
    }

    function test_setMinimumPrice() public {
        vm.prank(buyerOne);
        vm.expectRevert(IIntermediatedPaymentProcessor.NotAuthorized.selector);
        intermediatedPP.setMinimumPrice(200e8);

        uint256 newMin = 200e8;
        vm.prank(admin);
        intermediatedPP.setMinimumPrice(newMin);

        uint256 nextNonce = ppStorage.getNextInvoiceNonce();
        vm.expectRevert(IIntermediatedPaymentProcessor.PriceIsTooLow.selector);
        intermediatedPP.createSingleInvoice(getInvoiceCreationParam(nextNonce, sellerOne, 100e8, _testPaymentTokens()));

        intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, newMin, _testPaymentTokens())
        );
    }

    function test_updateInvoiceNonce() public {
        vm.expectRevert(NotAuthorized.selector);
        ppStorage.updateInvoiceNonce(1);
    }

    function test_setPriceFeed() public {
        IOracleManager oracleManager = intermediatedPP.oracle();

        vm.expectRevert(IOracleManager.UnsupportedToken.selector);
        oracleManager.getUsdPerToken(address(1));

        vm.prank(admin);
        oracle.setPriceFeed(
            address(1), IOracleManager.PriceFeedConfig({ aggregator: address(2), heartbeat: 1 hours, allowed: true })
        );

        vm.expectRevert(IOracleManager.UnsupportedToken.selector);
        oracleManager.getUsdPerToken(address(2));
    }

    function test_singleInvoiceCreation() public {
        uint256 price = 100e8;

        uint256 invoiceNonce = ppStorage.getNextInvoiceNonce();

        vm.prank(buyerOne);
        vm.expectRevert(IIntermediatedPaymentProcessor.NotAuthorized.selector);
        intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(invoiceNonce, sellerOne, price, _testPaymentTokens())
        );

        vm.expectRevert(IIntermediatedPaymentProcessor.PriceCannotBeZero.selector);
        intermediatedPP.createSingleInvoice(getInvoiceCreationParam(invoiceNonce, sellerOne, 0, _testPaymentTokens()));

        vm.expectRevert(IIntermediatedPaymentProcessor.PriceIsTooLow.selector);
        intermediatedPP.createSingleInvoice(getInvoiceCreationParam(invoiceNonce, sellerOne, 1, _testPaymentTokens()));

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(invoiceNonce, sellerOne, price, _testPaymentTokens())
        );

        vm.expectRevert(IIntermediatedPaymentProcessor.InvoiceAlreadyExists.selector);
        intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(invoiceNonce, sellerOne, price, _testPaymentTokens())
        );

        uint256 nextInvoiceNonce = intermediatedPP.getNextInvoiceNonce();
        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);
        assertEq(inv.state, CREATED);
        assertEq(inv.price, price);
        assertEq(inv.seller, sellerOne);
        assertEq(inv.createdAt, block.timestamp);
        assertEq(inv.invoiceNonce, intermediatedPP.totalUniqueInvoiceCreated());
        assertEq(nextInvoiceNonce, 2);
    }

    function test_createMultipleInvoiceAndMakePayment() public {
        // set up
        uint256 invoiceNonce = ppStorage.getNextInvoiceNonce();

        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;

        IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory a;

        vm.expectRevert(IIntermediatedPaymentProcessor.EmptyMetaInvoice.selector);
        intermediatedPP.createMetaInvoice(a);

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory keys) =
            getInvoiceCreationParams(invoiceNonce, sellers, prices, _testPaymentTokens());

        // create invoice
        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(param);

        uint256 upper = intermediatedPP.getNextInvoiceNonce() - 1;

        IIntermediatedPaymentProcessor.MetaInvoice memory metaInv = intermediatedPP.getMetaInvoice(metaInvoiceId);

        // assertion

        for (uint256 i = 0; i < keys.length; i++) {
            IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(keys[i]);

            assertEq(inv.price, prices[i]);
            assertEq(inv.seller, sellers[i]);
            assertEq(inv.createdAt, block.timestamp);
            assertEq(inv.metaInvoiceId, metaInvoiceId);
            // assertEq(inv.invoiceNonce, invoiceNonce + i);
        }

        assertEq(intermediatedPP.getNextInvoiceNonce(), upper + 1);
        assertEq(metaInv.price, prices[0] + prices[1]);
    }

    function test_nativeTokenPaymentForSingleInvoice() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        vm.startPrank(buyerOne);

        // A token the invoice never listed is rejected before the oracle is consulted.
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntermediatedPaymentProcessor.PaymentTokenNotAllowed.selector, invoiceId, address(12)
            )
        );
        intermediatedPP.payInvoice(
            invoiceId, address(12), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidNativePayment.selector);
        intermediatedPP.payInvoice{ value: 0.001 ether }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );
        vm.stopPrank();

        uint256 amountInToken = intermediatedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(sellerOne);
        vm.expectRevert(IIntermediatedPaymentProcessor.BuyerCannotBeSeller.selector);
        intermediatedPP.payInvoice{ value: amountInToken }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: amountInToken }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);

        assertEq(inv.escrow.balance, amountInToken);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, PAID);

        invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        vm.warp(15 days);
        vm.expectRevert(IIntermediatedPaymentProcessor.InvoiceExpired.selector);
        intermediatedPP.payInvoice{ value: amountInToken }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );
    }

    function test_nativeTokenPaymentForMetaInvoice() public {
        uint256 invoiceNonce = intermediatedPP.getNextInvoiceNonce();

        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 150e8;
        prices[1] = 250e8;

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(invoiceNonce, sellers, prices, _testPaymentTokens());

        // create meta invoice
        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(param);

        uint256 tokenAmount = intermediatedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        {
            address[] memory metaReceivers1 = _metaReceivers(0);
            bytes memory metaFeeSig1 = _metaFeeSig(0);
            vm.expectRevert(IIntermediatedPaymentProcessor.InvoiceDoesNotExist.selector);
            intermediatedPP.payMetaInvoiceWithValue{ value: 0.03 ether }(0, metaReceivers1, metaFeeSig1);
        }

        {
            address[] memory metaReceivers2 = _metaReceivers(metaInvoiceId);
            bytes memory metaFeeSig2 = _metaFeeSig(metaInvoiceId);
            vm.startPrank(buyerOne);

            vm.expectRevert(IIntermediatedPaymentProcessor.UnsupportedToken.selector);
            intermediatedPP.payMetaInvoice(metaInvoiceId, address(12), metaReceivers2, metaFeeSig2);
        }

        {
            address[] memory metaReceivers3 = _metaReceivers(metaInvoiceId);
            bytes memory metaFeeSig3 = _metaFeeSig(metaInvoiceId);
            intermediatedPP.payMetaInvoiceWithValue{ value: tokenAmount }(metaInvoiceId, metaReceivers3, metaFeeSig3);
        }

        {
            address[] memory metaReceivers4 = _metaReceivers(metaInvoiceId);
            bytes memory metaFeeSig4 = _metaFeeSig(metaInvoiceId);
            vm.expectRevert(IIntermediatedPaymentProcessor.InvalidInvoiceState.selector);
            intermediatedPP.payMetaInvoiceWithValue{ value: tokenAmount }(metaInvoiceId, metaReceivers4, metaFeeSig4);
        }

        vm.stopPrank();

        IIntermediatedPaymentProcessor.Invoice memory invOne = intermediatedPP.getInvoice(invoiceIds[0]);
        address escrowOne = intermediatedPP.getEscrowAddress(invOne.seller, invOne.buyer, invoiceIds[0]);

        assertEq(invOne.state, PAID);
        assertEq(invOne.escrow, escrowOne);
        assertApproxEqAbs(invOne.escrow.balance, intermediatedPP.getTokenValueFromUsd(address(0), prices[0]), 1);
        assertEq(invOne.paymentToken, address(0));

        IIntermediatedPaymentProcessor.Invoice memory invTwo = intermediatedPP.getInvoice(invoiceIds[1]);
        address escrowTwo = intermediatedPP.getEscrowAddress(invTwo.seller, invTwo.buyer, invoiceIds[1]);

        assertEq(invTwo.state, PAID);
        assertEq(invTwo.escrow, escrowTwo);
        assertApproxEqAbs(invTwo.escrow.balance, intermediatedPP.getTokenValueFromUsd(address(0), prices[1]), 1);
        assertEq(invTwo.paymentToken, address(0));
    }

    function test_payMetaInvoice_revertsOnIncorrectMsgValue() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 100e8;
        prices[1] = 200e8;

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param,) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, _testPaymentTokens());

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(param);
        uint256 expected = intermediatedPP.getMetaInvoice(metaInvoiceId).price;

        {
            address[] memory metaReceivers5 = _metaReceivers(metaInvoiceId);
            bytes memory metaFeeSig5 = _metaFeeSig(metaInvoiceId);
            vm.prank(buyerOne);
            vm.expectRevert();
            intermediatedPP.payMetaInvoiceWithValue{ value: expected - 1 }(metaInvoiceId, metaReceivers5, metaFeeSig5);
        }
    }

    function test_erc20PaymentForSingleInvoice() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        vm.prank(buyerOne);
        intermediatedPP.payInvoice(
            invoiceId, address(mockUsdc), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        vm.prank(buyerOne);
        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidInvoiceState.selector);
        intermediatedPP.payInvoice(
            invoiceId, address(mockUsdc), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(mockUsdc), price);

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

        {
            address[] memory metaReceivers6 = _metaReceivers(0);
            bytes memory metaFeeSig6 = _metaFeeSig(0);
            vm.expectRevert(IIntermediatedPaymentProcessor.InvoiceDoesNotExist.selector);
            intermediatedPP.payMetaInvoice(0, address(mockWBtc), metaReceivers6, metaFeeSig6);
        }

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, _testPaymentTokens());

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(param);

        // make payment; scoped so the extra locals do not push this function past the stack limit
        {
            {
                address[] memory metaReceivers7 = _metaReceivers(metaInvoiceId);
                bytes memory metaFeeSig7 = _metaFeeSig(metaInvoiceId);
                vm.prank(buyerOne);
                intermediatedPP.payMetaInvoice(metaInvoiceId, address(mockWBtc), metaReceivers7, metaFeeSig7);
            }
        }

        IIntermediatedPaymentProcessor.Invoice memory invOne = intermediatedPP.getInvoice(invoiceIds[0]);
        address escrowOne = intermediatedPP.getEscrowAddress(invOne.seller, invOne.buyer, invoiceIds[0]);

        assertEq(invOne.state, PAID);
        assertEq(invOne.escrow, escrowOne);
        assertApproxEqAbs(
            IERC20(mockWBtc).balanceOf(invOne.escrow),
            intermediatedPP.getTokenValueFromUsd(address(mockWBtc), prices[0]),
            1
        );
        assertEq(invOne.paymentToken, address(mockWBtc));

        IIntermediatedPaymentProcessor.Invoice memory invTwo = intermediatedPP.getInvoice(invoiceIds[1]);
        address escrowTwo = intermediatedPP.getEscrowAddress(invTwo.seller, invTwo.buyer, invoiceIds[1]);

        assertEq(invTwo.state, PAID);
        assertEq(invTwo.escrow, escrowTwo);
        assertApproxEqAbs(
            IERC20(mockWBtc).balanceOf(invTwo.escrow),
            intermediatedPP.getTokenValueFromUsd(address(mockWBtc), prices[1]),
            1
        );
        assertEq(invTwo.paymentToken, address(mockWBtc));
    }

    function test_cancelInvoice() public {
        // single invoice
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        vm.prank(buyerOne);
        vm.expectRevert(IIntermediatedPaymentProcessor.NotAuthorized.selector);
        intermediatedPP.cancelInvoice(invoiceId);

        intermediatedPP.cancelInvoice(invoiceId);

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidInvoiceState.selector);
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
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, _testPaymentTokens());

        intermediatedPP.createMetaInvoice(param);

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            intermediatedPP.cancelInvoice(invoiceIds[i]);
            assertEq(intermediatedPP.getInvoice(invoiceIds[i]).state, CANCELED);
        }

        vm.stopPrank();
    }

    function test_disputeCreation() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(sellerOne);
        vm.expectRevert(NotAuthorized.selector);
        intermediatedPP.createDispute(invoiceId);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        vm.warp(block.timestamp + 25 hours);

        intermediatedPP.createDispute(invoiceId);

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidInvoiceState.selector);
        intermediatedPP.createDispute(invoiceId);

        assertEq(intermediatedPP.getInvoice(invoiceId).state, DISPUTED);
    }

    function test_dismissedDispute() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, _testPaymentTokens());

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(param);

        {
            address[] memory metaReceivers8 = _metaReceivers(metaInvoiceId);
            bytes memory metaFeeSig8 = _metaFeeSig(metaInvoiceId);
            vm.prank(buyerOne);
            intermediatedPP.payMetaInvoice(metaInvoiceId, address(mockUsdc), metaReceivers8, metaFeeSig8);
        }

        for (uint256 i; i < invoiceIds.length; i++) {
            uint216 key = invoiceIds[i];

            intermediatedPP.createDispute(key);
        }

        uint8 dismissed = DISPUTE_DISMISSED;

        vm.prank(buyerOne);
        vm.expectRevert(IIntermediatedPaymentProcessor.NotAuthorized.selector);
        intermediatedPP.handleDispute(invoiceIds[0], dismissed, 0);

        intermediatedPP.handleDispute(invoiceIds[0], dismissed, 0);

        assertEq(intermediatedPP.getInvoice(invoiceIds[0]).state, dismissed);
    }

    function test_settledDispute() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(mockUsdc), price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice(
            invoiceId, address(mockUsdc), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        uint256 basisPoint = BASIS_POINTS;
        uint8 dismissed = DISPUTE_DISMISSED;
        uint8 settled = DISPUTE_SETTLED;
        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidInvoiceState.selector);
        intermediatedPP.handleDispute(invoiceId, dismissed, basisPoint);

        intermediatedPP.createDispute(invoiceId);

        uint256 buyerBalanceBefore = IERC20(mockUsdc).balanceOf(buyerOne);
        uint256 sellerBalanceBefore = IERC20(mockUsdc).balanceOf(sellerOne);

        console.log("balances before", buyerBalanceBefore, sellerBalanceBefore);

        uint256 sellerPercentage = 9000;

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidSellersPayoutShare.selector);
        intermediatedPP.handleDispute(invoiceId, settled, basisPoint + 1);

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidDisputeResolution.selector);
        intermediatedPP.handleDispute(invoiceId, 12, sellerPercentage);

        intermediatedPP.handleDispute(invoiceId, settled, sellerPercentage);

        uint256 buyerShare = applyBasisPoints(tokenValue, BASIS_POINTS - sellerPercentage);

        uint256 sellerShare = applyBasisPoints(tokenValue, sellerPercentage);
        uint256 fee = applyBasisPoints(sellerShare, FEE_RATE);

        console.log("balances after", IERC20(mockUsdc).balanceOf(buyerOne), IERC20(mockUsdc).balanceOf(sellerOne));

        assertEq(intermediatedPP.getInvoice(invoiceId).state, DISPUTE_SETTLED);
        assertEq(IERC20(mockUsdc).balanceOf(sellerOne), sellerBalanceBefore + sellerShare - fee);
        assertEq(IERC20(mockUsdc).balanceOf(buyerOne), buyerBalanceBefore + buyerShare);
        assertEq(IERC20(mockUsdc).balanceOf(feeReceiver), fee);
        assertEq(IERC20(mockUsdc).balanceOf(intermediatedPP.getInvoice(invoiceId).escrow), 0);
    }

    function test_resolveDispute() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        vm.prank(buyerOne);
        intermediatedPP.payInvoice(
            invoiceId, address(mockUsdc), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidInvoiceState.selector);
        intermediatedPP.resolveDispute(invoiceId);

        intermediatedPP.createDispute(invoiceId);

        vm.prank(buyerOne);
        vm.expectRevert(IIntermediatedPaymentProcessor.NotAuthorized.selector);
        intermediatedPP.resolveDispute(invoiceId);

        intermediatedPP.resolveDispute(invoiceId);
    }

    function test_invoiceRelease() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );
        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), price);

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidInvoiceState.selector);
        intermediatedPP.release(invoiceId);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        vm.warp(block.timestamp + 1 days);

        vm.prank(buyerOne);
        vm.expectRevert(IIntermediatedPaymentProcessor.NotAuthorized.selector);
        intermediatedPP.release(invoiceId);

        intermediatedPP.release(invoiceId);

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidInvoiceState.selector);
        intermediatedPP.release(invoiceId);

        assertEq(intermediatedPP.getInvoice(invoiceId).state, RELEASED);
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

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, _testPaymentTokens());

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(param);

        uint256 tokenAmount = intermediatedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        uint256 balanceBefore = buyerTwo.balance;

        {
            address[] memory metaReceivers9 = _metaReceivers(metaInvoiceId);
            bytes memory metaFeeSig9 = _metaFeeSig(metaInvoiceId);
            vm.prank(buyerTwo);
            intermediatedPP.payMetaInvoiceWithValue{ value: tokenAmount }(metaInvoiceId, metaReceivers9, metaFeeSig9);
        }

        vm.warp(block.timestamp + 1 days);
        intermediatedPP.release(invoiceIds[0]);
        intermediatedPP.release(invoiceIds[1]);

        assertEq(intermediatedPP.getInvoice(invoiceIds[0]).state, RELEASED);
        assertEq(intermediatedPP.getInvoice(invoiceIds[1]).state, RELEASED);

        assertApproxEqAbs(balanceBefore - tokenAmount, buyerTwo.balance, 1);

        assertEq(intermediatedPP.getInvoice(invoiceIds[0]).escrow.balance, 0);
        assertEq(intermediatedPP.getInvoice(invoiceIds[1]).escrow.balance, 0);
    }

    function test_releaseAfterCancelationMetaInvoice() public {
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

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, _testPaymentTokens());

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(param);

        intermediatedPP.cancelInvoice(invoiceIds[0]);

        uint256 tokenAmount = intermediatedPP.getTokenValueFromUsd(address(0), prices[1] + prices[2]);
        uint256 balanceBefore = buyerOne.balance;

        {
            address[] memory metaReceivers10 = _metaReceivers(metaInvoiceId);
            bytes memory metaFeeSig10 = _metaFeeSig(metaInvoiceId);
            vm.prank(buyerOne);
            intermediatedPP.payMetaInvoiceWithValue{ value: tokenAmount }(metaInvoiceId, metaReceivers10, metaFeeSig10);
        }

        assertApproxEqAbs(balanceBefore - tokenAmount, buyerOne.balance, 1);
    }

    function test_fullRefund() public {
        uint256 price = 1500e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );
        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), price);

        uint256 refundShare = 10_000;

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidInvoiceState.selector);
        intermediatedPP.refund(invoiceId, refundShare);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );
        uint256 buyerBalance = buyerOne.balance;

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidSellersPayoutShare.selector);
        intermediatedPP.refund(invoiceId, 0);

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidSellersPayoutShare.selector);
        intermediatedPP.refund(invoiceId, refundShare + 1);

        vm.prank(buyerOne);
        vm.expectRevert(IIntermediatedPaymentProcessor.NotAuthorized.selector);
        intermediatedPP.refund(invoiceId, BASIS_POINTS);

        intermediatedPP.refund(invoiceId, refundShare);

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);
        assertEq(inv.balance, 0);

        assertEq(buyerOne.balance, buyerBalance + tokenValue);
    }

    function test_partialRefundErc20ThenRelease() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        vm.prank(buyerOne);
        intermediatedPP.payInvoice(
            invoiceId, address(mockUsdc), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        uint256 tokenValue = intermediatedPP.getInvoice(invoiceId).balance;
        uint256 refundShare = 3000;
        uint256 refundAmount = (tokenValue * refundShare) / BASIS_POINTS;
        uint256 remaining = tokenValue - refundAmount;

        uint256 buyerUsdcBefore = mockUsdc.balanceOf(buyerOne);

        intermediatedPP.refund(invoiceId, refundShare);

        assertEq(mockUsdc.balanceOf(buyerOne), buyerUsdcBefore + refundAmount);
        assertEq(intermediatedPP.getInvoice(invoiceId).balance, remaining);
        assertEq(intermediatedPP.getInvoice(invoiceId).state, PAID);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);

        uint256 sellerUsdcBefore = mockUsdc.balanceOf(sellerOne);
        uint256 expectedFee = (remaining * FEE_RATE) / BASIS_POINTS;

        intermediatedPP.release(invoiceId);

        assertEq(intermediatedPP.getInvoice(invoiceId).state, RELEASED);
        assertEq(mockUsdc.balanceOf(sellerOne), sellerUsdcBefore + remaining - expectedFee);
        assertEq(mockUsdc.balanceOf(feeReceiver), expectedFee);
    }

    function test_fullRefundErc20() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        vm.prank(buyerOne);
        intermediatedPP.payInvoice(
            invoiceId, address(mockUsdc), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        uint256 tokenValue = intermediatedPP.getInvoice(invoiceId).balance;
        uint256 buyerUsdcBefore = mockUsdc.balanceOf(buyerOne);

        intermediatedPP.refund(invoiceId, BASIS_POINTS);

        assertEq(intermediatedPP.getInvoice(invoiceId).state, REFUNDED);
        assertEq(intermediatedPP.getInvoice(invoiceId).balance, 0);
        assertEq(mockUsdc.balanceOf(buyerOne), buyerUsdcBefore + tokenValue);
    }

    function test_refundAndRelease() public {
        uint256 price = 1500e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );
        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        uint256 buyerBalance = buyerOne.balance;

        uint256 refundableAmount = (tokenValue * 67) / 100;
        uint256 releaseableAmount = tokenValue - refundableAmount;

        uint256 refundShare = 6700;

        intermediatedPP.refund(invoiceId, refundShare);

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);
        assertEq(inv.balance, releaseableAmount);
        assertEq(buyerOne.balance, buyerBalance + refundableAmount);

        releaseableAmount -= (releaseableAmount * ppStorage.getFeeRate()) / BASIS_POINTS;

        uint256 sellerBalance = sellerOne.balance;

        vm.warp(block.timestamp + 1 days);
        intermediatedPP.release(invoiceId);
        assertEq(sellerBalance + releaseableAmount, sellerOne.balance);
    }

    function test_feeRateSnapshotAtCreationIsUsedOnRelease() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        assertEq(intermediatedPP.getInvoice(invoiceId).feeRate, FEE_RATE);

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), price);
        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        // Global fee rate change after creation must not affect this invoice.
        vm.prank(admin);
        ppStorage.setFeeRate(uint96(FEE_RATE * 4));

        uint256 sellerBalance = sellerOne.balance;
        uint256 expectedFee = (tokenValue * FEE_RATE) / BASIS_POINTS;

        vm.warp(block.timestamp + 1 days);
        intermediatedPP.release(invoiceId);

        assertEq(sellerOne.balance, sellerBalance + tokenValue - expectedFee);
        assertEq(feeReceiver.balance, expectedFee);
    }

    function test_feeRateSnapshotAtCreationIsUsedOnDisputeSettlement() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), price);
        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        intermediatedPP.createDispute(invoiceId);

        // Global fee rate change after creation must not affect this invoice.
        vm.prank(admin);
        ppStorage.setFeeRate(uint96(FEE_RATE * 4));

        uint256 sellerShare = 5000;
        uint256 buyerReceiving = applyBasisPoints(tokenValue, BASIS_POINTS - sellerShare);
        uint256 sellerReceiving = tokenValue - buyerReceiving;
        uint256 expectedFee = applyBasisPoints(sellerReceiving, FEE_RATE);

        uint256 sellerBalance = sellerOne.balance;
        intermediatedPP.handleDispute(invoiceId, DISPUTE_SETTLED, sellerShare);

        assertEq(sellerOne.balance, sellerBalance + sellerReceiving - expectedFee);
        assertEq(feeReceiver.balance, expectedFee);
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

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param,) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, _testPaymentTokens());

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(param);
        IIntermediatedPaymentProcessor.MetaInvoice memory metaInv = intermediatedPP.getMetaInvoice(metaInvoiceId);
        assertEq(metaInv.price, prices[0] + prices[1] + prices[2]);
    }

    function test_customEscrowHoldPeriodIsUsedWhenSet() public {
        uint256 price = 100e8;
        uint32 customHold = 7 days;

        IIntermediatedPaymentProcessor.InvoiceCreationParam memory param =
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens());
        param.escrowHoldPeriod = customHold;

        uint216 invoiceId = intermediatedPP.createSingleInvoice(param);

        assertEq(intermediatedPP.getInvoice(invoiceId).escrowHoldPeriod, customHold);

        uint256 amountInToken = intermediatedPP.getTokenValueFromUsd(address(0), price);
        uint256 paidAt = block.timestamp;

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: amountInToken }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);

        assertEq(inv.releaseAt, paidAt + customHold);
        assertEq(inv.state, PAID);
    }

    function test_createInvoiceRevertsWhenEscrowHoldPeriodIsZero() public {
        IIntermediatedPaymentProcessor.InvoiceCreationParam memory param =
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, 100e8, _testPaymentTokens());
        param.escrowHoldPeriod = 0;

        vm.expectRevert(HoldPeriodCanNotBeZero.selector);
        intermediatedPP.createSingleInvoice(param);
    }

    function test_customEscrowHoldPeriod_cannotReleaseBeforeIt() public {
        uint256 price = 100e8;
        uint32 customHold = 7 days;

        IIntermediatedPaymentProcessor.InvoiceCreationParam memory param =
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens());
        param.escrowHoldPeriod = customHold;

        uint216 invoiceId = intermediatedPP.createSingleInvoice(param);

        uint256 amountInToken = intermediatedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: amountInToken }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        // warp past default hold (1 day) but not past custom hold (7 days)
        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidInvoiceState.selector);
        intermediatedPP.release(invoiceId);
    }

    function test_customEscrowHoldPeriod_canReleaseAfterIt() public {
        uint256 price = 100e8;
        uint32 customHold = 7 days;

        IIntermediatedPaymentProcessor.InvoiceCreationParam memory param =
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens());
        param.escrowHoldPeriod = customHold;

        uint216 invoiceId = intermediatedPP.createSingleInvoice(param);

        uint256 amountInToken = intermediatedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: amountInToken }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        vm.warp(block.timestamp + customHold + 1);
        intermediatedPP.release(invoiceId);

        assertEq(intermediatedPP.getInvoice(invoiceId).state, RELEASED);
    }

    function test_customEscrowHoldPeriodForMetaInvoice() public {
        uint32 customHold = 14 days;

        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 100e8;
        prices[1] = 200e8;

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory params, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, _testPaymentTokens());

        params[0].escrowHoldPeriod = customHold;
        params[1].escrowHoldPeriod = customHold;

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(params);

        uint256 totalTokenValue = intermediatedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);
        uint256 paidAt = block.timestamp;

        {
            address[] memory metaReceivers11 = _metaReceivers(metaInvoiceId);
            bytes memory metaFeeSig11 = _metaFeeSig(metaInvoiceId);
            vm.prank(buyerOne);
            intermediatedPP.payMetaInvoiceWithValue{ value: totalTokenValue }(
                metaInvoiceId, metaReceivers11, metaFeeSig11
            );
        }

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceIds[i]);
            assertEq(inv.releaseAt, paidAt + customHold);
            assertEq(inv.state, PAID);
        }
    }

    function test_USDConversionRoundingDownUnderpaysInvoice() public {
        // Price is $1.00000001 (8 decimals). This should require slightly more than 1 USDC.
        uint256 price = 100_000_001;

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        // Buyer pays using USDC; token amount is rounded down in getTokenValueFromUsd.
        vm.prank(buyerOne);
        intermediatedPP.payInvoice(
            invoiceId, address(mockUsdc), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);

        // Compute the USD value represented by the paid USDC amount.
        uint256 paidUsd = (inv.amountPaid * uint256(MOCK_USDC_PRICE)) / (10 ** mockUsdc.decimals());

        // A correct implementation should never accept a payment that converts to less USD than the invoice price.
        assertGe(paidUsd, price);
    }

    function test_setInvoiceReleaseTimeOnDisputeResolved() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );
        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        intermediatedPP.createDispute(invoiceId);
        intermediatedPP.resolveDispute(invoiceId);

        assertEq(intermediatedPP.getInvoice(invoiceId).state, DISPUTE_RESOLVED);

        uint256 newHold = 5 days;
        vm.prank(admin);
        intermediatedPP.setInvoiceReleaseTime(invoiceId, newHold);

        assertEq(intermediatedPP.getInvoice(invoiceId).releaseAt, block.timestamp + newHold);
    }

    function test_setInvoiceReleaseTimeOnDisputeDismissed() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );
        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        intermediatedPP.createDispute(invoiceId);
        intermediatedPP.handleDispute(invoiceId, DISPUTE_DISMISSED, 0);

        assertEq(intermediatedPP.getInvoice(invoiceId).state, DISPUTE_DISMISSED);

        uint256 newHold = 5 days;
        vm.prank(admin);
        intermediatedPP.setInvoiceReleaseTime(invoiceId, newHold);

        assertEq(intermediatedPP.getInvoice(invoiceId).releaseAt, block.timestamp + newHold);
    }

    function test_createSingleInvoice(uint256 _price) public {
        _price = bound(_price, 1e8, type(uint128).max);

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price, _testPaymentTokens())
        );

        uint256 nextInvoiceNonce = intermediatedPP.getNextInvoiceNonce();
        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);
        assertEq(inv.price, _price);
        assertEq(inv.seller, sellerOne);
        assertEq(nextInvoiceNonce, 2);
    }

    function test_payInvoice(uint256 _price) public {
        _price = bound(_price, 1e8, 100e8);

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerTwo, _price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerTwo);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);

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

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param,) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, _testPaymentTokens());

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(param);

        uint256 id = intermediatedPP.totalMetaInvoiceCreated();

        IIntermediatedPaymentProcessor.MetaInvoice memory metaInv = intermediatedPP.getMetaInvoice(metaInvoiceId);

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

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param,) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, _testPaymentTokens());

        uint216 invoiceId = intermediatedPP.createMetaInvoice(param);

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(mockUsdc), _priceO + _priceT);

        _executePayment(buyerOne, invoiceId, tokenValue);

        assertApproxEqAbs(mockUsdc.allowance(buyerOne, address(intermediatedPP)), 0, 2);
    }

    function test_releasePayment(uint256 _price, uint256 _sellerShare) public {
        _price = bound(_price, 1e8, 100e8);
        _sellerShare = bound(_sellerShare, 0, BASIS_POINTS);

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(intermediatedPP.getNextInvoiceNonce(), sellerOne, _price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        uint256 balanceBefore = sellerOne.balance;
        vm.warp(block.timestamp + 1 days);
        intermediatedPP.release(invoiceId);

        uint256 expectedValue = tokenValue - ((tokenValue * FEE_RATE) / BASIS_POINTS);

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);
        assertEq(inv.state, RELEASED);
        assertEq(sellerOne.balance, expectedValue + balanceBefore);
    }

    function test_handleDispute(uint256 _price, uint256 _resolution, uint256 _sellerShare) public {
        _price = bound(_price, 1e8, 100e8);
        _resolution = bound(_resolution, DISPUTE_DISMISSED, DISPUTE_SETTLED);
        _sellerShare = bound(_sellerShare, 0, BASIS_POINTS);

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(intermediatedPP.getNextInvoiceNonce(), sellerOne, _price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        intermediatedPP.createDispute(invoiceId);

        intermediatedPP.handleDispute(invoiceId, _resolution.toUint8(), _sellerShare);

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);
        assertEq(inv.state, _resolution);
    }

    function test_getTokenValueFromUsd(uint256 _price) public view {
        _price = bound(_price, 1e8, type(uint256).max / 1e18);
        uint256 val = intermediatedPP.getTokenValueFromUsd(address(0), _price);
        assertGt(val, 0);
    }

    function test_payInvoiceWithERC20(uint256 _price) public {
        _price = bound(_price, 1e8, 100e8);

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(mockUsdc), _price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice(
            invoiceId, address(mockUsdc), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);
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

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory subInvoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, _testPaymentTokens());

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(param);
        uint256 totalEth = intermediatedPP.getTokenValueFromUsd(address(0), _priceO + _priceT);

        {
            address[] memory metaReceivers12 = _metaReceivers(metaInvoiceId);
            bytes memory metaFeeSig12 = _metaFeeSig(metaInvoiceId);
            vm.prank(buyerOne);
            intermediatedPP.payMetaInvoiceWithValue{ value: totalEth }(metaInvoiceId, metaReceivers12, metaFeeSig12);
        }

        IIntermediatedPaymentProcessor.Invoice memory inv0 = intermediatedPP.getInvoice(subInvoiceIds[0]);
        IIntermediatedPaymentProcessor.Invoice memory inv1 = intermediatedPP.getInvoice(subInvoiceIds[1]);

        assertEq(inv0.state, PAID);
        assertEq(inv1.state, PAID);
        assertEq(inv0.buyer, buyerOne);
        assertEq(inv1.buyer, buyerOne);
        assertLe(inv0.escrow.balance + inv1.escrow.balance, totalEth);
    }

    function test_partialRefund(uint256 _price, uint256 _refundShare) public {
        _price = bound(_price, 1e8, 100e8);
        _refundShare = bound(_refundShare, 1, BASIS_POINTS - 1); // partial, not full

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        uint256 expectedRefund = (tokenValue * _refundShare) / BASIS_POINTS;
        uint256 buyerBefore = buyerOne.balance;

        intermediatedPP.refund(invoiceId, _refundShare);

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);
        assertEq(inv.state, PAID);
        assertEq(inv.balance, tokenValue - expectedRefund);
        assertEq(buyerOne.balance, buyerBefore + expectedRefund);
    }

    function test_disputeSettledFundDistribution(uint256 _price, uint256 _sellerShare) public {
        _price = bound(_price, 1e8, 100e8);
        _sellerShare = bound(_sellerShare, 0, BASIS_POINTS);

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        intermediatedPP.createDispute(invoiceId);

        uint256 sellerBefore = sellerOne.balance;
        uint256 buyerBefore = buyerOne.balance;
        uint256 feeReceiverBefore = feeReceiver.balance;

        intermediatedPP.handleDispute(invoiceId, uint8(DISPUTE_SETTLED), _sellerShare);

        uint256 buyerRefund = (tokenValue * (BASIS_POINTS - _sellerShare)) / BASIS_POINTS;
        uint256 sellerGross = tokenValue - buyerRefund;
        uint256 fee = (sellerGross * FEE_RATE) / BASIS_POINTS;

        assertEq(sellerOne.balance, sellerBefore + sellerGross - fee);
        assertEq(buyerOne.balance, buyerBefore + buyerRefund);
        assertEq(feeReceiver.balance, feeReceiverBefore + fee);

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);
        assertEq(inv.state, DISPUTE_SETTLED);
        assertEq(inv.balance, 0);
        assertEq(inv.escrow.balance, 0);
    }

    function test_setInvoiceReleaseTime(uint256 _price, uint256 _holdPeriod) public {
        _price = bound(_price, 1e8, 100e8);
        _holdPeriod = bound(_holdPeriod, 1, type(uint32).max / 2);

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        uint256 expectedReleaseAt = block.timestamp + _holdPeriod;

        vm.prank(admin);
        intermediatedPP.setInvoiceReleaseTime(invoiceId, _holdPeriod);

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);
        assertEq(inv.releaseAt, expectedReleaseAt);

        vm.warp(expectedReleaseAt + 1);
        intermediatedPP.release(invoiceId);

        inv = intermediatedPP.getInvoice(invoiceId);
        assertEq(inv.state, RELEASED);
    }

    function test_payInvoiceErc20RejectsNonZeroMsgValue(uint256 _price, uint256 _wrongValue) public {
        _price = bound(_price, 1e8, 100e8);
        _wrongValue = bound(_wrongValue, 1, 100 ether);

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price, _testPaymentTokens())
        );

        vm.prank(buyerOne);
        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidNativePayment.selector);
        intermediatedPP.payInvoice{ value: _wrongValue }(
            invoiceId, address(mockUsdc), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );
    }

    function test_resolveDisputeAndRelease(uint256 _price) public {
        _price = bound(_price, 1e8, 100e8);

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        IIntermediatedPaymentProcessor.Invoice memory inv = intermediatedPP.getInvoice(invoiceId);
        uint256 originalReleaseAt = inv.releaseAt;

        intermediatedPP.createDispute(invoiceId);
        intermediatedPP.resolveDispute(invoiceId);

        inv = intermediatedPP.getInvoice(invoiceId);
        assertEq(inv.state, DISPUTE_RESOLVED);

        vm.warp(originalReleaseAt + 1);

        uint256 sellerBefore = sellerOne.balance;
        uint256 expectedFee = (tokenValue * FEE_RATE) / BASIS_POINTS;

        intermediatedPP.release(invoiceId);

        inv = intermediatedPP.getInvoice(invoiceId);
        assertEq(inv.state, RELEASED);
        assertEq(inv.balance, 0);
        assertEq(sellerOne.balance, sellerBefore + tokenValue - expectedFee);
    }

    function test_decimal() public view {
        uint8 decimal = intermediatedPP._getDecimals(address(0));
        assertEq(decimal, DEFAULT_DECIMAL);
    }

    function _executePayment(address _buyer, uint216 _invoiceId, uint256 _tokenValue) internal {
        mockUsdc.mint(_buyer, INITIAL_BALANCE);

        vm.startPrank(_buyer);
        mockUsdc.approve(address(intermediatedPP), _tokenValue);
        {
            address[] memory metaReceivers13 = _metaReceivers(_invoiceId);
            bytes memory metaFeeSig13 = _metaFeeSig(_invoiceId);
            intermediatedPP.payMetaInvoice(_invoiceId, address(mockUsdc), metaReceivers13, metaFeeSig13);
        }
        vm.stopPrank();
    }

    // ================================================================
    //                              PAUSE
    // ================================================================

    function test_pauseBlocksEveryValueMovingEntrypoint() public {
        uint256 price = 10e8;

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), price);
        vm.prank(buyerTwo);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        // Build args before arming expectRevert: inner staticcalls would otherwise consume it.
        IIntermediatedPaymentProcessor.InvoiceCreationParam memory param =
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens());
        IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory params =
            new IIntermediatedPaymentProcessor.InvoiceCreationParam[](1);
        params[0] = param;

        vm.prank(admin);
        ppStorage.pause();

        vm.expectRevert(IIntermediatedPaymentProcessor.ContractPaused.selector);
        intermediatedPP.createSingleInvoice(param);

        vm.expectRevert(IIntermediatedPaymentProcessor.ContractPaused.selector);
        intermediatedPP.createMetaInvoice(params);

        vm.prank(buyerTwo);
        vm.expectRevert(IIntermediatedPaymentProcessor.ContractPaused.selector);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        {
            address[] memory metaReceivers14 = _metaReceivers(invoiceId);
            bytes memory metaFeeSig14 = _metaFeeSig(invoiceId);
            vm.prank(buyerTwo);
            vm.expectRevert(IIntermediatedPaymentProcessor.ContractPaused.selector);
            intermediatedPP.payMetaInvoiceWithValue(invoiceId, metaReceivers14, metaFeeSig14);
        }

        {
            address[] memory metaReceivers15 = _metaReceivers(invoiceId);
            bytes memory metaFeeSig15 = _metaFeeSig(invoiceId);
            vm.prank(buyerTwo);
            vm.expectRevert(IIntermediatedPaymentProcessor.ContractPaused.selector);
            intermediatedPP.payMetaInvoice(invoiceId, address(0), metaReceivers15, metaFeeSig15);
        }

        vm.expectRevert(IIntermediatedPaymentProcessor.ContractPaused.selector);
        intermediatedPP.createDispute(invoiceId);

        vm.expectRevert(IIntermediatedPaymentProcessor.ContractPaused.selector);
        intermediatedPP.handleDispute(invoiceId, DISPUTE_RESOLVED, BASIS_POINTS);

        vm.expectRevert(IIntermediatedPaymentProcessor.ContractPaused.selector);
        intermediatedPP.release(invoiceId);

        vm.expectRevert(IIntermediatedPaymentProcessor.ContractPaused.selector);
        intermediatedPP.refund(invoiceId, BASIS_POINTS);
    }

    function test_pauseLeavesCancelInvoiceOpen() public {
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, 10e8, _testPaymentTokens())
        );

        vm.prank(admin);
        ppStorage.pause();

        intermediatedPP.cancelInvoice(invoiceId);

        assertEq(intermediatedPP.getInvoice(invoiceId).state, CANCELED);
    }

    function test_unpauseRestoresNormalFlow() public {
        vm.startPrank(admin);
        ppStorage.pause();
        ppStorage.unpause();
        vm.stopPrank();

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, 10e8, _testPaymentTokens())
        );

        assertEq(intermediatedPP.getInvoice(invoiceId).state, CREATED);
    }

    function test_lapsedEmergencyPauseStopsBlocking() public {
        address pauser = address(0x9a);
        vm.prank(admin);
        ppStorage.setEmergencyPauser(pauser);

        vm.prank(pauser);
        ppStorage.emergencyPause();

        IIntermediatedPaymentProcessor.InvoiceCreationParam memory param =
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, 10e8, _testPaymentTokens());

        vm.expectRevert(IIntermediatedPaymentProcessor.ContractPaused.selector);
        intermediatedPP.createSingleInvoice(param);

        vm.warp(block.timestamp + ppStorage.EMERGENCY_PAUSE_DURATION());

        intermediatedPP.createSingleInvoice(param);
    }

    function test_payInvoiceRequiresAnAuthorizedFeeReceiver() public {
        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), price);
        address attackerFeeReceiver = address(0xbad);

        vm.startPrank(buyerOne);

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidFeeReceiver.selector);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), address(0), _feeSig(address(intermediatedPP), invoiceId, address(0))
        );

        // A valid signature for one receiver does not authorize another.
        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidFeeAuthorization.selector);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), attackerFeeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );

        // Nor does a signature bound to a different invoice.
        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidFeeAuthorization.selector);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId + 1, feeReceiver)
        );

        // Nor does one signed for the other processor.
        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidFeeAuthorization.selector);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(ppStorage), invoiceId, feeReceiver)
        );

        vm.expectEmit(address(intermediatedPP));
        emit IIntermediatedPaymentProcessor.InvoicePaid(
            invoiceId,
            address(0),
            intermediatedPP.getEscrowAddress(sellerOne, buyerOne, invoiceId),
            tokenValue,
            uint40(block.timestamp + TEST_ESCROW_HOLD_PERIOD),
            feeReceiver
        );
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), feeReceiver, _feeSig(address(intermediatedPP), invoiceId, feeReceiver)
        );
        vm.stopPrank();

        assertEq(intermediatedPP.getInvoice(invoiceId).feeReceiver, feeReceiver);
    }

    function test_releasePaysTheInvoicesAuthorizedFeeReceiver() public {
        uint256 price = 100e8;
        address invoiceFeeReceiver = address(0xfee5);

        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, _testPaymentTokens())
        );

        uint256 tokenValue = intermediatedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        intermediatedPP.payInvoice{ value: tokenValue }(
            invoiceId, address(0), invoiceFeeReceiver, _feeSig(address(intermediatedPP), invoiceId, invoiceFeeReceiver)
        );

        uint256 fee = applyBasisPoints(intermediatedPP.getInvoice(invoiceId).balance, FEE_RATE);
        uint256 globalFeeReceiverBalance = feeReceiver.balance;

        vm.warp(block.timestamp + TEST_ESCROW_HOLD_PERIOD + 1);
        intermediatedPP.release(invoiceId);

        assertEq(invoiceFeeReceiver.balance, fee);
        assertEq(feeReceiver.balance, globalFeeReceiverBalance, "global fee receiver should not be paid");
    }

    function test_metaInvoiceGivesEachSubInvoiceItsOwnFeeReceiver() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 100e8;
        prices[1] = 50e8;

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory params, uint216[] memory subInvoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, _testPaymentTokens());

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(params);

        address[] memory receivers = new address[](2);
        receivers[0] = address(0xfee1);
        receivers[1] = address(0xfee2);

        uint256 totalValue = intermediatedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);
        bytes memory sig = _feeSigMeta(address(intermediatedPP), metaInvoiceId, receivers);

        vm.prank(buyerOne);
        intermediatedPP.payMetaInvoiceWithValue{ value: totalValue }(metaInvoiceId, receivers, sig);

        // One signature, but each sub-invoice keeps its own receiver.
        assertEq(intermediatedPP.getInvoice(subInvoiceIds[0]).feeReceiver, receivers[0]);
        assertEq(intermediatedPP.getInvoice(subInvoiceIds[1]).feeReceiver, receivers[1]);

        uint256 feeOne = applyBasisPoints(intermediatedPP.getInvoice(subInvoiceIds[0]).balance, FEE_RATE);
        uint256 feeTwo = applyBasisPoints(intermediatedPP.getInvoice(subInvoiceIds[1]).balance, FEE_RATE);

        vm.warp(block.timestamp + TEST_ESCROW_HOLD_PERIOD + 1);
        intermediatedPP.release(subInvoiceIds[0]);
        intermediatedPP.release(subInvoiceIds[1]);

        assertEq(receivers[0].balance, feeOne);
        assertEq(receivers[1].balance, feeTwo);
    }

    function test_metaInvoiceRejectsAMismatchedOrTamperedFeeReceiverArray() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 100e8;
        prices[1] = 50e8;

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory params,) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, _testPaymentTokens());

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(params);
        uint256 totalValue = intermediatedPP.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        address[] memory receivers = new address[](2);
        receivers[0] = address(0xfee1);
        receivers[1] = address(0xfee2);
        bytes memory sig = _feeSigMeta(address(intermediatedPP), metaInvoiceId, receivers);

        address[] memory tooFew = new address[](1);
        tooFew[0] = address(0xfee1);

        // Reordering the array invalidates the one signature that covers it.
        address[] memory swapped = new address[](2);
        swapped[0] = receivers[1];
        swapped[1] = receivers[0];

        address[] memory withZero = new address[](2);
        withZero[0] = address(0xfee1);

        vm.startPrank(buyerOne);

        vm.expectRevert(abi.encodeWithSelector(IIntermediatedPaymentProcessor.FeeReceiverCountMismatch.selector, 1, 2));
        intermediatedPP.payMetaInvoiceWithValue{ value: totalValue }(metaInvoiceId, tooFew, sig);

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidFeeReceiver.selector);
        intermediatedPP.payMetaInvoiceWithValue{ value: totalValue }(metaInvoiceId, withZero, sig);

        vm.expectRevert(IIntermediatedPaymentProcessor.InvalidFeeAuthorization.selector);
        intermediatedPP.payMetaInvoiceWithValue{ value: totalValue }(metaInvoiceId, swapped, sig);

        intermediatedPP.payMetaInvoiceWithValue{ value: totalValue }(metaInvoiceId, receivers, sig);
        vm.stopPrank();
    }

    function test_setFeeSigner() public {
        vm.expectRevert();
        ppStorage.setFeeSigner(address(0xa11ce));

        vm.startPrank(admin);
        vm.expectRevert(IPaymentProcessorStorage.InvalidFeeSigner.selector);
        ppStorage.setFeeSigner(address(0));

        vm.expectEmit(address(ppStorage));
        emit IPaymentProcessorStorage.FeeSignerUpdated(address(0xa11ce));
        ppStorage.setFeeSigner(address(0xa11ce));
        vm.stopPrank();

        assertEq(ppStorage.getFeeSigner(), address(0xa11ce));
    }

    function test_onlyListedPaymentTokensAreAccepted() public {
        address[] memory usdcOnly = new address[](1);
        usdcOnly[0] = address(mockUsdc);

        uint256 price = 100e8;
        uint216 invoiceId = intermediatedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price, usdcOnly)
        );

        assertTrue(intermediatedPP.isPaymentTokenAllowed(invoiceId, address(mockUsdc)));
        assertFalse(intermediatedPP.isPaymentTokenAllowed(invoiceId, address(0)), "native was not listed");
        assertFalse(intermediatedPP.isPaymentTokenAllowed(invoiceId, address(mockWBtc)));

        uint256 nativeValue = intermediatedPP.getTokenValueFromUsd(address(0), price);
        bytes memory sig = _feeSig(address(intermediatedPP), invoiceId, feeReceiver);

        vm.startPrank(buyerOne);

        // Native currency is a listed-token decision, not a special case.
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntermediatedPaymentProcessor.PaymentTokenNotAllowed.selector, invoiceId, address(0)
            )
        );
        intermediatedPP.payInvoice{ value: nativeValue }(invoiceId, address(0), feeReceiver, sig);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntermediatedPaymentProcessor.PaymentTokenNotAllowed.selector, invoiceId, address(mockWBtc)
            )
        );
        intermediatedPP.payInvoice(invoiceId, address(mockWBtc), feeReceiver, sig);

        mockUsdc.approve(address(intermediatedPP), type(uint256).max);
        intermediatedPP.payInvoice(invoiceId, address(mockUsdc), feeReceiver, sig);
        vm.stopPrank();

        assertEq(intermediatedPP.getInvoice(invoiceId).paymentToken, address(mockUsdc));
    }

    function test_createInvoiceRequiresAtLeastOnePaymentToken() public {
        // Built first: expectRevert applies to the next call, which getNextInvoiceNonce would otherwise be.
        IIntermediatedPaymentProcessor.InvoiceCreationParam memory param =
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, 100e8, new address[](0));

        vm.expectRevert(IIntermediatedPaymentProcessor.NoPaymentTokens.selector);
        intermediatedPP.createSingleInvoice(param);
    }

    function test_metaInvoicePaymentRejectsATokenASubInvoiceDoesNotAccept() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 100e8;
        prices[1] = 50e8;

        address[] memory nativeOnly = new address[](1);
        nativeOnly[0] = address(0);

        (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory params, uint216[] memory subInvoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices, nativeOnly);

        // Widen only the first sub-invoice, so the pair disagree on what they accept.
        params[0].paymentTokens = _testPaymentTokens();

        uint216 metaInvoiceId = intermediatedPP.createMetaInvoice(params);

        address[] memory receivers = _metaReceivers(metaInvoiceId);
        bytes memory sig = _metaFeeSig(metaInvoiceId);

        vm.startPrank(buyerOne);
        mockUsdc.approve(address(intermediatedPP), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntermediatedPaymentProcessor.PaymentTokenNotAllowed.selector, subInvoiceIds[1], address(mockUsdc)
            )
        );
        intermediatedPP.payMetaInvoice(metaInvoiceId, address(mockUsdc), receivers, sig);
        vm.stopPrank();
    }
}
