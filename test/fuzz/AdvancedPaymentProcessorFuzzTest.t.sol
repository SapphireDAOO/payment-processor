// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";
import { MockUsdc, MockWbtc } from "../mock/mERC20.sol";
import { PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { getInvoiceCreationParam, getInvoiceCreationParams } from "../utils/InvoiceTestHelpers.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { AdvancedPaymentProcessorSetUp } from "../utils/AdvancedPaymentProcessorSetUp.sol";

contract AdvancedPaymentProcessorFuzzTest is AdvancedPaymentProcessorSetUp {
    using SafeCastLib for uint256;

    function setUp() public override {
        super.setUp();
    }

    function testFuzz_createSingleInvoice(uint256 price, uint256 timeBeforeCancelation, uint256 releaseWindow) public {
        timeBeforeCancelation = bound(timeBeforeCancelation, 1 days, 30 days);
        releaseWindow = bound(releaseWindow, 1 days, 30 days);

        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(
                ppStorage.getNextInvoiceId(),
                sellerOne,
                price,
                timeBeforeCancelation.toUint32(),
                releaseWindow.toUint32()
            )
        );

        uint256 nextInvoiceId = advancedPP.getNextInvoiceId();
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(orderId);
        assertEq(inv.price, price);
        assertEq(inv.seller, sellerOne);
        assertEq(inv.metaInvoiceOrderId, bytes32(0));
        assertEq(nextInvoiceId, 2);
    }

    function testFuzz_paySingleInvoice(uint256 price, uint256 timeBeforeCancelation, uint256 releaseWindow) public {
        price = bound(price, 1e8, 100e8);
        timeBeforeCancelation = bound(timeBeforeCancelation, 1 days, type(uint32).max);
        releaseWindow = bound(releaseWindow, 1 days, type(uint32).max);

        bytes32 orderId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(
                ppStorage.getNextInvoiceId(),
                sellerTwo,
                price,
                timeBeforeCancelation.toUint32(),
                releaseWindow.toUint32()
            )
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerTwo);
        advancedPP.paySingleInvoice{ value: tokenValue }(orderId, address(0));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(orderId);

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

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param,) = getInvoiceCreationParams(
            ppStorage.getNextInvoiceId(), sellers, prices, responseTime, releaseWindows
        );

        bytes32 metaInvoiceOrderId = advancedPP.createMetaInvoice(param);

        uint256 id = advancedPP.totalMetaInvoiceCreated();

        IAdvancedPaymentProcessor.MetaInvoice memory metaInv = advancedPP.getMetaInvoice(metaInvoiceOrderId);

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

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param,) = getInvoiceCreationParams(
            ppStorage.getNextInvoiceId(), sellers, prices, responseTime, releaseWindows
        );

        bytes32 orderIdId = advancedPP.createMetaInvoice(param);

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(mockUsdc), priceO + priceT);

        _executePayment(buyerOne, orderIdId, tokenValue);

        assertApproxEqAbs(mockUsdc.allowance(buyerOne, address(advancedPP)), 0, 2);
    }

    function testFuzz_releasePayment(uint256 price, uint256 sellerShare) public {
        price = bound(price, 1e8, 100e8);
        sellerShare = bound(sellerShare, 0, advancedPP.BASIS_POINTS());

        bytes32 orderIdId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(advancedPP.getNextInvoiceId(), sellerOne, price, 1 days, 2 days)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(orderIdId, address(0));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(orderIdId);

        uint256 balanceBefore = sellerOne.balance;
        advancedPP.releasePayment(orderIdId);

        uint256 expectedValue = tokenValue - ((tokenValue * FEE) / advancedPP.BASIS_POINTS());

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(orderIdId);
        assertEq(inv.state, advancedPP.RELEASED());
        assertEq(sellerOne.balance, expectedValue + balanceBefore);
    }

    function testFuzz_handleDispute(uint256 price, uint256 resolution, uint256 sellerShare) public {
        price = bound(price, 1e8, 100e8);
        resolution = bound(resolution, advancedPP.DISPUTE_DISMISSED(), advancedPP.DISPUTE_SETTLED());
        sellerShare = bound(sellerShare, 0, advancedPP.BASIS_POINTS());

        bytes32 orderIdId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(advancedPP.getNextInvoiceId(), sellerOne, price, 1 days, 2 days)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.paySingleInvoice{ value: tokenValue }(orderIdId, address(0));

        vm.prank(sellerOne);
        advancedPP.acceptInvoice(orderIdId);

        vm.prank(buyerOne);
        advancedPP.createDispute(orderIdId);

        advancedPP.handleDispute(orderIdId, resolution.toUint8(), sellerShare);

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(orderIdId);
        assertEq(inv.state, resolution);
    }

    function testFuzz_getTokenValueFromUsd(uint256 price) public view {
        price = bound(price, 1e8, type(uint256).max / 1e18);
        uint256 val = advancedPP.getTokenValueFromUsd(address(0), price);
        assertGt(val, 0);
    }

    function _executePayment(address buyer, bytes32 orderIdId, uint256 tokenValue) internal {
        mockUsdc.mint(buyer, INITIAL_BALANCE);

        vm.startPrank(buyer);
        mockUsdc.approve(address(advancedPP), tokenValue);
        advancedPP.payMetaInvoice(orderIdId, address(mockUsdc));
        vm.stopPrank();
    }
}
