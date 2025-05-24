// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentProcessorV2 } from "../../src/interface/IPaymentProcessorV2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";

import { V2 } from "../util/V2.sol";

contract PaymentProcessorV2Test is V2 {
    function test_Initialization() public view {
        assertEq(pp.getNextInvoiceId(), 1);
        assertEq(pp.getNextMetaInvoiceId(), 1);
    }

    function test_singleInvoiceCreation() public {
        uint256 price = 100e8;

        vm.prank(buyerOne);
        vm.expectRevert(IPaymentProcessorV2.NotAuthorized.selector);
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));

        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        uint256 nextInvoiceId = pp.getNextInvoiceId();
        IPaymentProcessorV2.Invoice memory inv = pp.getInvoice(nextInvoiceId - 1);
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

        uint256 startInvoiceId = pp.getNextInvoiceId();
        pp.createMetaInvoice(
            buyerOne, _getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        uint256 thisMetaInvoiceId = pp.getNextMetaInvoiceId() - 1;
        uint256 upper = pp.getNextInvoiceId() - 1;

        IPaymentProcessorV2.MetaInvoice memory metaInv = pp.getMetaInvoice(thisMetaInvoiceId);
        IPaymentProcessorV2.Invoice memory inv = pp.getInvoice(upper);

        assertEq(inv.price, prices[1]);
        assertEq(inv.buyer, buyerOne);
        assertEq(inv.seller, sellerTwo);
        assertEq(inv.createdAt, block.timestamp);
        assertEq(inv.metaInvoiceId, thisMetaInvoiceId);
        assertEq(pp.getNextInvoiceId(), upper + 1);

        assertEq(thisMetaInvoiceId, 1);
        assertEq(pp.getMetaInvoiceIdForSub(upper), thisMetaInvoiceId);
        assertEq(pp.getMetaInvoiceIdForSub(startInvoiceId), thisMetaInvoiceId);
        assertEq(metaInv.price, prices[0] + prices[1]);
        assertEq(metaInv.upper, upper);
        assertEq(metaInv.lower, startInvoiceId);
    }

    function test_nativeTokenPaymentForSingleInvoice() public {
        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        uint256 thisInvoiceId = pp.totalUniqueInvoiceCreated();

        vm.startPrank(buyerOne);

        vm.expectRevert(IPaymentProcessorV2.InvalidPaymentToken.selector);
        pp.paySingleInvoice(thisInvoiceId, address(12));

        vm.expectRevert(IPaymentProcessorV2.InvalidNativePayment.selector);
        pp.paySingleInvoice{ value: 0.001 ether }(thisInvoiceId, address(0));

        uint256 amountInToken = pp.getTokenValueFromUsd(address(0), price);
        pp.paySingleInvoice{ value: amountInToken }(thisInvoiceId, address(0));
        vm.stopPrank();

        IPaymentProcessorV2.Invoice memory inv = pp.getInvoice(thisInvoiceId);

        assertEq(inv.escrow.balance, amountInToken);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, pp.PAID());

        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));

        uint256 currentId = pp.totalUniqueInvoiceCreated();

        vm.warp(block.timestamp + 1 + 1 days);
        vm.expectRevert(IPaymentProcessorV2.InvoiceExpired.selector);
        pp.paySingleInvoice{ value: price }(currentId, address(0));
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

        uint256 thisInvoiceId = pp.getNextInvoiceId();
        pp.createMetaInvoice(
            buyerOne, _getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        uint256 tokenAmount = pp.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.expectRevert(IPaymentProcessorV2.InvoiceDoesNotExist.selector);
        pp.payMetaInvoice{ value: 0.03 ether }(10, address(0));

        vm.expectRevert(IPaymentProcessorV2.InvalidBuyer.selector);
        pp.payMetaInvoice{ value: tokenAmount }(thisInvoiceId, address(0));

        vm.startPrank(buyerOne);
        vm.expectRevert(IPaymentProcessorV2.InvalidMetaInvoicePayment.selector);
        pp.payMetaInvoice{ value: 0.01 ether }(thisInvoiceId, address(0));

        vm.expectRevert(IPaymentProcessorV2.InvalidPaymentToken.selector);
        pp.payMetaInvoice(thisInvoiceId, address(12));

        pp.payMetaInvoice{ value: tokenAmount }(thisInvoiceId, address(0));

        vm.stopPrank();

        IPaymentProcessorV2.Invoice memory invOne = pp.getInvoice(thisInvoiceId);
        address escrowOne = _getEscrowAddress(invOne.seller, invOne.buyer, thisInvoiceId);

        assertEq(invOne.state, pp.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(invOne.escrow.balance, pp.getTokenValueFromUsd(address(0), prices[0]));
        assertEq(invOne.paymentToken, address(0));

        IPaymentProcessorV2.Invoice memory invTwo = pp.getInvoice(pp.getNextInvoiceId() - 1);
        address escrowTwo = _getEscrowAddress(invTwo.seller, invTwo.buyer, pp.getNextInvoiceId() - 1);

        assertEq(invTwo.state, pp.PAID());
        assertEq(invTwo.escrow, escrowTwo);
        assertEq(invTwo.escrow.balance, pp.getTokenValueFromUsd(address(0), prices[1]));
        assertEq(invTwo.paymentToken, address(0));
    }

    function test_erc20PaymentForSingleInvoice() public {
        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        uint256 invoiceId = pp.getNextInvoiceId() - 1;

        vm.prank(buyerTwo);
        vm.expectRevert(IPaymentProcessorV2.InvalidBuyer.selector);
        pp.paySingleInvoice(invoiceId, address(mockUsdc));

        vm.prank(buyerOne);
        pp.paySingleInvoice(invoiceId, address(mockUsdc));

        vm.prank(buyerOne);
        vm.expectRevert(IPaymentProcessorV2.InvalidInvoiceState.selector);
        pp.paySingleInvoice(invoiceId, address(mockUsdc));

        IPaymentProcessorV2.Invoice memory inv = pp.getInvoice(invoiceId);

        uint256 tokenValue = pp.getTokenValueFromUsd(address(mockUsdc), price);

        assertEq(IERC20(mockUsdc).balanceOf(inv.escrow), tokenValue);
        assertEq(inv.paymentToken, address(mockUsdc));
        assertEq(inv.state, pp.PAID());
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

        uint256 thisInvoiceId = pp.getNextInvoiceId();
        pp.createMetaInvoice(
            buyerOne, _getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        vm.prank(buyerOne);

        pp.payMetaInvoice(thisInvoiceId, address(mockWBtc));

        IPaymentProcessorV2.Invoice memory invOne = pp.getInvoice(thisInvoiceId);
        address escrowOne = _getEscrowAddress(invOne.seller, invOne.buyer, thisInvoiceId);

        assertEq(invOne.state, pp.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(IERC20(mockWBtc).balanceOf(invOne.escrow), pp.getTokenValueFromUsd(address(mockWBtc), prices[0]));
        assertEq(invOne.paymentToken, address(mockWBtc));

        IPaymentProcessorV2.Invoice memory invTwo = pp.getInvoice(pp.getNextInvoiceId() - 1);
        address escrowTwo = _getEscrowAddress(invTwo.seller, invTwo.buyer, pp.getNextInvoiceId() - 1);

        assertEq(invTwo.state, pp.PAID());
        assertEq(invTwo.escrow, escrowTwo);
        assertEq(IERC20(mockWBtc).balanceOf(invTwo.escrow), pp.getTokenValueFromUsd(address(mockWBtc), prices[1]));
        assertEq(invTwo.paymentToken, address(mockWBtc));
    }

    function test_sellerAcceptsInvoice() public {
        // single Invoice

        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));

        uint256 currentId = pp.totalUniqueInvoiceCreated();

        vm.prank(sellerOne);
        vm.expectRevert(IPaymentProcessorV2.InvalidInvoiceState.selector);
        pp.acceptInvoice(currentId);

        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        pp.paySingleInvoice{ value: tokenValue }(currentId, address(0));

        assertEq(pp.getInvoice(currentId).state, pp.PAID());

        vm.prank(sellerTwo);
        vm.expectRevert(IPaymentProcessorV2.UnauthorizedSeller.selector);
        pp.acceptInvoice(currentId);

        vm.prank(sellerOne);
        pp.acceptInvoice(currentId);

        assertEq(pp.getInvoice(currentId).state, pp.ACCEPTED());

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

        pp.createMetaInvoice(
            buyerTwo, _getInvoiceCreationParams(buyerTwo, sellers, prices, responseTime, disputeWindow)
        );

        uint256 currentMetaId = pp.totalMetaInvoiceCreated();

        uint256 metaInvoiceTokenValue = pp.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.prank(buyerTwo);
        pp.payMetaInvoice{ value: metaInvoiceTokenValue }(currentMetaId, address(0));

        uint256[] memory ids = _getSubInvoiceIdsForMetaInvoice(currentMetaId);

        vm.prank(sellerTwo);
        pp.acceptInvoice(ids);

        for (uint256 i = 0; i < ids.length - 1; i++) {
            assertEq(pp.getInvoice(ids[i]).state, pp.ACCEPTED());
        }

        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        currentId = pp.totalUniqueInvoiceCreated();

        vm.prank(buyerOne);
        pp.paySingleInvoice{ value: tokenValue }(currentId, address(0));

        vm.warp(block.timestamp + 1 + 1 days);

        vm.prank(sellerOne);
        vm.expectRevert(IPaymentProcessorV2.InvoiceResponseTimeExpired.selector);
        pp.acceptInvoice(currentId);
    }

    function test_sellerCancelInitiatedInvoice() public {
        // single invoice
        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));

        uint256 currentId = pp.totalUniqueInvoiceCreated();

        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        pp.paySingleInvoice{ value: tokenValue }(currentId, address(0));

        uint256 buyersBalanceBeforeCancellation = buyerOne.balance;

        vm.prank(sellerTwo);
        vm.expectRevert(IPaymentProcessorV2.UnauthorizedSeller.selector);
        pp.cancelInvoice(currentId);

        vm.prank(sellerOne);
        pp.cancelInvoice(currentId);

        vm.prank(sellerOne);
        vm.expectRevert(IPaymentProcessorV2.InvalidInvoiceState.selector);
        pp.cancelInvoice(currentId);

        uint256 buyersBalanceAfterCancellation = buyerOne.balance;

        IPaymentProcessorV2.Invoice memory invOne = pp.getInvoice(currentId);
        assertEq(invOne.state, pp.CANCELED());
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

        pp.createMetaInvoice(
            buyerOne, _getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        uint256 currentMetaInvoiceId = pp.totalMetaInvoiceCreated();

        tokenValue = pp.getTokenValueFromUsd(address(0), prices[0] + prices[1] + prices[2]);

        vm.prank(buyerOne);
        pp.payMetaInvoice{ value: tokenValue }(currentMetaInvoiceId, address(0));
        buyersBalanceBeforeCancellation = buyerOne.balance;

        uint256[] memory ids = _getSubInvoiceIdsForMetaInvoice(currentMetaInvoiceId);

        vm.prank(sellerOne);
        pp.cancelInvoice(ids);

        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(pp.getInvoice(ids[i]).state, pp.CANCELED());
        }

        assertApproxEqAbs(buyerOne.balance - buyersBalanceBeforeCancellation, tokenValue, 1);
    }

    function test_invoiceCancelationRequest() public {
        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));

        uint256 currentId = pp.totalUniqueInvoiceCreated();
        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), price);

        vm.expectRevert(IPaymentProcessorV2.UnauthorizedBuyer.selector);
        pp.requestCancelation(currentId);

        vm.startPrank(buyerOne);

        vm.expectRevert(IPaymentProcessorV2.InvalidInvoiceState.selector);
        pp.requestCancelation(currentId);

        pp.paySingleInvoice{ value: tokenValue }(currentId, address(0));

        pp.requestCancelation(currentId);

        vm.stopPrank();
        assertEq(pp.getInvoice(currentId).state, pp.CANCELATION_REQUESTED());

        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        currentId = pp.totalUniqueInvoiceCreated();

        vm.startPrank(buyerOne);
        pp.paySingleInvoice{ value: tokenValue }(currentId, address(0));

        vm.warp(block.timestamp + 1 + 1 days);
        vm.expectRevert(IPaymentProcessorV2.CancelationRequestDeadlinePassed.selector);
        pp.requestCancelation(currentId);

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

        pp.createMetaInvoice(
            buyerOne, _getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );

        uint256 totalPrice = prices[0] + prices[1] + prices[2];

        uint256 currentMetaInvoiceId = pp.totalMetaInvoiceCreated();
        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), totalPrice);

        vm.startPrank(buyerOne);
        pp.payMetaInvoice{ value: tokenValue }(currentMetaInvoiceId, address(0));

        uint256[] memory ids = _getSubInvoiceIdsForMetaInvoice(currentMetaInvoiceId);
        pp.requestCancelation(ids);

        vm.startPrank(sellerOne);

        bool[] memory accept = new bool[](ids.length);
        accept[0] = true; // + 0.01 ether
        accept[1] = false;
        accept[2] = false;

        uint256 buyersBalanceBefore = buyerOne.balance;
        for (uint256 i = 0; i < ids.length; ++i) {
            pp.handleCancelationRequest(ids[i], accept[i]);
        }

        assertEq(buyerOne.balance, buyersBalanceBefore + pp.getTokenValueFromUsd(address(0), prices[0]));
        assertEq(pp.getInvoice(ids[0]).state, pp.CANCELATION_ACCEPTED());
        assertEq(pp.getInvoice(ids[1]).state, pp.CANCELATION_REJECTED());
        assertEq(pp.getInvoice(ids[2]).state, pp.CANCELATION_REJECTED());
    }

    function test_refundAfterInvoiceExpires() public {
        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        uint256 id = pp.totalUniqueInvoiceCreated();

        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        pp.paySingleInvoice{ value: tokenValue }(id, address(0));

        vm.prank(buyerTwo);
        vm.expectRevert(IPaymentProcessorV2.UnauthorizedBuyer.selector);
        pp.claimExpiredInvoiceRefunds(id);

        vm.startPrank(buyerOne);
        vm.expectRevert(IPaymentProcessorV2.InvoiceStillActive.selector);
        pp.claimExpiredInvoiceRefunds(id);

        uint256 balanceBefore = buyerOne.balance;
        vm.warp(block.timestamp + 1 + 1 days);
        pp.claimExpiredInvoiceRefunds(id);

        vm.expectRevert(IPaymentProcessorV2.AlreadyRefunded.selector);
        pp.claimExpiredInvoiceRefunds(id);
        vm.stopPrank();

        assertEq(pp.getInvoice(id).state, pp.REFUNDED());
        assertEq(pp.getInvoice(id).amountPaid + balanceBefore, buyerOne.balance);

        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        id = pp.totalUniqueInvoiceCreated();

        vm.prank(buyerOne);
        pp.paySingleInvoice{ value: tokenValue }(id, address(0));

        vm.prank(sellerOne);
        pp.acceptInvoice(id);

        vm.prank(buyerOne);
        vm.expectRevert(IPaymentProcessorV2.InvalidInvoiceState.selector);
        pp.claimExpiredInvoiceRefunds(id);
    }

    function test_disputeCreation() public {
        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        uint256 id = pp.totalUniqueInvoiceCreated();
        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), price);

        vm.expectRevert(IPaymentProcessorV2.UnauthorizedBuyer.selector);
        pp.createDispute(id);

        vm.startPrank(buyerOne);
        vm.expectRevert(IPaymentProcessorV2.InvalidInvoiceState.selector);
        pp.createDispute(id);

        pp.paySingleInvoice{ value: tokenValue }(id, address(0));
        vm.stopPrank();

        vm.prank(sellerOne);
        pp.acceptInvoice(id);

        vm.warp(block.timestamp + 25 hours);

        vm.startPrank(buyerOne);
        vm.expectRevert(IPaymentProcessorV2.DisputeWindowExpired.selector);
        pp.createDispute(id);

        vm.warp(block.timestamp - 20 hours);
        pp.createDispute(id);
        vm.stopPrank();

        assertEq(pp.getInvoice(id).state, pp.DISPUTED());
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

        pp.createMetaInvoice(
            buyerOne, _getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow)
        );
        uint256 metaInvoiceId = pp.totalMetaInvoiceCreated();

        uint256[] memory ids = _getSubInvoiceIdsForMetaInvoice(metaInvoiceId);

        vm.prank(buyerOne);
        pp.payMetaInvoice(metaInvoiceId, address(mockUsdc));

        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            IPaymentProcessorV2.Invoice memory inv = pp.getInvoice(id);
            vm.prank(inv.seller);
            pp.acceptInvoice(id);

            vm.prank(buyerOne);
            pp.createDispute(id);
        }

        uint8 dismissed = pp.DISPUTE_DISMISSED();
        uint8 resolved = pp.DISPUTE_RESOLVED();

        vm.prank(buyerOne);
        vm.expectRevert(IPaymentProcessorV2.NotAuthorized.selector);
        pp.resolveDispute(ids[0], dismissed, 0);

        pp.resolveDispute(ids[0], dismissed, 0);

        pp.resolveDispute(ids[1], resolved, 0);

        assertEq(pp.getInvoice(ids[0]).state, dismissed);
        assertEq(pp.getInvoice(ids[1]).state, resolved);
    }

    function test_settledDispute() public {
        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        uint256 id = pp.totalUniqueInvoiceCreated();
        uint256 tokenValue = pp.getTokenValueFromUsd(address(mockUsdc), price);

        vm.prank(buyerOne);
        pp.paySingleInvoice(id, address(mockUsdc));

        vm.prank(sellerOne);
        pp.acceptInvoice(id);

        uint256 basisPoint = pp.BASIS_POINTS();
        uint8 dismissed = pp.DISPUTE_DISMISSED();
        uint8 settled = pp.DISPUTE_SETTLED();
        uint8 accepted = pp.ACCEPTED();
        vm.expectRevert(IPaymentProcessorV2.InvalidInvoiceState.selector);
        pp.resolveDispute(id, dismissed, basisPoint);

        vm.prank(buyerOne);
        pp.createDispute(id);

        uint256 buyerBalanceBefore = IERC20(mockUsdc).balanceOf(buyerOne);
        uint256 sellerBalanceBefore = IERC20(mockUsdc).balanceOf(sellerOne);

        console.log("balances before", buyerBalanceBefore, sellerBalanceBefore);

        uint256 sellerPercentage = 9000;

        vm.expectRevert(IPaymentProcessorV2.InvalidSellersPayoutShare.selector);
        pp.resolveDispute(id, settled, basisPoint + 1);

        vm.expectRevert(IPaymentProcessorV2.InvalidDisputeResolution.selector);
        pp.resolveDispute(id, accepted, sellerPercentage);

        pp.resolveDispute(id, settled, sellerPercentage);

        uint256 buyerShare = _applyBasisPoints(tokenValue, pp.BASIS_POINTS() - sellerPercentage);

        uint256 sellerShare = _applyBasisPoints(tokenValue, sellerPercentage);
        uint256 fee = _applyBasisPoints(sellerShare, FEE);

        console.log("balances after", IERC20(mockUsdc).balanceOf(buyerOne), IERC20(mockUsdc).balanceOf(sellerOne));

        assertEq(pp.getInvoice(id).state, pp.DISPUTE_SETTLED());
        assertEq(IERC20(mockUsdc).balanceOf(sellerOne), sellerBalanceBefore + sellerShare - fee);
        assertEq(IERC20(mockUsdc).balanceOf(buyerOne), buyerBalanceBefore + buyerShare);
        assertEq(IERC20(mockUsdc).balanceOf(feeReceiver), fee);
    }

    // @audit time factor
    function test_invoiceRelease() public {
        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), price);

        uint256 id = pp.totalUniqueInvoiceCreated();

        vm.expectRevert(IPaymentProcessorV2.InvalidInvoiceState.selector);
        pp.releasePayment(id);

        vm.prank(buyerOne);
        pp.paySingleInvoice{ value: tokenValue }(id, address(0));

        vm.expectRevert(IPaymentProcessorV2.InvalidInvoiceState.selector);
        pp.releasePayment(id);

        vm.prank(sellerOne);
        pp.acceptInvoice(id);

        pp.releasePayment(id);

        vm.expectRevert(IPaymentProcessorV2.InvalidInvoiceState.selector);
        pp.releasePayment(id);

        assertEq(pp.getInvoice(id).state, pp.RELEASED());
    }

    function test_justRandom() public view {
        uint256 value = pp.getTokenValueFromUsd(address(mockUsdc), 100e8);
        console.log("Value is", value);
    }

    function _applyBasisPoints(uint256 amount, uint256 basisPoints) internal view returns (uint256) {
        return (amount * basisPoints) / pp.BASIS_POINTS();
    }

    function _getSubInvoiceIdsForMetaInvoice(uint256 metaInvoiceId) internal view returns (uint256[] memory) {
        IPaymentProcessorV2.MetaInvoice memory meta = pp.getMetaInvoice(metaInvoiceId);
        uint256 count = meta.upper - meta.lower + 1;
        uint256[] memory ids = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            ids[i] = meta.lower + i;
        }

        return ids;
    }

    function _getEscrowAddress(address seller, address buyer, uint256 invoiceId) internal view returns (address) {
        bytes32 salt = pp.computeSalt(seller, buyer, invoiceId);
        return pp.getPredictedAddress(salt);
    }

    function _getInvoiceCreationParam(
        address seller,
        address buyer,
        uint256 price,
        uint32 timeBeforeCancelation,
        uint32 releaseWindow
    ) internal pure returns (IPaymentProcessorV2.InvoiceCreationParam memory) {
        IPaymentProcessorV2.InvoiceCreationParam memory param;
        param.seller = seller;
        param.buyer = buyer;
        param.price = price;
        param.timeBeforeCancelation = timeBeforeCancelation;
        param.releaseWindow = releaseWindow;
        param.invoiceExpiryDuration = 1 days;

        return param;
    }

    function _getInvoiceCreationParams(
        address buyer,
        address[] memory sellers,
        uint256[] memory prices,
        uint32[] memory timeBeforeCancelation,
        uint32[] memory disputeWindow
    ) internal pure returns (IPaymentProcessorV2.InvoiceCreationParam[] memory) {
        uint256 numberOfInvoice = sellers.length;
        IPaymentProcessorV2.InvoiceCreationParam[] memory params =
            new IPaymentProcessorV2.InvoiceCreationParam[](numberOfInvoice);

        for (uint256 i; i < numberOfInvoice; i++) {
            params[i] =
                _getInvoiceCreationParam(sellers[i], buyer, prices[i], timeBeforeCancelation[i], disputeWindow[i]);
        }
        return params;
    }
}
