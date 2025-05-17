// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console, Vm } from "forge-std/Test.sol";
import { PaymentProcessorV2, Invoice, MetaInvoice, InvoiceCreationParam } from "../../src/PaymentProcessorV2.sol";
import { MockERC20 } from "../mock/mERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PaymentProcessorV2Test is Test {
    PaymentProcessorV2 pp;
    MockERC20 paymentTokenOne;

    address admin = address(1);
    address buyerOne = address(2);
    address buyerTwo = address(3);
    address sellerOne = address(4);
    address sellerTwo = address(5);
    address feeReceiver = address(6);

    uint256 public constant FEE = 500;

    function setUp() public {
        vm.startPrank(admin);
        pp = new PaymentProcessorV2(admin, address(this), FEE, feeReceiver);
        paymentTokenOne = new MockERC20("Payment token", "PTK");

        pp.setPaymentTokenState(address(paymentTokenOne), true);
        vm.stopPrank();

        paymentTokenOne.mint(buyerOne, 100_000 ether);
        paymentTokenOne.mint(buyerTwo, 100_000 ether);

        vm.prank(buyerOne);
        IERC20(paymentTokenOne).approve(address(pp), type(uint256).max);

        vm.prank(buyerTwo);
        IERC20(paymentTokenOne).approve(address(pp), type(uint256).max);

        vm.deal(buyerOne, 100 ether);
        vm.deal(sellerOne, 100 ether);

        vm.deal(buyerTwo, 100 ether);
        vm.deal(sellerTwo, 100 ether);
    }

    function test_Initialization() public view {
        assertEq(pp.getNextInvoiceId(), 1);
        assertEq(pp.getNextMetaInvoiceId(), 1);
    }

    function test_singleInvoiceCreation() public {
        uint256 price = 0.01 ether;

        vm.prank(buyerOne);
        vm.expectRevert(PaymentProcessorV2.NotAuthorized.selector);
        pp.openInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));

        pp.openInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        uint256 nextInvoiceId = pp.getNextInvoiceId();
        Invoice memory inv = pp.getInvoice(nextInvoiceId - 1);
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

        uint256[] memory responseTime = new uint256[](2);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;

        uint256[] memory disputeWindow = new uint256[](2);
        disputeWindow[0] = 2 days;
        disputeWindow[1] = 2 days;

        uint256 startInvoiceId = pp.getNextInvoiceId();
        pp.openMetaInvoice(buyerOne, _getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow));

        uint256 thisMetaInvoiceId = pp.getNextMetaInvoiceId() - 1;
        uint256 upper = pp.getNextInvoiceId() - 1;

        MetaInvoice memory metaInv = pp.getMetaInvoice(thisMetaInvoiceId);
        Invoice memory inv = pp.getInvoice(upper);

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
        uint256 price = 0.01 ether;
        pp.openInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        uint256 thisInvoiceId = pp.getNextInvoiceId() - 1;

        vm.startPrank(buyerOne);

        vm.expectRevert(PaymentProcessorV2.InvalidPaymentToken.selector);
        pp.paySingleInvoice(thisInvoiceId, address(12));

        vm.expectRevert(PaymentProcessorV2.InvalidNativePayment.selector);
        pp.paySingleInvoice{ value: 0.001 ether }(thisInvoiceId, address(0));

        pp.paySingleInvoice{ value: price }(thisInvoiceId, address(0));
        vm.stopPrank();

        Invoice memory inv = pp.getInvoice(thisInvoiceId);

        assertEq(inv.escrow.balance, price);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, pp.PAID());
    }

    function test_nativeTokenPaymentForMetaInvoice() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;

        uint256[] memory responseTime = new uint256[](2);
        responseTime[0] = 1 days;
        responseTime[1] = 5 days;

        uint256[] memory disputeWindow = new uint256[](2);
        disputeWindow[0] = 1 days;
        disputeWindow[1] = 3 days;

        uint256 thisInvoiceId = pp.getNextInvoiceId();
        pp.openMetaInvoice(buyerOne, _getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow));

        vm.expectRevert(PaymentProcessorV2.InvoiceDoesNotExist.selector);
        pp.payMetaInvoice{ value: 0.03 ether }(10, address(0));

        vm.expectRevert(PaymentProcessorV2.InvalidBuyer.selector);
        pp.payMetaInvoice{ value: 0.03 ether }(thisInvoiceId, address(0));

        vm.startPrank(buyerOne);
        vm.expectRevert(PaymentProcessorV2.InvalidMetaInvoicePayment.selector);
        pp.payMetaInvoice{ value: 0.01 ether }(thisInvoiceId, address(0));

        vm.expectRevert(PaymentProcessorV2.InvalidPaymentToken.selector);
        pp.payMetaInvoice(thisInvoiceId, address(12));

        pp.payMetaInvoice{ value: 0.03 ether }(thisInvoiceId, address(0));

        vm.stopPrank();

        Invoice memory invOne = pp.getInvoice(thisInvoiceId);
        address escrowOne = _getEscrowAddress(invOne.seller, invOne.buyer, thisInvoiceId);

        assertEq(invOne.state, pp.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(invOne.escrow.balance, prices[0]);
        assertEq(invOne.paymentToken, address(0));

        Invoice memory invTwo = pp.getInvoice(pp.getNextInvoiceId() - 1);
        address escrowTwo = _getEscrowAddress(invTwo.seller, invTwo.buyer, pp.getNextInvoiceId() - 1);

        assertEq(invTwo.state, pp.PAID());
        assertEq(invTwo.escrow, escrowTwo);
        assertEq(invTwo.escrow.balance, prices[1]);
        assertEq(invTwo.paymentToken, address(0));
    }

    function test_erc20PaymentForSingleInvoice() public {
        uint256 price = 0.01 ether;
        pp.openInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        uint256 thisInvoiceId = pp.getNextInvoiceId() - 1;

        vm.prank(buyerTwo);
        vm.expectRevert(PaymentProcessorV2.InvalidBuyer.selector);
        pp.paySingleInvoice(thisInvoiceId, address(paymentTokenOne));

        vm.prank(buyerOne);
        pp.paySingleInvoice(thisInvoiceId, address(paymentTokenOne));

        vm.prank(buyerOne);
        vm.expectRevert(PaymentProcessorV2.InvalidInvoiceState.selector);
        pp.paySingleInvoice(thisInvoiceId, address(paymentTokenOne));

        Invoice memory inv = pp.getInvoice(thisInvoiceId);

        assertEq(IERC20(paymentTokenOne).balanceOf(inv.escrow), price);
        assertEq(inv.paymentToken, address(paymentTokenOne));
        assertEq(inv.state, pp.PAID());
    }

    function test_erc20PaymentForMetaInvoice() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;

        uint256[] memory responseTime = new uint256[](2);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;

        uint256[] memory disputeWindow = new uint256[](2);
        disputeWindow[0] = 2 days;
        disputeWindow[1] = 2 days;

        uint256 thisInvoiceId = pp.getNextInvoiceId();
        pp.openMetaInvoice(buyerOne, _getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow));

        vm.prank(buyerOne);

        pp.payMetaInvoice(thisInvoiceId, address(paymentTokenOne));

        Invoice memory invOne = pp.getInvoice(thisInvoiceId);
        address escrowOne = _getEscrowAddress(invOne.seller, invOne.buyer, thisInvoiceId);

        assertEq(invOne.state, pp.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(IERC20(paymentTokenOne).balanceOf(invOne.escrow), prices[0]);
        assertEq(invOne.paymentToken, address(paymentTokenOne));

        Invoice memory invTwo = pp.getInvoice(pp.getNextInvoiceId() - 1);
        address escrowTwo = _getEscrowAddress(invTwo.seller, invTwo.buyer, pp.getNextInvoiceId() - 1);

        assertEq(invTwo.state, pp.PAID());
        assertEq(invTwo.escrow, escrowTwo);
        assertEq(IERC20(paymentTokenOne).balanceOf(invTwo.escrow), prices[1]);
        assertEq(invTwo.paymentToken, address(paymentTokenOne));
    }

    function test_sellerAcceptsInvoice() public {
        // single Invoice

        uint256 price = 0.01 ether;
        pp.openInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));

        uint256 currentId = pp.totalUniqueInvoiceCreated();

        vm.prank(sellerOne);
        vm.expectRevert(PaymentProcessorV2.InvalidInvoiceState.selector);
        pp.acceptInvoice(currentId);

        vm.prank(buyerOne);
        pp.paySingleInvoice{ value: price }(currentId, address(0));

        assertEq(pp.getInvoice(currentId).state, pp.PAID());

        vm.prank(sellerTwo);
        vm.expectRevert(PaymentProcessorV2.UnauthorizedSeller.selector);
        pp.acceptInvoice(currentId);

        vm.prank(sellerOne);
        pp.acceptInvoice(currentId);

        assertEq(pp.getInvoice(currentId).state, pp.ACCEPTED());

        // meta invoice

        address[] memory sellers = new address[](2);
        sellers[0] = sellerTwo;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;

        uint256[] memory responseTime = new uint256[](2);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;

        uint256[] memory disputeWindow = new uint256[](2);
        disputeWindow[0] = 2 days;
        disputeWindow[1] = 2 days;

        pp.openMetaInvoice(buyerTwo, _getInvoiceCreationParams(buyerTwo, sellers, prices, responseTime, disputeWindow));

        uint256 currentMetaId = pp.totalMetaInvoiceCreated();

        vm.prank(buyerTwo);
        pp.payMetaInvoice{ value: 0.03 ether }(currentMetaId, address(0));

        uint256[] memory ids = _getSubInvoiceIdsForMetaInvoice(currentMetaId);

        vm.prank(sellerTwo);
        pp.acceptInvoice(ids);

        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(pp.getInvoice(ids[i]).state, pp.ACCEPTED());
        }
    }

    function test_sellerCancelInitiatedInvoice() public {
        // single invoice
        uint256 price = 0.01 ether;
        pp.openInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));

        uint256 currentId = pp.totalUniqueInvoiceCreated();

        vm.prank(buyerOne);
        pp.paySingleInvoice{ value: price }(currentId, address(0));

        uint256 buyersBalanceBeforeCancellation = buyerOne.balance;

        vm.prank(sellerTwo);
        vm.expectRevert(PaymentProcessorV2.UnauthorizedSeller.selector);
        pp.cancelInvoice(currentId);

        vm.prank(sellerOne);
        pp.cancelInvoice(currentId);

        vm.prank(sellerOne);
        vm.expectRevert(PaymentProcessorV2.InvalidInvoiceState.selector);
        pp.cancelInvoice(currentId);

        uint256 buyersBalanceAfterCancellation = buyerOne.balance;

        Invoice memory invOne = pp.getInvoice(currentId);
        assertEq(invOne.state, pp.CANCELED());
        assertEq(buyersBalanceAfterCancellation - buyersBalanceBeforeCancellation, price);

        // meta invoice

        address[] memory sellers = new address[](3);
        sellers[0] = sellerOne;
        sellers[1] = sellerOne;
        sellers[2] = sellerOne;

        uint256[] memory prices = new uint256[](3);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;
        prices[2] = 0.02 ether;

        uint256[] memory responseTime = new uint256[](3);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;
        responseTime[2] = 1 days;

        uint256[] memory disputeWindow = new uint256[](3);
        disputeWindow[0] = 1 days;
        disputeWindow[1] = 4 days;
        disputeWindow[2] = 5 days;

        pp.openMetaInvoice(buyerOne, _getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow));

        uint256 currentMetaInvoiceId = pp.totalMetaInvoiceCreated();

        vm.prank(buyerOne);
        pp.payMetaInvoice{ value: 0.05 ether }(currentMetaInvoiceId, address(0));
        buyersBalanceBeforeCancellation = buyerOne.balance;

        uint256[] memory ids = _getSubInvoiceIdsForMetaInvoice(currentMetaInvoiceId);

        vm.prank(sellerOne);
        pp.cancelInvoice(ids);

        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(pp.getInvoice(ids[i]).state, pp.CANCELED());
        }
        assertEq(buyerOne.balance, buyersBalanceBeforeCancellation + 0.05 ether);
    }

    function test_invoiceCancelationRequest() public {
        uint256 price = 0.01 ether;
        pp.openInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));

        uint256 currentId = pp.totalUniqueInvoiceCreated();

        vm.expectRevert(PaymentProcessorV2.UnauthorizedBuyer.selector);
        pp.requestCancelation(currentId);

        vm.startPrank(buyerOne);

        vm.expectRevert(PaymentProcessorV2.InvalidInvoiceState.selector);
        pp.requestCancelation(currentId);

        pp.paySingleInvoice{ value: price }(currentId, address(0));

        pp.requestCancelation(currentId);

        vm.stopPrank();
        assertEq(pp.getInvoice(currentId).state, pp.CANCELATION_REQUESTED());
    }

    function test_handleInvoiceCancelation() public {
        address[] memory sellers = new address[](3);
        sellers[0] = sellerOne;
        sellers[1] = sellerOne;
        sellers[2] = sellerOne;

        uint256[] memory prices = new uint256[](3);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;
        prices[2] = 0.02 ether;

        uint256[] memory responseTime = new uint256[](3);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;
        responseTime[2] = 1 days;

        uint256[] memory disputeWindow = new uint256[](3);
        disputeWindow[0] = 1 days;
        disputeWindow[1] = 4 days;
        disputeWindow[2] = 5 days;

        pp.openMetaInvoice(buyerOne, _getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow));

        uint256 currentMetaInvoiceId = pp.totalMetaInvoiceCreated();

        vm.startPrank(buyerOne);
        pp.payMetaInvoice{ value: 0.05 ether }(currentMetaInvoiceId, address(0));

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

        assertEq(buyerOne.balance, buyersBalanceBefore + prices[0]);
        assertEq(pp.getInvoice(ids[0]).state, pp.CANCELATION_ACCEPTED());
        assertEq(pp.getInvoice(ids[1]).state, pp.CANCELATION_REJECTED());
        assertEq(pp.getInvoice(ids[2]).state, pp.CANCELATION_REJECTED());
    }

    function test_disputeCreation() public {
        uint256 price = 0.01 ether;
        pp.openInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));
        uint256 id = pp.totalUniqueInvoiceCreated();

        vm.expectRevert(PaymentProcessorV2.UnauthorizedBuyer.selector);
        pp.createDispute(id);

        vm.startPrank(buyerOne);
        vm.expectRevert(PaymentProcessorV2.InvalidInvoiceState.selector);
        pp.createDispute(id);

        pp.paySingleInvoice{ value: price }(id, address(0));
        vm.stopPrank();

        vm.prank(sellerOne);
        pp.acceptInvoice(id);

        vm.warp(block.timestamp + 25 hours);

        vm.startPrank(buyerOne);
        vm.expectRevert(PaymentProcessorV2.DisputeWindowExpired.selector);
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

        uint256[] memory responseTime = new uint256[](2);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;

        uint256[] memory disputeWindow = new uint256[](2);
        disputeWindow[0] = 1 days;
        disputeWindow[1] = 4 days;

        pp.openMetaInvoice(buyerOne, _getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, disputeWindow));
        uint256 metaInvoiceId = pp.totalMetaInvoiceCreated();

        uint256[] memory ids = _getSubInvoiceIdsForMetaInvoice(metaInvoiceId);

        vm.prank(buyerOne);
        pp.payMetaInvoice(metaInvoiceId, address(paymentTokenOne));

        console.log("State before resolveDispute:", pp.getInvoice(ids[0]).state);

        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            Invoice memory inv = pp.getInvoice(id);
            vm.prank(inv.seller);
            pp.acceptInvoice(id);

            vm.prank(buyerOne);
            pp.createDispute(id);
        }

        pp.resolveDispute(ids[0], pp.DISPUTE_DISMISSED(), 0);

        pp.resolveDispute(ids[1], pp.DISPUTE_RESOLVED(), 0);

        assertEq(pp.getInvoice(ids[0]).state, pp.DISPUTE_DISMISSED());
        assertEq(pp.getInvoice(ids[1]).state, pp.DISPUTE_RESOLVED());
    }

    function test_settledDispute() public {
        uint256 price = 0.01 ether;
        pp.openInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));

        uint256 id = pp.totalUniqueInvoiceCreated();

        vm.prank(buyerOne);
        pp.paySingleInvoice(id, address(paymentTokenOne));

        vm.prank(sellerOne);
        pp.acceptInvoice(id);

        uint256 dismissed = pp.DISPUTE_DISMISSED();
        uint256 basisPoint = pp.BASIS_POINTS();
        uint256 settled = pp.DISPUTE_SETTLED();
        uint256 accepted = pp.ACCEPTED();
        vm.expectRevert(PaymentProcessorV2.InvalidInvoiceState.selector);
        pp.resolveDispute(id, dismissed, basisPoint);

        vm.prank(buyerOne);
        pp.createDispute(id);

        uint256 buyerBalanceBefore = IERC20(paymentTokenOne).balanceOf(buyerOne);
        uint256 sellerBalanceBefore = IERC20(paymentTokenOne).balanceOf(sellerOne);

        uint256 sellerPercentage = 9000;

        vm.expectRevert(PaymentProcessorV2.InvalidSellersPayoutShare.selector);
        pp.resolveDispute(id, settled, basisPoint + 1);

        vm.expectRevert(PaymentProcessorV2.InvalidDisputeResolution.selector);
        pp.resolveDispute(id, accepted, sellerPercentage);

        pp.resolveDispute(id, settled, sellerPercentage);

        uint256 buyerShare = _applyBasisPoints(price, pp.BASIS_POINTS() - sellerPercentage);

        uint256 sellerShare = _applyBasisPoints(price, sellerPercentage);
        uint256 fee = _applyBasisPoints(sellerShare, FEE);

        assertEq(pp.getInvoice(id).state, pp.DISPUTE_SETTLED());
        assertEq(IERC20(paymentTokenOne).balanceOf(sellerOne), sellerBalanceBefore + sellerShare - fee);
        assertEq(IERC20(paymentTokenOne).balanceOf(buyerOne), buyerBalanceBefore + buyerShare);
    }

    function test_invoiceRelease() public {
        uint256 price = 0.01 ether;
        pp.openInvoice(_getInvoiceCreationParam(sellerOne, buyerOne, price, 1 days, 1 days));

        uint256 id = pp.totalUniqueInvoiceCreated();

        vm.expectRevert(PaymentProcessorV2.InvalidInvoiceState.selector);
        pp.releasePayment(id);

        vm.prank(buyerOne);
        pp.paySingleInvoice{ value: price }(id, address(0));

        vm.expectRevert(PaymentProcessorV2.InvalidInvoiceState.selector);
        pp.releasePayment(id);

        vm.prank(sellerOne);
        pp.acceptInvoice(id);

        pp.releasePayment(id);

        vm.expectRevert(PaymentProcessorV2.InvalidInvoiceState.selector);
        pp.releasePayment(id);

        assertEq(pp.getInvoice(id).state, pp.RELEASED());
    }

    function _applyBasisPoints(uint256 amount, uint256 basisPoints) internal view returns (uint256) {
        return (amount * basisPoints) / pp.BASIS_POINTS();
    }

    function _getSubInvoiceIdsForMetaInvoice(uint256 metaInvoiceId) internal view returns (uint256[] memory) {
        MetaInvoice memory meta = pp.getMetaInvoice(metaInvoiceId);
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
        uint256 timeBeforeCancelation,
        uint256 disputeWindow
    ) internal pure returns (InvoiceCreationParam memory) {
        InvoiceCreationParam memory param;
        param.seller = seller;
        param.buyer = buyer;
        param.price = price;
        param.timeBeforeCancelation = timeBeforeCancelation;
        param.disputeWindow = disputeWindow;

        return param;
    }

    function _getInvoiceCreationParams(
        address buyer,
        address[] memory sellers,
        uint256[] memory prices,
        uint256[] memory timeBeforeCancelation,
        uint256[] memory disputeWindow
    ) internal pure returns (InvoiceCreationParam[] memory) {
        uint256 numberOfInvoice = sellers.length;
        InvoiceCreationParam[] memory params = new InvoiceCreationParam[](numberOfInvoice);

        for (uint256 i; i < numberOfInvoice; i++) {
            params[i] =
                _getInvoiceCreationParam(sellers[i], buyer, prices[i], timeBeforeCancelation[i], disputeWindow[i]);
        }
        return params;
    }
}
