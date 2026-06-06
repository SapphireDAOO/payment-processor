// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../../src/AdvancedPaymentProcessor.sol";
import { Test } from "forge-std/Test.sol";
import { getInvoiceCreationParam, getInvoiceCreationParams } from "../../utils/InvoiceTestHelpers.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { LibString } from "solady/utils/LibString.sol";

import {
    CREATED,
    PAID,
    DISPUTED,
    DISPUTE_RESOLVED,
    DISPUTE_DISMISSED,
    DISPUTE_SETTLED,
    BASIS_POINTS
} from "src/constants/Advanced.sol";

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

    modifier countCall(bytes4 _key) {
        calls[_key]++;
        _;
    }

    constructor(
        AdvancedPaymentProcessor _advancedPaymentProcessor,
        address _adminAddress,
        address _buyerAddress,
        address _sellerAddress
    ) {
        advancedPP = _advancedPaymentProcessor;
        admin = _adminAddress;
        buyer = _buyerAddress;
        seller = _sellerAddress;
    }

    modifier onlyExistingInvoice() {
        if (totalSingleInvoiceCreated == 0) return;
        _;
    }

    function createInvoice(uint256 _price) public {
        uint216 identifier = (uint256(keccak256(abi.encode(totalSingleInvoiceCreated))) & ((1 << 216) - 1)).toUint216();
        if (advancedPP.getInvoice(identifier).state != 0) {
            return;
        }
        _price = bound(_price, advancedPP.getMinimumPrice(), 1_000e8);

        vm.prank(advancedPP.ppStorage().getMarketplace());

        uint216 id = advancedPP.createSingleInvoice(getInvoiceCreationParam(totalSingleInvoiceCreated, seller, _price));

        singleInvoiceIds.push(id);
        singleAndSubInvoice.push(id);
        totalSingleInvoiceCreated++;
    }

    function createMetaInvoice(uint256 _priceO, uint256 _priceT) public {
        _priceO = bound(_priceO, advancedPP.getMinimumPrice(), 1_000e8);
        _priceT = bound(_priceT, advancedPP.getMinimumPrice(), 1_000e8);

        address[] memory sellers = new address[](2);
        sellers[0] = seller;
        sellers[1] = seller;

        uint256[] memory prices = new uint256[](2);
        prices[0] = _priceO;
        prices[1] = _priceT;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory param, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(totalSingleInvoiceCreated, sellers, prices);

        vm.prank(advancedPP.ppStorage().getMarketplace());
        uint216 metaInvoiceId = advancedPP.createMetaInvoice(param);
        metaInvoiceIds.push(metaInvoiceId);

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            subInvoice[metaInvoiceId].push(invoiceIds[i]);
            singleInvoiceIds.push(invoiceIds[i]);
            singleAndSubInvoice.push(invoiceIds[i]);
        }

        totalSingleInvoiceCreated += sellers.length;
        totalMetaInvoiceCreated++;
    }

    function makeSingleInvoicePayment(uint256 _index) public onlyExistingInvoice {
        if (singleInvoiceIds.length == 0) return;
        _index = bound(_index, 0, singleInvoiceIds.length - 1);
        uint216 invoiceId = singleInvoiceIds[_index];
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

        if (inv.state != CREATED) return;
        if (block.timestamp > inv.expiresAt) return;

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), inv.price);

        vm.prank(buyer);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));
    }

    function makeMetaInvoicePayment(uint256 _index) public {
        uint256 length = metaInvoiceIds.length;
        if (metaInvoiceIds.length == 0) return;

        _index = bound(_index, 0, length - 1);
        uint216 invoiceId = metaInvoiceIds[_index];
        IAdvancedPaymentProcessor.MetaInvoice memory metaInv = advancedPP.getMetaInvoice(invoiceId);

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), metaInv.price);

        uint216[] memory ids = subInvoice[invoiceId];

        bool hasPayable;
        bool paid;
        for (uint256 i; i < ids.length; i++) {
            IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(ids[i]);
            if (inv.state == CREATED && block.timestamp <= inv.expiresAt) hasPayable = true;
            if (inv.balance != 0) paid = true;
        }
        if (!hasPayable || paid || metaInv.price == 0) return;

        vm.prank(buyer);
        advancedPP.payMetaInvoiceWithValue{ value: tokenValue }(invoiceId);
    }

    function cancelInvoice(uint256 _index) public onlyExistingInvoice {
        if (singleInvoiceIds.length == 0) return;
        _index = bound(_index, 0, singleInvoiceIds.length - 1);
        uint216 invoiceId = singleInvoiceIds[_index];
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != CREATED) return;

        vm.prank(advancedPP.ppStorage().getMarketplace());
        advancedPP.cancelInvoice(invoiceId);
    }

    function createDispute(uint256 _index) public onlyExistingInvoice {
        if (singleInvoiceIds.length == 0) return;
        _index = bound(_index, 0, singleInvoiceIds.length - 1);
        uint216 invoiceId = singleInvoiceIds[_index];
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != PAID) return;

        vm.prank(advancedPP.ppStorage().getMarketplace());
        advancedPP.createDispute(invoiceId);
    }

    function handleDispute(uint256 _index, uint256 _resolution, uint256 _sellerShare) public onlyExistingInvoice {
        if (singleInvoiceIds.length == 0) return;
        _index = bound(_index, 0, singleInvoiceIds.length - 1);
        uint216 invoiceId = singleInvoiceIds[_index];
        _resolution = bound(_resolution, DISPUTE_DISMISSED, DISPUTE_SETTLED);
        _sellerShare = bound(_sellerShare, 0, BASIS_POINTS);
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != DISPUTED) return;

        vm.prank(advancedPP.ppStorage().getMarketplace());
        advancedPP.handleDispute(invoiceId, _resolution.toUint8(), _sellerShare);
    }

    function refund(uint256 _index, uint256 _share) public onlyExistingInvoice {
        if (singleInvoiceIds.length == 0) return;
        _index = bound(_index, 0, singleInvoiceIds.length - 1);
        _share = bound(_share, 100, 10_000);
        uint216 invoiceId = singleInvoiceIds[_index];

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != PAID) return;
        if (inv.balance == 0) return;

        vm.prank(advancedPP.ppStorage().getMarketplace());
        advancedPP.refund(invoiceId, _share);
    }

    function release(uint256 _index, uint256 _sellerShare) public onlyExistingInvoice {
        if (singleInvoiceIds.length == 0) return;
        _index = bound(_index, 0, singleInvoiceIds.length - 1);
        _sellerShare = bound(_sellerShare, 100, 10_000);
        uint216 invoiceId = singleInvoiceIds[_index];
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != PAID) return;
        if (block.timestamp <= inv.releaseAt) {
            vm.warp(inv.releaseAt + 1);
        }

        vm.prank(advancedPP.ppStorage().getMarketplace());
        advancedPP.release(invoiceId);
    }

    function resolveDispute(uint256 _index, uint256 _senderIndex) public onlyExistingInvoice {
        if (singleInvoiceIds.length == 0) return;
        _index = bound(_index, 0, singleInvoiceIds.length - 1);
        _senderIndex = bound(_senderIndex, 0, 1);
        uint216 invoiceId = singleInvoiceIds[_index];

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != DISPUTED) return;

        vm.prank(advancedPP.ppStorage().getMarketplace());
        advancedPP.resolveDispute(invoiceId);
    }

    function setInvoiceReleaseTime(uint256 _index, uint256 _holdPeriod) public onlyExistingInvoice {
        if (singleAndSubInvoice.length == 0) return;
        _index = bound(_index, 0, singleAndSubInvoice.length - 1);
        uint216 invoiceId = singleAndSubInvoice[_index];
        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        if (inv.state != PAID && inv.state != DISPUTE_RESOLVED && inv.state != DISPUTE_DISMISSED) return;
        _holdPeriod = bound(_holdPeriod, 1 hours, 30 days);
        vm.prank(admin);
        advancedPP.setInvoiceReleaseTime(invoiceId, _holdPeriod);
    }

    function setMinimumPrice(uint256 _newMin) public {
        _newMin = bound(_newMin, 1e6, 1_000e8);
        vm.prank(admin);
        advancedPP.setMinimumPrice(_newMin);
    }

    /// @notice Returns the total number of single invoices created by the handler.
    function getTotalSingleInvoiceCreated() public view returns (uint256 totalSingleInvoices) {
        return totalSingleInvoiceCreated;
    }

    /// @notice Returns the total number of meta invoices created by the handler.
    function getTotalMetaInvoiceCreated() public view returns (uint256 totalMetaInvoices) {
        return totalMetaInvoiceCreated;
    }

    function getInvoiceCount() external view returns (uint256 count) {
        return singleAndSubInvoice.length;
    }

    function getInvoiceId(uint256 _index) external view returns (uint216 invoiceId) {
        return singleAndSubInvoice[_index];
    }

    function getMetaInvoiceCount() external view returns (uint256 count) {
        return metaInvoiceIds.length;
    }

    function getMetaInvoiceId(uint256 _index) external view returns (uint216 invoiceId) {
        return metaInvoiceIds[_index];
    }

    function getSubInvoiceCount(uint216 _metaInvoiceId) external view returns (uint256 count) {
        return subInvoice[_metaInvoiceId].length;
    }

    function getSubInvoiceId(uint216 _metaInvoiceId, uint256 _index) external view returns (uint216 invoiceId) {
        return subInvoice[_metaInvoiceId][_index];
    }
}
