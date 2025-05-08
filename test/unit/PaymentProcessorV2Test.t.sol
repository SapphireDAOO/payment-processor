// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { PaymentProcessorV2, Invoice, MetaInvoice } from "../../src/PaymentProcessorV2.sol";
import { MockERC20 } from "../mock/mERC20.sol";

contract PaymentProcessorV2Test is Test {
    PaymentProcessorV2 pp;
    MockERC20 paymentTokenOne;

    address admin = address(1);
    address buyerOne = address(2);
    address buyerTwo = address(3);
    address sellerOne = address(4);
    address sellerTwo = address(5);

    function setUp() public {
        pp = new PaymentProcessorV2();
        paymentTokenOne = new MockERC20("Payment token", "PTK");

        pp.setPaymentTokenState(address(paymentTokenOne), true);

        vm.deal(buyerOne, 100 ether);
        vm.deal(sellerOne, 100 ether);
    }

    function test_singleInvoiceCreation() public {
        uint256 price = 0.01 ether;
        pp.openInvoice(sellerOne, buyerOne, price);
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

        uint256 startInvoiceId = pp.getNextInvoiceId();
        pp.openMetaInvoice(sellers, prices, buyerOne);

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
        pp.openInvoice(sellerOne, buyerOne, price);
        uint256 thisInvoiceId = pp.getNextInvoiceId() - 1;

        vm.startPrank(buyerOne);

        vm.expectRevert(PaymentProcessorV2.InvalidPaymentToken.selector);
        pp.paySingleInvoice(thisInvoiceId, address(12));

        vm.expectRevert(PaymentProcessorV2.InvalidNativePayment.selector);
        pp.paySingleInvoice{ value: 0.001 ether }(thisInvoiceId, address(0));

        pp.paySingleInvoice{ value: price }(thisInvoiceId, address(0));

        Invoice memory inv = pp.getInvoice(thisInvoiceId);

        address escrow = inv.escrow;

        vm.stopPrank();

        assertEq(escrow.balance, price);
        assertEq(inv.paymentToken, address(0));
        assertEq(inv.state, pp.PAID());
    }
}
