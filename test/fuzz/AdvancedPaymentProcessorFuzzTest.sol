// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";
import { MockUsdc, MockWbtc } from "../mock/mERC20.sol";
import { PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { getInvoiceCreationParam, getInvoiceCreationParams } from "../util/InvoiceTestHelpers.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { AdvancedPaymentProcessorSetUp } from "../util/AdvancedPaymentProcessorSetUp.sol";

contract AdvancedPaymentProcessorFuzzTest is AdvancedPaymentProcessorSetUp {
    using SafeCastLib for uint256;

    function setUp() public override {
        super.setUp();
    }

    function testFuzz_createSingleInvoice(uint256 price, uint256 timeBeforeCancelation, uint256 releaseWindow) public {
        timeBeforeCancelation = bound(timeBeforeCancelation, 1 days, 30 days);
        releaseWindow = bound(releaseWindow, 1 days, 30 days);

        advancedPP.createSingleInvoice(
            getInvoiceCreationParam(
                buyerOne, sellerOne, price, timeBeforeCancelation.toUint32(), releaseWindow.toUint32()
            )
        );

        uint256 nextInvoiceId = advancedPP.getNextInvoiceId();
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(nextInvoiceId - 1);
        assertEq(inv.price, price);
        assertEq(inv.buyer, buyerOne);
        assertEq(inv.seller, sellerOne);
        assertEq(inv.metaInvoiceId, 0);
        assertEq(nextInvoiceId, 2);
    }

    function testFuzz_paySingleInvoice(uint256 price, uint256 timeBeforeCancelation, uint256 releaseWindow) public {
        price = bound(price, 1e8, 100e8);
        timeBeforeCancelation = bound(timeBeforeCancelation, 1 days, type(uint32).max);
        releaseWindow = bound(releaseWindow, 1 days, type(uint32).max);

        advancedPP.createSingleInvoice(
            getInvoiceCreationParam(
                buyerTwo, sellerTwo, price, timeBeforeCancelation.toUint32(), releaseWindow.toUint32()
            )
        );

        uint256 id = advancedPP.totalUniqueInvoiceCreated();

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerTwo);
        advancedPP.paySingleInvoice{ value: tokenValue }(id, address(0));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(id);

        assertEq(inv.escrow.balance, tokenValue);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, advancedPP.PAID());
    }

    function testFuzz_createMetaInvoice(
        uint256 priceO,
        uint256 priceT,
        uint256 timeBeforeCancelation,
        uint256 releaseWindow
    ) public {
        timeBeforeCancelation = bound(timeBeforeCancelation, 1 days, type(uint32).max);
        releaseWindow = bound(releaseWindow, 1 days, type(uint32).max);

        priceO = bound(priceO, 1e8, 100e8);
        priceT = bound(priceT, 1e8, 100e8);

        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = priceO;
        prices[1] = priceT;

        uint32[] memory responseTime = new uint32[](2);
        responseTime[0] = timeBeforeCancelation.toUint32();
        responseTime[1] = timeBeforeCancelation.toUint32();

        uint32[] memory releaseWindows = new uint32[](2);
        releaseWindows[0] = releaseWindow.toUint32();
        releaseWindows[1] = releaseWindow.toUint32();

        advancedPP.createMetaInvoice(
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, releaseWindows)
        );

        uint256 id = advancedPP.totalMetaInvoiceCreated();

        IAdvancedPaymentProcessor.MetaInvoice memory metaInv = advancedPP.getMetaInvoice(id);

        assertEq(id, 1);
        assertEq(metaInv.price, priceO + priceT);
    }

    function testFuzz_payMetaInvoice(
        uint256 priceO,
        uint256 priceT,
        uint256 timeBeforeCancelation,
        uint256 releaseWindow
    ) public {
        timeBeforeCancelation = bound(timeBeforeCancelation, 1 days, type(uint32).max);
        releaseWindow = bound(releaseWindow, 1 days, type(uint32).max);

        priceO = bound(priceO, 1e8, 100e8);
        priceT = bound(priceT, 1e8, 100e8);

        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = priceO;
        prices[1] = priceT;

        uint32[] memory responseTime = new uint32[](2);
        responseTime[0] = timeBeforeCancelation.toUint32();
        responseTime[1] = timeBeforeCancelation.toUint32();

        uint32[] memory releaseWindows = new uint32[](2);
        releaseWindows[0] = releaseWindow.toUint32();
        releaseWindows[1] = releaseWindow.toUint32();

        advancedPP.createMetaInvoice(
            buyerOne, getInvoiceCreationParams(buyerOne, sellers, prices, responseTime, releaseWindows)
        );

        uint256 id = advancedPP.totalMetaInvoiceCreated();

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(mockUsdc), priceO + priceT);

        _executePayment(buyerOne, id, tokenValue);

        assertApproxEqAbs(mockUsdc.allowance(buyerOne, address(advancedPP)), 0, 2);
    }

    function testFuzz_releasePayment(uint256 price, uint256 resolution, uint256 sellerShare) public {
        price = bound(price, 1e8, 100e8);
        resolution = bound(resolution, advancedPP.DISPUTE_RESOLVED(), advancedPP.DISPUTE_SETTLED());
        sellerShare = bound(sellerShare, 0, advancedPP.BASIS_POINTS());

        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 2 days));

        uint256 id = advancedPP.totalUniqueInvoiceCreated();

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(id, address(0));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(id);

        uint256 balanceBefore = sellerOne.balance;
        advancedPP.releasePayment(id);

        uint256 expectedValue = tokenValue - ((tokenValue * FEE) / advancedPP.BASIS_POINTS());

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(id);
        assertEq(inv.state, advancedPP.RELEASED());
        assertEq(sellerOne.balance, expectedValue + balanceBefore);
    }

    function testFuzz_resolveDispute(uint256 price, uint256 resolution, uint256 sellerShare) public {
        price = bound(price, 1e8, 100e8);
        resolution = bound(resolution, advancedPP.DISPUTE_RESOLVED(), advancedPP.DISPUTE_SETTLED());
        sellerShare = bound(sellerShare, 0, advancedPP.BASIS_POINTS());

        advancedPP.createSingleInvoice(getInvoiceCreationParam(buyerOne, sellerOne, price, 1 days, 2 days));

        uint256 id = advancedPP.totalUniqueInvoiceCreated();

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(id, address(0));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(id);

        vm.prank(buyerOne);
        advancedPP.createDispute(id);

        advancedPP.resolveDispute(id, resolution.toUint8(), sellerShare);

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(id);
        assertEq(inv.state, resolution);
    }

    function testFuzz_getTokenValueFromUsd(uint256 price) public view {
        price = bound(price, 1e8, type(uint256).max / 1e18);
        uint256 val = advancedPP.getTokenValueFromUsd(address(0), price);
        assertGt(val, 0);
    }

    function _executePayment(address buyer, uint256 id, uint256 tokenValue) internal {
        mockUsdc.mint(buyer, INITIAL_BALANCE);

        vm.startPrank(buyer);
        mockUsdc.approve(address(advancedPP), tokenValue);
        advancedPP.payMetaInvoice(id, address(mockUsdc));
        vm.stopPrank();
    }
}
