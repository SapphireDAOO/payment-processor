// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAdvancedPaymentProcessor } from "../../src/interface/IAdvancedPaymentProcessor.sol";
import { getInvoiceCreationParam, getInvoiceCreationParams } from "../utils/InvoiceTestHelpers.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";

import { AdvancedPaymentProcessorSetUp } from "../utils/AdvancedPaymentProcessorSetUp.sol";

contract AdvancedPaymentProcessorFuzzTest is AdvancedPaymentProcessorSetUp {
    using SafeCastLib for uint256;

    function setUp() public override {
        super.setUp();
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
        assertEq(inv.state, advancedPP.PAID());
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
        _sellerShare = bound(_sellerShare, 0, advancedPP.BASIS_POINTS());

        uint216 invoiceId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(advancedPP.getNextInvoiceNonce(), sellerOne, _price)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        uint256 balanceBefore = sellerOne.balance;
        vm.warp(block.timestamp + 1 days);
        advancedPP.release(invoiceId);

        uint256 expectedValue = tokenValue - ((tokenValue * FEE_RATE) / advancedPP.BASIS_POINTS());

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, advancedPP.RELEASED());
        assertEq(sellerOne.balance, expectedValue + balanceBefore);
    }

    function test_handleDispute(uint256 _price, uint256 _resolution, uint256 _sellerShare) public {
        _price = bound(_price, 1e8, 100e8);
        _resolution = bound(_resolution, advancedPP.DISPUTE_DISMISSED(), advancedPP.DISPUTE_SETTLED());
        _sellerShare = bound(_sellerShare, 0, advancedPP.BASIS_POINTS());

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
        assertEq(inv.state, advancedPP.PAID());
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

        assertEq(inv0.state, advancedPP.PAID());
        assertEq(inv1.state, advancedPP.PAID());
        assertEq(inv0.buyer, buyerOne);
        assertEq(inv1.buyer, buyerOne);
        assertLe(inv0.escrow.balance + inv1.escrow.balance, totalEth);
    }

    function test_partialRefund(uint256 _price, uint256 _refundShare) public {
        _price = bound(_price, 1e8, 100e8);
        _refundShare = bound(_refundShare, 1, advancedPP.BASIS_POINTS() - 1); // partial, not full

        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        uint256 expectedRefund = (tokenValue * _refundShare) / advancedPP.BASIS_POINTS();
        uint256 buyerBefore = buyerOne.balance;

        advancedPP.refund(invoiceId, _refundShare);

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, advancedPP.PAID());
        assertEq(inv.balance, tokenValue - expectedRefund);
        assertEq(buyerOne.balance, buyerBefore + expectedRefund);
    }

    function test_disputeSettledFundDistribution(uint256 _price, uint256 _sellerShare) public {
        _price = bound(_price, 1e8, 100e8);
        _sellerShare = bound(_sellerShare, 0, advancedPP.BASIS_POINTS());

        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        advancedPP.createDispute(invoiceId);

        uint256 sellerBefore = sellerOne.balance;
        uint256 buyerBefore = buyerOne.balance;
        uint256 feeReceiverBefore = feeReceiver.balance;

        advancedPP.handleDispute(invoiceId, uint8(advancedPP.DISPUTE_SETTLED()), _sellerShare);

        uint256 sellerGross = (tokenValue * _sellerShare) / advancedPP.BASIS_POINTS();
        uint256 fee = (sellerGross * FEE_RATE) / advancedPP.BASIS_POINTS();
        uint256 buyerRefund = (tokenValue * (advancedPP.BASIS_POINTS() - _sellerShare)) / advancedPP.BASIS_POINTS();

        assertEq(sellerOne.balance, sellerBefore + sellerGross - fee);
        assertEq(buyerOne.balance, buyerBefore + buyerRefund);
        assertEq(feeReceiver.balance, feeReceiverBefore + fee);

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, advancedPP.DISPUTE_SETTLED());
        assertEq(inv.balance, 0);
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
        assertEq(inv.state, advancedPP.RELEASED());
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
        assertEq(inv.state, advancedPP.DISPUTE_RESOLVED());

        vm.warp(originalReleaseAt + 1);

        uint256 sellerBefore = sellerOne.balance;
        uint256 expectedFee = (tokenValue * FEE_RATE) / advancedPP.BASIS_POINTS();

        advancedPP.release(invoiceId);

        inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, advancedPP.RELEASED());
        assertEq(inv.balance, 0);
        assertEq(sellerOne.balance, sellerBefore + tokenValue - expectedFee);
    }

    function _executePayment(address _buyer, uint216 _invoiceId, uint256 _tokenValue) internal {
        mockUsdc.mint(_buyer, INITIAL_BALANCE);

        vm.startPrank(_buyer);
        mockUsdc.approve(address(advancedPP), _tokenValue);
        advancedPP.payMetaInvoice(_invoiceId, address(mockUsdc));
        vm.stopPrank();
    }
}
