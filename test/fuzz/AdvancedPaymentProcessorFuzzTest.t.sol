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

    function testFuzz_createSingleInvoice(uint256 _price) public {
        _price = bound(_price, 1e8, type(uint128).max);

        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, _price));

        uint256 nextInvoiceNonce = advancedPP.getNextInvoiceNonce();
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.price, _price);
        assertEq(inv.seller, sellerOne);
        // assertEq(inv.invoiceId, uint256(0));
        assertEq(nextInvoiceNonce, 2);
    }

    function testFuzz_paySingleInvoice(uint256 _price) public {
        _price = bound(_price, 1e8, 100e8);

        uint216 invoiceId =
            advancedPP.createSingleInvoice(getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerTwo, _price));

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerTwo);
        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceId, address(0));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

        assertEq(inv.escrow.balance, tokenValue);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, advancedPP.PAID());
    }

    function testFuzz_createMetaInvoice(
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

    function testFuzz_payMetaInvoice(
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

    function testFuzz_releasePayment(uint256 _price, uint256 _sellerShare) public {
        _price = bound(_price, 1e8, 100e8);
        _sellerShare = bound(_sellerShare, 0, advancedPP.BASIS_POINTS());

        uint216 invoiceId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(advancedPP.getNextInvoiceNonce(), sellerOne, _price)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceId, address(0));

        uint256 balanceBefore = sellerOne.balance;
        vm.warp(block.timestamp + 1 days);
        advancedPP.release(invoiceId);

        uint256 expectedValue = tokenValue - ((tokenValue * FEE_RATE) / advancedPP.BASIS_POINTS());

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, advancedPP.RELEASED());
        assertEq(sellerOne.balance, expectedValue + balanceBefore);
    }

    function testFuzz_handleDispute(uint256 _price, uint256 _resolution, uint256 _sellerShare) public {
        _price = bound(_price, 1e8, 100e8);
        _resolution = bound(_resolution, advancedPP.DISPUTE_DISMISSED(), advancedPP.DISPUTE_SETTLED());
        _sellerShare = bound(_sellerShare, 0, advancedPP.BASIS_POINTS());

        uint216 invoiceId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(advancedPP.getNextInvoiceNonce(), sellerOne, _price)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), _price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceId, address(0));

        advancedPP.createDispute(invoiceId);

        advancedPP.handleDispute(invoiceId, _resolution.toUint8(), _sellerShare);

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, _resolution);
    }

    function testFuzz_getTokenValueFromUsd(uint256 _price) public view {
        _price = bound(_price, 1e8, type(uint256).max / 1e18);
        uint256 val = advancedPP.getTokenValueFromUsd(address(0), _price);
        assertGt(val, 0);
    }

    function _executePayment(address _buyer, uint216 _invoiceId, uint256 _tokenValue) internal {
        mockUsdc.mint(_buyer, INITIAL_BALANCE);

        vm.startPrank(_buyer);
        mockUsdc.approve(address(advancedPP), _tokenValue);
        advancedPP.payMetaInvoice(_invoiceId, address(mockUsdc));
        vm.stopPrank();
    }
}
