// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { console } from "forge-std/console.sol";
import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../../src/AdvancedPaymentProcessor.sol";
import { Test } from "forge-std/Test.sol";
import { getInvoiceCreationParam, getInvoiceCreationParams } from "../../utils/InvoiceTestHelpers.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { LibString } from "solady/utils/LibString.sol";

contract AdvancedPaymentProcessorHandler is Test {
    using SafeCastLib for uint256;
    using LibString for uint256;

    AdvancedPaymentProcessor advancedPP;

    address admin;
    address buyer;
    address seller;

    uint256 private totalSingleInvoiceCreated;
    uint256 private totalMetaInvoiceCreated;

    mapping(bytes4 => uint256) calls;

    uint216[] singleInvoiceIds;
    uint216[] metaInvoiceIds;
    uint216[] singleAndSubInvoice;

    mapping(uint216 => uint216[]) subInvoice;

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

    function createInvoice(uint256 price) public countCall(this.createInvoice.selector) {
        uint216 identifier = (uint256(keccak256(abi.encode(totalSingleInvoiceCreated))) & ((1 << 216) - 1)).toUint216();
        if (advancedPP.getInvoice(identifier).state != 0) {
            return;
        }
        price = bound(price, 1e8, 1_000e8);

        vm.prank(advancedPP.ppStorage().getMarketplace());

        uint216 id = advancedPP.createSingleInvoice(getInvoiceCreationParam(totalSingleInvoiceCreated, seller, price));

        singleAndSubInvoice.push(id);
        totalSingleInvoiceCreated++;
    }

    function createMetaInvoice(uint256 priceO, uint256 priceT) public countCall(this.createMetaInvoice.selector) {
        priceO = bound(priceO, 1e8, 1_000e8);
        priceT = bound(priceT, 1e8, 1_000e8);

        address[] memory sellers = new address[](2);
        sellers[0] = seller;
        sellers[1] = seller;

        uint256[] memory prices = new uint256[](2);
        prices[0] = priceO;
        prices[1] = priceT;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(totalSingleInvoiceCreated, sellers, prices);

        vm.prank(advancedPP.ppStorage().getMarketplace());
        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);
        metaInvoiceIds.push(metaInvoiceId);

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            subInvoice[metaInvoiceId].push(invoiceIds[i]);
            singleAndSubInvoice.push(invoiceIds[i]);
        }

        totalSingleInvoiceCreated += sellers.length;
        totalMetaInvoiceCreated++;
    }

    function makeSingleInvoicePayment(uint256 index)
        public
        onlyExistingInvoice
        countCall(this.makeSingleInvoicePayment.selector)
    {
        if (singleInvoiceIds.length == 0) return;
        index = bound(index, 0, singleInvoiceIds.length - 1);
        uint216 invoiceId = singleInvoiceIds[index];
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), inv.price);

        if (inv.state == advancedPP.CREATED()) return;
        vm.prank(buyer);
        advancedPP.paySingleInvoice{ value: tokenValue }(invoiceId, address(0));
    }

    function makeMetaInvoicePayment(uint256 index) public countCall(this.makeMetaInvoicePayment.selector) {
        uint256 length = metaInvoiceIds.length;
        if (singleInvoiceIds.length == 0) return;
        if (metaInvoiceIds.length == 0) return;

        index = bound(index, 0, length - 1);
        uint216 invoiceId = metaInvoiceIds[index];
        IAdvancedPaymentProcessor.MetaInvoice memory metaInv = advancedPP.getMetaInvoice(invoiceId);

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), metaInv.price);

        uint216[] memory ids = subInvoice[invoiceId];

        bool paid;
        for (uint256 i; i < ids.length; i++) {
            IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(ids[i]);
            if (inv.balance != 0) paid = true;
        }
        if (paid || metaInv.price == 0) return;

        vm.prank(buyer);
        advancedPP.payMetaInvoice{ value: tokenValue }(invoiceId, address(0));
    }

    function cancelInvoice(uint256 index) public onlyExistingInvoice countCall(this.cancelInvoice.selector) {
        if (singleInvoiceIds.length == 0) return;
        index = bound(index, 0, singleInvoiceIds.length - 1);
        uint216 invoiceId = singleInvoiceIds[index];
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != advancedPP.PAID()) return;

        vm.prank(seller);
        advancedPP.cancelInvoice(invoiceId);
    }

    function createDispute(uint256 index) public onlyExistingInvoice countCall(this.createDispute.selector) {
        if (singleInvoiceIds.length == 0) return;
        index = bound(index, 0, singleInvoiceIds.length - 1);
        uint216 invoiceId = singleInvoiceIds[index];
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != advancedPP.PAID()) return;

        vm.prank(buyer);
        advancedPP.createDispute(invoiceId);
    }

    function handleDispute(uint256 index, uint256 resolution, uint256 sellerShare)
        public
        onlyExistingInvoice
        countCall(this.handleDispute.selector)
    {
        if (singleInvoiceIds.length == 0) return;
        index = bound(index, 0, singleInvoiceIds.length - 1);
        uint216 invoiceId = singleInvoiceIds[index];
        resolution = bound(resolution, advancedPP.DISPUTE_DISMISSED(), advancedPP.DISPUTE_SETTLED());
        sellerShare = bound(sellerShare, 0, advancedPP.BASIS_POINTS());
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != advancedPP.DISPUTED()) return;

        vm.prank(advancedPP.ppStorage().getMarketplace());
        advancedPP.handleDispute(invoiceId, resolution.toUint8(), sellerShare);
    }

    function refund(uint256 index, uint256 share) public onlyExistingInvoice countCall(this.refund.selector) {
        if (singleInvoiceIds.length == 0) return;
        index = bound(index, 0, singleInvoiceIds.length - 1);
        share = bound(share, 100, 10_000);
        uint216 invoiceId = singleInvoiceIds[index];

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != advancedPP.PAID()) return;

        vm.prank(advancedPP.ppStorage().getMarketplace());
        advancedPP.refund(invoiceId, share);
    }

    function release(uint256 index, uint256 sellerShare) public onlyExistingInvoice countCall(this.release.selector) {
        if (singleInvoiceIds.length == 0) return;
        index = bound(index, 0, singleInvoiceIds.length - 1);
        sellerShare = bound(sellerShare, 100, 10_000);
        uint216 invoiceId = singleInvoiceIds[index];
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != advancedPP.PAID()) return;

        vm.prank(advancedPP.ppStorage().getMarketplace());
        advancedPP.release(invoiceId);
    }

    function resolveDispute(uint256 index, uint256 senderIndex)
        public
        onlyExistingInvoice
        countCall(this.resolveDispute.selector)
    {
        if (singleInvoiceIds.length == 0) return;
        index = bound(index, 0, singleInvoiceIds.length - 1);
        senderIndex = bound(senderIndex, 0, 1);
        uint216 invoiceId = singleInvoiceIds[index];

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != advancedPP.DISPUTED()) return;

        advancedPP.resolveDispute(invoiceId);
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
        console.log("Cancel Invoice:", calls[this.cancelInvoice.selector]);
        console.log("Create Dispute:", calls[this.createDispute.selector]);
        console.log("Handle Dispute:", calls[this.handleDispute.selector]);
        console.log("Resolve Dispute:", calls[this.resolveDispute.selector]);
        console.log("Refund Payment:", calls[this.refund.selector]);
        console.log("Release Payment:", calls[this.release.selector]);
    }
}
