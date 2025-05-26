// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { console } from "forge-std/console.sol";
import { AdvancedPaymentProcessor } from "../../../src/AdvancedPaymentProcessor.sol";
import { Test } from "forge-std/Test.sol";
import { getInvoiceCreationParam } from "../../util/InvoiceTestHelpers.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";

contract AdvancedPaymentProcessorHandler is Test {
    using SafeCastLib for uint256;

    AdvancedPaymentProcessor advancedPP;

    address buyer;
    address seller;

    uint256 private uniqueInvoice;

    mapping(bytes4 => uint256) calls;

    modifier countCall(bytes4 key) {
        calls[key]++;
        _;
    }

    constructor(AdvancedPaymentProcessor advancedPaymentProcessor) {
        advancedPP = advancedPaymentProcessor;
    }

    function createInvoice(uint256 price, uint256 timeBeforeCancelation, uint256 releaseWindow)
        public
        countCall(this.createInvoice.selector)
    {
        timeBeforeCancelation = bound(timeBeforeCancelation, 1 days, 30 days);
        releaseWindow = bound(releaseWindow, 1 days, 30 days);
        price = bound(price, 1e8, 1000e8);

        advancedPP.createSingleInvoice(
            getInvoiceCreationParam(buyer, seller, price, timeBeforeCancelation.toUint32(), releaseWindow.toUint32())
        );
        uniqueInvoice++;
    }

    function createMetaInvoice() public countCall(this.createMetaInvoice.selector) { }

    function makeInvoicePayment() public countCall(this.makeInvoicePayment.selector) { }

    function makeMultiInvoicePayment() public countCall(this.makeMultiInvoicePayment.selector) { }

    function acceptInvoice() public countCall(this.acceptInvoice.selector) { }

    function cancelInvoice() public countCall(this.cancelInvoice.selector) { }

    function requestCancelation() public countCall(this.requestCancelation.selector) { }

    function handleCancelation() public countCall(this.handleCancelation.selector) { }

    function createDispute() public countCall(this.createDispute.selector) { }

    function resolveDispute() public countCall(this.resolveDispute.selector) { }

    function releasePayment() public countCall(this.releasePayment.selector) { }

    function callSummary() external view {
        console.log("Call summary:");
        console.log("-------------------");
        console.log("Create Invoice", calls[this.createInvoice.selector]);
        console.log("Create meta Invoice", calls[this.createMetaInvoice.selector]);
        console.log("Payment", calls[this.makeInvoicePayment.selector]);
        console.log("Accept", calls[this.makeMultiInvoicePayment.selector]);
        console.log("Reject", calls[this.makeMultiInvoicePayment.selector]);
        console.log("Accept", calls[this.acceptInvoice.selector]);
        console.log("Release", calls[this.cancelInvoice.selector]);
        console.log("Release", calls[this.createDispute.selector]);
        console.log("Release", calls[this.resolveDispute.selector]);
    }
}
