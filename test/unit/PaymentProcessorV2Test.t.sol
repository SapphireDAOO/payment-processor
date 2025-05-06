// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { PaymentProcessorV2, Invoice, MetaInvoice } from "../../src/PaymentProcessorV2.sol";

contract PaymentProcessorV2Test is Test {
    PaymentProcessorV2 pp;

    address admin = address(1);
    address buyerOne = address(2);
    address buyerTwo = address(3);
    address sellerOne = address(4);
    address sellerTwo = address(5);

    function setUp() public {
        pp = new PaymentProcessorV2();
    }

    function test_singleInvoiceCreation() public {
        uint256 price = 0.01 ether;
        pp.openInvoiceWithPayment{ value: price }(sellerOne, buyerOne, address(0), price);
        Invoice memory i = pp.getInvoice(1);
        assertEq(i.seller, sellerOne);
        assertEq(address(pp).balance, price);
    }

    function test_openMultipleInvoiceWithPayment() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 0.01 ether;
        prices[1] = 0.02 ether;

        pp.openMultipleInvoiceWithPayment(sellers, prices, buyerOne, address(0));

        assertEq(pp.getChildInvoice(1, 1).metaInvoiceId, 1);
        assertEq(pp.getChildInvoice(1, 2).metaInvoiceId, 1);
        assertEq(pp.getMetaInvoiceTotalPrice(1), 0.03 ether);
    }
}
