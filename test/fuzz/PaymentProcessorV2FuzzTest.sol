// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IPaymentProcessorV2, PaymentProcessorV2 } from "../../src/PaymentProcessorV2.sol";
import { MockUsdc, MockWbtc } from "../mock/mERC20.sol";
import { PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { getInvoiceCreationParam, getInvoiceCreationParams } from "../util/InvoiceTestHelpers.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { V2 } from "../util/V2.sol";

contract PaymentProcessorV2FuzzTest is V2 {
    using SafeCastLib for uint256;

    function setUp() public override {
        super.setUp();
    }

    function testFuzz_createSingleInvoice(
        address seller,
        address buyer,
        uint256 price,
        uint256 timeBeforeCancelation,
        uint256 releaseWindow
    ) public {
        vm.assume(buyer.code.length == 0 && seller.code.length == 0);
        vm.assume(buyer != seller);
        timeBeforeCancelation = bound(timeBeforeCancelation, 1 days, 30 days);
        releaseWindow = bound(releaseWindow, 1 days, 30 days);

        pp.createSingleInvoice(
            getInvoiceCreationParam(buyer, seller, price, timeBeforeCancelation.toUint32(), releaseWindow.toUint32())
        );

        uint256 nextInvoiceId = pp.getNextInvoiceId();
        IPaymentProcessorV2.Invoice memory inv = pp.getInvoice(nextInvoiceId - 1);
        assertEq(inv.price, price);
        assertEq(inv.buyer, buyer);
        assertEq(inv.seller, seller);
        assertEq(inv.metaInvoiceId, 0);
        assertEq(nextInvoiceId, 2);
    }

    function testFuzz_paySingleInvoice(
        address buyer,
        address seller,
        uint256 price,
        uint256 timeBeforeCancelation,
        uint256 releaseWindow
    ) public {
        vm.assume(buyer.code.length == 0 && seller.code.length == 0);
        price = bound(price, 1e8, 100e8);
        timeBeforeCancelation = bound(timeBeforeCancelation, 1 days, type(uint32).max);
        releaseWindow = bound(releaseWindow, 1 days, type(uint32).max);

        pp.createSingleInvoice(
            getInvoiceCreationParam(buyer, seller, price, timeBeforeCancelation.toUint32(), releaseWindow.toUint32())
        );

        uint256 id = pp.totalUniqueInvoiceCreated();

        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), price);
        vm.deal(buyer, tokenValue);
        vm.prank(buyer);
        pp.paySingleInvoice{ value: tokenValue }(id, address(0));

        IPaymentProcessorV2.Invoice memory inv = pp.getInvoice(id);

        assertEq(inv.escrow.balance, tokenValue);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, pp.PAID());
    }

    function testFuzz_createMetaInvoice(
        address buyer,
        address sellerO,
        address sellerT,
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
        sellers[0] = sellerO;
        sellers[1] = sellerT;

        uint256[] memory prices = new uint256[](2);
        prices[0] = priceO;
        prices[1] = priceT;

        uint32[] memory responseTime = new uint32[](2);
        responseTime[0] = timeBeforeCancelation.toUint32();
        responseTime[1] = timeBeforeCancelation.toUint32();

        uint32[] memory releaseWindows = new uint32[](2);
        releaseWindows[0] = releaseWindow.toUint32();
        releaseWindows[1] = releaseWindow.toUint32();

        pp.createMetaInvoice(buyer, getInvoiceCreationParams(buyer, sellers, prices, responseTime, releaseWindows));

        uint256 id = pp.totalMetaInvoiceCreated();

        IPaymentProcessorV2.MetaInvoice memory metaInv = pp.getMetaInvoice(id);

        assertEq(id, 1);
        assertEq(metaInv.price, priceO + priceT);
    }

    function testFuzz_payMetaInvoice(
        address buyer,
        address sellerO,
        address sellerT,
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
        sellers[0] = sellerO;
        sellers[1] = sellerT;

        uint256[] memory prices = new uint256[](2);
        prices[0] = priceO;
        prices[1] = priceT;

        uint32[] memory responseTime = new uint32[](2);
        responseTime[0] = timeBeforeCancelation.toUint32();
        responseTime[1] = timeBeforeCancelation.toUint32();

        uint32[] memory releaseWindows = new uint32[](2);
        releaseWindows[0] = releaseWindow.toUint32();
        releaseWindows[1] = releaseWindow.toUint32();

        pp.createMetaInvoice(buyer, getInvoiceCreationParams(buyer, sellers, prices, responseTime, releaseWindows));

        uint256 id = pp.totalMetaInvoiceCreated();

        uint256 tokenValue = pp.getTokenValueFromUsd(address(mockUsdc), priceO + priceT);

        _executePayment(buyer, id, tokenValue);

        assertApproxEqAbs(mockUsdc.allowance(buyer, address(pp)), 0, 2);
    }

    function testFuzz_releasePayment(
        address seller,
        address buyer,
        uint256 price,
        uint256 resolution,
        uint256 sellerShare
    ) public {
        vm.assume(buyer.code.length == 0 && seller.code.length == 0);
        price = bound(price, 1e8, 100e8);
        resolution = bound(resolution, pp.DISPUTE_RESOLVED(), pp.DISPUTE_SETTLED());
        sellerShare = bound(sellerShare, 0, pp.BASIS_POINTS());

        pp.createSingleInvoice(getInvoiceCreationParam(buyer, seller, price, 1 days, 2 days));

        uint256 id = pp.totalUniqueInvoiceCreated();

        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), price);
        vm.deal(buyer, tokenValue);
        vm.prank(buyer);
        pp.paySingleInvoice{ value: tokenValue }(id, address(0));

        vm.prank(seller);
        pp.acceptInvoice(id);

        pp.releasePayment(id);

        uint256 expectedValue = tokenValue - ((tokenValue * FEE) / pp.BASIS_POINTS());

        IPaymentProcessorV2.Invoice memory inv = pp.getInvoice(id);
        assertEq(inv.state, pp.RELEASED());
        assertEq(seller.balance, expectedValue);
    }

    function testFuzz_resolveDispute(
        address seller,
        address buyer,
        uint256 price,
        uint256 resolution,
        uint256 sellerShare
    ) public {
        vm.assume(buyer.code.length == 0 && seller.code.length == 0);

        price = bound(price, 1e8, 100e8);
        resolution = bound(resolution, pp.DISPUTE_RESOLVED(), pp.DISPUTE_SETTLED());
        sellerShare = bound(sellerShare, 0, pp.BASIS_POINTS());

        pp.createSingleInvoice(getInvoiceCreationParam(buyer, seller, price, 1 days, 2 days));

        uint256 id = pp.totalUniqueInvoiceCreated();

        uint256 tokenValue = pp.getTokenValueFromUsd(address(0), price);
        vm.deal(buyer, tokenValue);
        vm.prank(buyer);
        pp.paySingleInvoice{ value: tokenValue }(id, address(0));

        vm.prank(seller);
        pp.acceptInvoice(id);

        vm.prank(buyer);
        pp.createDispute(id);

        pp.resolveDispute(id, resolution.toUint8(), sellerShare);

        IPaymentProcessorV2.Invoice memory inv = pp.getInvoice(id);
        assertEq(inv.state, resolution);
    }

    function testFuzz_getTokenValueFromUsd(uint256 price) public view {
        price = bound(price, 1e8, type(uint256).max / 1e18);
        uint256 val = pp.getTokenValueFromUsd(address(0), price);
        assertGt(val, 0);
    }

    function _executePayment(address buyer, uint256 id, uint256 tokenValue) internal {
        mockUsdc.mint(buyer, INITIAL_BALANCE);

        vm.startPrank(buyer);
        mockUsdc.approve(address(pp), tokenValue);
        pp.payMetaInvoice(id, address(mockUsdc));
        vm.stopPrank();
    }
}
