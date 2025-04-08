// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SetUp, console } from "../util/SetUp.sol";
import { IPaymentProcessorV1, PaymentProcessorV1 } from "../../src/PaymentProcessorV1.sol";

contract PaymentProcessorFuzzTest is SetUp {
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

    function testFuzz_createAndPayInvoice(uint256 _invoicePrice) public {
        _invoicePrice = bound(_invoicePrice, 1 ether, 1000 ether);

        vm.startPrank(creatorOne);
        uint256 invoiceId = pp.createInvoice(_invoicePrice);
        vm.stopPrank();

        IPaymentProcessorV1.Invoice memory invoice = pp.getInvoiceData(invoiceId);
        assertEq(invoice.price, _invoicePrice);
        assertEq(invoice.status, pp.CREATED());

        vm.prank(payerOne);
        address escrow = pp.makeInvoicePayment{ value: _invoicePrice }(invoiceId);

        IPaymentProcessorV1.Invoice memory updated = pp.getInvoiceData(invoiceId);
        assertEq(updated.payer, payerOne);
        assertEq(updated.amountPaid, _invoicePrice);
        assertEq(updated.status, pp.PAID());
        assertEq(updated.escrow, escrow);
    }
}
