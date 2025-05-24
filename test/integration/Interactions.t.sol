// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentProcessorV2 } from "../../src/interface/IPaymentProcessorV2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { V2 } from "../util/V2.sol";

contract Interactions is V2 {
    string POLYGON_MAINNET_RPC = vm.envString("MAINNET_RPC");

    function setUp() public override {
        uint256 fork = vm.createFork(POLYGON_MAINNET_RPC);
        vm.selectFork(fork);
        super.setUp();
    }

    function test_nativeTokenPaymentForSingleInvoice() public {
        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, NATIVE_TOKEN_BUYER, price, 1 days, 1 days));
        uint256 thisInvoiceId = pp.totalUniqueInvoiceCreated();

        uint256 amountInToken = pp.getTokenValueFromUsd(address(0), price);

        vm.prank(NATIVE_TOKEN_BUYER);
        pp.paySingleInvoice{ value: amountInToken }(thisInvoiceId, address(0));

        IPaymentProcessorV2.Invoice memory inv = pp.getInvoice(thisInvoiceId);

        assertEq(inv.escrow.balance, amountInToken);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, pp.PAID());
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
            NATIVE_TOKEN_BUYER,
            _getInvoiceCreationParams(NATIVE_TOKEN_BUYER, sellers, prices, responseTime, disputeWindow)
        );

        uint256 tokenAmount = pp.getTokenValueFromUsd(address(0), prices[0] + prices[1]);

        vm.prank(NATIVE_TOKEN_BUYER);

        pp.payMetaInvoice{ value: tokenAmount }(thisInvoiceId, address(0));

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
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, USDC_BUYER, price, 1 days, 1 days));
        uint256 invoiceId = pp.getNextInvoiceId() - 1;

        vm.prank(USDC_BUYER);
        pp.paySingleInvoice(invoiceId, address(USDC));

        IPaymentProcessorV2.Invoice memory inv = pp.getInvoice(invoiceId);

        uint256 tokenValue = pp.getTokenValueFromUsd(address(USDC), price);

        assertEq(IERC20(USDC).balanceOf(inv.escrow), tokenValue);
        assertEq(inv.paymentToken, address(USDC));
        assertEq(inv.state, pp.PAID());
    }

    function test_erc20PaymentForMetaInvoice() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 100e8;
        prices[1] = 200e8;

        uint32[] memory responseTime = new uint32[](2);
        responseTime[0] = 1 days;
        responseTime[1] = 1 days;

        uint32[] memory disputeWindow = new uint32[](2);
        disputeWindow[0] = 2 days;
        disputeWindow[1] = 2 days;

        uint256 thisInvoiceId = pp.getNextInvoiceId();
        pp.createMetaInvoice(
            WTBC_BUYER, _getInvoiceCreationParams(WTBC_BUYER, sellers, prices, responseTime, disputeWindow)
        );

        vm.startPrank(WTBC_BUYER);
        pp.payMetaInvoice(thisInvoiceId, address(WBTC));

        vm.stopPrank();

        IPaymentProcessorV2.Invoice memory invOne = pp.getInvoice(thisInvoiceId);
        address escrowOne = _getEscrowAddress(invOne.seller, invOne.buyer, thisInvoiceId);

        assertEq(invOne.state, pp.PAID());
        assertEq(invOne.escrow, escrowOne);
        assertEq(IERC20(WBTC).balanceOf(invOne.escrow), pp.getTokenValueFromUsd(address(WBTC), prices[0]));
        assertEq(invOne.paymentToken, address(WBTC));

        IPaymentProcessorV2.Invoice memory invTwo = pp.getInvoice(pp.getNextInvoiceId() - 1);
        address escrowTwo = _getEscrowAddress(invTwo.seller, invTwo.buyer, pp.getNextInvoiceId() - 1);

        assertEq(invTwo.state, pp.PAID());
        assertEq(invTwo.escrow, escrowTwo);
        assertEq(IERC20(WBTC).balanceOf(invTwo.escrow), pp.getTokenValueFromUsd(address(WBTC), prices[1]));
        assertEq(invTwo.paymentToken, address(WBTC));
    }

    function test_sellerCancelInitiatedInvoice() public {
        // single invoice
        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, NATIVE_TOKEN_BUYER, price, 1 days, 1 days));

        uint256 currentId = pp.totalUniqueInvoiceCreated();

        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), price);

        vm.prank(NATIVE_TOKEN_BUYER);
        pp.paySingleInvoice{ value: tokenValue }(currentId, address(0));

        uint256 buyersBalanceBeforeCancellation = NATIVE_TOKEN_BUYER.balance;

        vm.prank(sellerOne);
        pp.cancelInvoice(currentId);

        uint256 buyersBalanceAfterCancellation = NATIVE_TOKEN_BUYER.balance;

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
            NATIVE_TOKEN_BUYER,
            _getInvoiceCreationParams(NATIVE_TOKEN_BUYER, sellers, prices, responseTime, disputeWindow)
        );

        uint256 currentMetaInvoiceId = pp.totalMetaInvoiceCreated();

        tokenValue = pp.getTokenValueFromUsd(address(0), prices[0] + prices[1] + prices[2]);

        vm.prank(NATIVE_TOKEN_BUYER);
        pp.payMetaInvoice{ value: tokenValue }(currentMetaInvoiceId, address(0));
        buyersBalanceBeforeCancellation = NATIVE_TOKEN_BUYER.balance;

        uint256[] memory ids = _getSubInvoiceIdsForMetaInvoice(currentMetaInvoiceId);

        vm.prank(sellerOne);
        pp.cancelInvoice(ids);

        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(pp.getInvoice(ids[i]).state, pp.CANCELED());
        }

        assertApproxEqAbs(NATIVE_TOKEN_BUYER.balance - buyersBalanceBeforeCancellation, tokenValue, 2);
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
            NATIVE_TOKEN_BUYER,
            _getInvoiceCreationParams(NATIVE_TOKEN_BUYER, sellers, prices, responseTime, disputeWindow)
        );

        uint256 totalPrice = prices[0] + prices[1] + prices[2];

        uint256 currentMetaInvoiceId = pp.totalMetaInvoiceCreated();
        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), totalPrice);

        vm.startPrank(NATIVE_TOKEN_BUYER);
        pp.payMetaInvoice{ value: tokenValue }(currentMetaInvoiceId, address(0));

        uint256[] memory ids = _getSubInvoiceIdsForMetaInvoice(currentMetaInvoiceId);
        pp.requestCancelation(ids);

        vm.startPrank(sellerOne);

        bool[] memory accept = new bool[](ids.length);
        accept[0] = true; // + 0.01 ether
        accept[1] = false;
        accept[2] = false;

        uint256 buyersBalanceBefore = NATIVE_TOKEN_BUYER.balance;
        for (uint256 i = 0; i < ids.length; ++i) {
            pp.handleCancelationRequest(ids[i], accept[i]);
        }

        assertEq(NATIVE_TOKEN_BUYER.balance, buyersBalanceBefore + pp.getTokenValueFromUsd(address(0), prices[0]));
        assertEq(pp.getInvoice(ids[0]).state, pp.CANCELATION_ACCEPTED());
        assertEq(pp.getInvoice(ids[1]).state, pp.CANCELATION_REJECTED());
        assertEq(pp.getInvoice(ids[2]).state, pp.CANCELATION_REJECTED());
    }

    function test_refundAfterInvoiceExpires() public {
        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, NATIVE_TOKEN_BUYER, price, 1 days, 1 days));
        uint256 id = pp.totalUniqueInvoiceCreated();

        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), price);

        vm.startPrank(NATIVE_TOKEN_BUYER);
        pp.paySingleInvoice{ value: tokenValue }(id, address(0));

        uint256 balanceBefore = NATIVE_TOKEN_BUYER.balance;
        vm.warp(block.timestamp + 1 + 1 days);
        pp.claimExpiredInvoiceRefunds(id);

        vm.stopPrank();

        assertEq(pp.getInvoice(id).state, pp.REFUNDED());
        assertEq(pp.getInvoice(id).amountPaid + balanceBefore, NATIVE_TOKEN_BUYER.balance);
    }

    function test_settledDispute() public {
        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, USDC_BUYER, price, 1 days, 1 days));
        uint256 id = pp.totalUniqueInvoiceCreated();
        uint256 tokenValue = pp.getTokenValueFromUsd(address(USDC), price);

        vm.prank(USDC_BUYER);
        pp.paySingleInvoice(id, address(USDC));

        vm.prank(sellerOne);
        pp.acceptInvoice(id);

        uint8 settled = pp.DISPUTE_SETTLED();

        vm.prank(USDC_BUYER);
        pp.createDispute(id);

        uint256 buyerBalanceBefore = IERC20(USDC).balanceOf(USDC_BUYER);
        uint256 sellerBalanceBefore = IERC20(USDC).balanceOf(sellerOne);

        uint256 sellerPercentage = 9000;

        pp.resolveDispute(id, settled, sellerPercentage);

        uint256 buyerShare = _applyBasisPoints(tokenValue, pp.BASIS_POINTS() - sellerPercentage);

        uint256 sellerShare = _applyBasisPoints(tokenValue, sellerPercentage);
        uint256 fee = _applyBasisPoints(sellerShare, FEE);

        assertEq(pp.getInvoice(id).state, pp.DISPUTE_SETTLED());
        assertEq(IERC20(USDC).balanceOf(sellerOne), sellerBalanceBefore + sellerShare - fee);
        assertEq(IERC20(USDC).balanceOf(USDC_BUYER), buyerBalanceBefore + buyerShare);
        assertEq(IERC20(USDC).balanceOf(feeReceiver), fee);
    }

    function test_invoiceRelease() public {
        uint256 price = 100e8;
        pp.createSingleInvoice(_getInvoiceCreationParam(sellerOne, NATIVE_TOKEN_BUYER, price, 1 days, 1 days));
        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), price);

        uint256 id = pp.totalUniqueInvoiceCreated();

        vm.prank(NATIVE_TOKEN_BUYER);
        pp.paySingleInvoice{ value: tokenValue }(id, address(0));

        vm.prank(sellerOne);
        pp.acceptInvoice(id);

        pp.releasePayment(id);

        assertEq(pp.getInvoice(id).state, pp.RELEASED());
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
