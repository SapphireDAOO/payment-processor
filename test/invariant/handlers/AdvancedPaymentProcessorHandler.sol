// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { console } from "forge-std/console.sol";
import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../../src/AdvancedPaymentProcessor.sol";
import { Test } from "forge-std/Test.sol";
import {
    getInvoiceCreationParam,
    getInvoiceCreationParams,
    getSubInvoiceIdsForMetaInvoice
} from "../../utils/InvoiceTestHelpers.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";

contract AdvancedPaymentProcessorHandler is Test {
    using SafeCastLib for uint256;
    using { getSubInvoiceIdsForMetaInvoice } for AdvancedPaymentProcessor;

    AdvancedPaymentProcessor advancedPP;

    address admin;
    address buyer;
    address seller;

    uint256 private totalSingleInvoiceCreated;
    uint256 private totalMetaInvoiceCreated;

    mapping(bytes4 => uint256) calls;

    modifier countCall(bytes4 key) {
        calls[key]++;
        _;
    }

    constructor(
        AdvancedPaymentProcessor advancedPaymentProcessor,
        address adminAddress,
        address buyerAddress,
        address sellerAddress
    ) {
        advancedPP = advancedPaymentProcessor;
        admin = adminAddress;
        buyer = buyerAddress;
        seller = sellerAddress;
    }

    modifier onlyExistingInvoice() {
        if (totalSingleInvoiceCreated == 0) return;
        _;
    }

    function createInvoice(uint256 price, uint256 timeBeforeCancelation, uint256 releaseWindow)
        public
        countCall(this.createInvoice.selector)
    {
        timeBeforeCancelation = bound(timeBeforeCancelation, 1 days, 30 days);
        releaseWindow = bound(releaseWindow, 1 days, 30 days);
        price = bound(price, 1e8, 1000e8);

        vm.prank(advancedPP.getMarketplace());
        advancedPP.createSingleInvoice(
            getInvoiceCreationParam(buyer, seller, price, timeBeforeCancelation.toUint32(), releaseWindow.toUint32())
        );
        totalSingleInvoiceCreated++;
    }

    function createMetaInvoice(uint256 priceO, uint256 priceT, uint256 timeBeforeCancelation, uint256 releaseWindow)
        public
        countCall(this.createMetaInvoice.selector)
    {
        if (totalMetaInvoiceCreated == 0) return;
        timeBeforeCancelation = bound(timeBeforeCancelation, 1 days, 30 days);
        releaseWindow = bound(releaseWindow, 1 days, 30 days);

        priceO = bound(priceO, 1e8, 100e8);
        priceT = bound(priceT, 1e8, 100e8);

        address[] memory sellers = new address[](2);
        sellers[0] = seller;
        sellers[1] = seller;

        uint256[] memory prices = new uint256[](2);
        prices[0] = priceO;
        prices[1] = priceT;

        uint32[] memory responseTime = new uint32[](2);
        responseTime[0] = timeBeforeCancelation.toUint32();
        responseTime[1] = timeBeforeCancelation.toUint32();

        uint32[] memory releaseWindows = new uint32[](2);
        releaseWindows[0] = releaseWindow.toUint32();
        releaseWindows[1] = releaseWindow.toUint32();

        vm.prank(advancedPP.getMarketplace());
        advancedPP.createMetaInvoice(
            buyer, getInvoiceCreationParams(buyer, sellers, prices, responseTime, releaseWindows)
        );

        totalSingleInvoiceCreated += sellers.length;
        totalMetaInvoiceCreated++;
    }

    function makeSingleInvoicePayment(uint256 invoiceId)
        public
        onlyExistingInvoice
        countCall(this.makeSingleInvoicePayment.selector)
    {
        invoiceId = bound(invoiceId, 1, totalSingleInvoiceCreated);
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

        if (inv.escrow != address(0) || inv.price == 0) return;
        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), inv.price);

        vm.prank(buyer);
        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceId, address(0));
    }

    function makeMetaInvoicePayment(uint256 invoiceId) public countCall(this.makeMetaInvoicePayment.selector) {
        if (totalMetaInvoiceCreated == 0) return;
        invoiceId = bound(invoiceId, 1, totalMetaInvoiceCreated);
        IAdvancedPaymentProcessor.MetaInvoice memory metaInv = advancedPP.getMetaInvoice(invoiceId);
        if (metaInv.price == 0) return;

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), metaInv.price);
        uint256[] memory ids = advancedPP.getSubInvoiceIdsForMetaInvoice(invoiceId);

        for (uint256 i; i < ids.length; i++) {
            IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(ids[i]);
            if (inv.escrow != address(0)) return;
        }

        vm.prank(buyer);
        advancedPP.payMetaInvoice{ value: tokenValue }(invoiceId, address(0));
    }

    function acceptInvoice(uint256 invoiceId) public onlyExistingInvoice countCall(this.acceptInvoice.selector) {
        invoiceId = bound(invoiceId, 1, totalSingleInvoiceCreated);
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != advancedPP.PAID()) return;

        vm.prank(seller);
        advancedPP.acceptInvoice(invoiceId);
    }

    function cancelInvoice(uint256 invoiceId) public onlyExistingInvoice countCall(this.cancelInvoice.selector) {
        invoiceId = bound(invoiceId, 1, totalSingleInvoiceCreated);
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != advancedPP.PAID()) return;

        vm.prank(seller);
        advancedPP.cancelInvoice(invoiceId);
    }

    function requestCancelation(uint256 invoiceId)
        public
        onlyExistingInvoice
        countCall(this.requestCancelation.selector)
    {
        invoiceId = bound(invoiceId, 1, totalSingleInvoiceCreated);
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != advancedPP.PAID()) return;

        vm.prank(buyer);
        advancedPP.requestCancelation(invoiceId);
    }

    function handleCancelation(uint256 invoiceId, bool accept)
        public
        onlyExistingInvoice
        countCall(this.handleCancelation.selector)
    {
        invoiceId = bound(invoiceId, 1, totalSingleInvoiceCreated);
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != advancedPP.CANCELATION_REQUESTED()) return;

        vm.prank(buyer);
        advancedPP.handleCancelationRequest(invoiceId, accept);
    }

    function createDispute(uint256 invoiceId) public onlyExistingInvoice countCall(this.createDispute.selector) {
        invoiceId = bound(invoiceId, 1, totalSingleInvoiceCreated);
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != advancedPP.ACCEPTED()) return;

        vm.prank(buyer);
        advancedPP.createDispute(invoiceId);
    }

    function resolveDispute(uint256 invoiceId, uint256 resolution, uint256 sellerShare)
        public
        onlyExistingInvoice
        countCall(this.resolveDispute.selector)
    {
        invoiceId = bound(invoiceId, 1, totalSingleInvoiceCreated);
        resolution = bound(resolution, advancedPP.DISPUTE_RESOLVED(), advancedPP.DISPUTE_SETTLED());
        sellerShare = bound(sellerShare, 0, advancedPP.BASIS_POINTS());
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != advancedPP.DISPUTED()) return;

        vm.prank(advancedPP.getMarketplace());
        advancedPP.resolveDispute(invoiceId, resolution.toUint8(), sellerShare);
    }

    function releasePayment(uint256 invoiceId) public onlyExistingInvoice countCall(this.releasePayment.selector) {
        invoiceId = bound(invoiceId, 1, totalSingleInvoiceCreated);
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != advancedPP.ACCEPTED()) return;

        vm.prank(advancedPP.getMarketplace());
        advancedPP.releasePayment(invoiceId);
    }

    function getTotalSingleInvoiceCreated() public view returns (uint256) {
        return totalSingleInvoiceCreated;
    }

    function getTotalMetaInvoiceCreated() public view returns (uint256) {
        return totalMetaInvoiceCreated;
    }

    function callSummary() external view {
        console.log("Advanced Payment processor Call Summary:");
        console.log("-------------------");
        console.log("Create Invoice:", calls[this.createInvoice.selector]);
        console.log("Create Meta Invoice:", calls[this.createMetaInvoice.selector]);
        console.log("Make Single Invoice Payment:", calls[this.makeSingleInvoicePayment.selector]);
        console.log("Make Meta Invoice Payment:", calls[this.makeMetaInvoicePayment.selector]);
        console.log("Accept Invoice:", calls[this.acceptInvoice.selector]);
        console.log("Cancel Invoice:", calls[this.cancelInvoice.selector]);
        console.log("Request Cancelation:", calls[this.requestCancelation.selector]);
        console.log("Handle Cancelation:", calls[this.handleCancelation.selector]);
        console.log("Create Dispute:", calls[this.createDispute.selector]);
        console.log("Resolve Dispute:", calls[this.resolveDispute.selector]);
        console.log("Release Payment:", calls[this.releasePayment.selector]);
    }
}
