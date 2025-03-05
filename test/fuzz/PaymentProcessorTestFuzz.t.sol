// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { Invoice } from "../../src/Types/InvoiceType.sol";
import { IPaymentProcessorV1, PaymentProcessorV1 } from "../../src/PaymentProcessorV1.sol";
import {
    CREATED,
    ACCEPTED,
    REJECTED,
    PAID,
    CANCELLED,
    VALID_PERIOD
} from "../../src/utils/Constants.sol";

contract PaymentProcessorTest is Test {
    PaymentProcessorV1 pp;

    address owner;
    address feeReceiver;

    address creator;
    address payer;

    uint256 constant FEE = 1 ether;
    uint256 constant DEFAULT_HOLD_PERIOD = 1 days;
    uint256 constant PAYER_ONE_INITIAL_BALANCE = 10_000 ether;

    function setUp() public {
        owner = makeAddr("owner");
        feeReceiver = makeAddr("feeReceiver");
        creator = makeAddr("creator");
        payer = makeAddr("payer");
        vm.deal(payer, PAYER_ONE_INITIAL_BALANCE);
        vm.prank(owner);
        pp = new PaymentProcessorV1(feeReceiver, FEE, DEFAULT_HOLD_PERIOD);
    }

    function testFuzz_invoice_creation(uint256 _amount) public {
        vm.assume(_amount > FEE);
        vm.prank(creator);
        pp.createInvoice(_amount);
        Invoice memory invoiceData = pp.getInvoiceData(1);
        assertEq(invoiceData.creator, creator);
        assertEq(invoiceData.createdAt, block.timestamp);
        assertEq(invoiceData.paymentTime, 0);
        assertEq(invoiceData.price, _amount);
        assertEq(invoiceData.amountPaid, 0);
        assertEq(invoiceData.payer, address(0));
        assertEq(invoiceData.status, CREATED);
        assertEq(invoiceData.escrow, address(0));
        assertEq(pp.getNextInvoiceId(), 2);
    }

    function testFuzz_makeInvoicePayment(uint256 _paymentAmount) public {
        uint256 invoicePrice = 100 ether;
        _paymentAmount = bound(_paymentAmount, FEE + 1, invoicePrice);
        vm.startPrank(creator);
        uint256 invoiceId = pp.createInvoice(invoicePrice);
        vm.stopPrank();

        vm.prank(payer);

        pp.makeInvoicePayment{ value: _paymentAmount }(invoiceId);
        Invoice memory invoice = pp.getInvoiceData(invoiceId);
        assertEq(invoice.status, PAID);
        assertEq(address(pp).balance, invoiceId * FEE);
    }
}
