// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SetUp } from "../SetUp.sol";
import { IPaymentProcessorV1, PaymentProcessorV1 } from "../../src/PaymentProcessorV1.sol";

contract PaymentProcessorTest is SetUp {
    function testFuzz_invoice_creation(uint256 _amount) public {
        vm.assume(_amount > 1 ether);
        vm.prank(creatorOne);
        pp.createInvoice(_amount);
        IPaymentProcessorV1.Invoice memory invoiceData = pp.getInvoiceData(1);
        assertEq(invoiceData.creator, creatorOne);
        assertEq(invoiceData.createdAt, block.timestamp);
        assertEq(invoiceData.paymentTime, 0);
        assertEq(invoiceData.price, _amount);
        assertEq(invoiceData.amountPaid, 0);
        assertEq(invoiceData.payer, address(0));
        assertEq(invoiceData.status, pp.CREATED());
        assertEq(invoiceData.escrow, address(0));
        assertEq(pp.getNextInvoiceId(), 2);
    }

    function testFuzz_makeInvoicePayment(uint256 _paymentAmount) public {
        uint256 invoicePrice = 100 ether;
        uint256 fee = pp.calculateFee(invoicePrice);
        _paymentAmount = bound(_paymentAmount, fee + 1, invoicePrice);
        vm.startPrank(creatorOne);
        uint256 invoiceId = pp.createInvoice(invoicePrice);
        vm.stopPrank();

        vm.prank(payerOne);

        pp.makeInvoicePayment{ value: _paymentAmount }(invoiceId);
        IPaymentProcessorV1.Invoice memory invoice = pp.getInvoiceData(invoiceId);
        assertEq(invoice.status, pp.PAID());
        assertEq(address(pp).balance, invoiceId * fee);
    }
}
