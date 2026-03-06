// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISimplePaymentProcessor, SimplePaymentProcessor } from "../../../src/SimplePaymentProcessor.sol";
import { Test } from "forge-std/Test.sol";

contract SimplePaymentProcessorHandler is Test {
    SimplePaymentProcessor public pp;

    uint256 private totalInvoiceCreated;

    address admin;
    address seller;
    address buyer;

    uint256 constant INVOICE_PRICE = 1000 ether;

    uint256 constant BUYERS_INITIAL_FUND = 10_000 ether;

    uint216[] invoiceIds;

    mapping(uint256 => uint256) public price;

    modifier invoiceExists() {
        if (invoiceIds.length == 0) return;
        _;
    }

    constructor(SimplePaymentProcessor _sPP, address _buyersAddr, address _sellersAddr, address _adminAddr) {
        totalInvoiceCreated = 0;
        seller = _sellersAddr;
        buyer = _buyersAddr;
        admin = _adminAddr;

        pp = _sPP;
    }

    function createInvoice(uint256 _price) public {
        uint256 minValue = pp.getMinimumInvoiceValue();
        if (minValue > INVOICE_PRICE) return;
        _price = bound(_price, minValue, INVOICE_PRICE);
        vm.prank(seller);
        uint216 invoiceId = pp.createInvoice(_price, "", false);
        price[invoiceId] = _price;
        invoiceIds.push(invoiceId);
        totalInvoiceCreated++;
    }

    function cancelInvoice(uint256 _index) public invoiceExists {
        _index = _bound(_index);
        uint216 invoiceId = invoiceIds[_index];
        if (pp.getInvoiceData(invoiceId).status != pp.CREATED()) return;
        vm.prank(seller);
        pp.cancelInvoice(invoiceId);
    }

    function makePayment(uint256 _index, uint256 _value) public invoiceExists {
        _index = _bound(_index);
        uint216 invoiceId = invoiceIds[_index];
        ISimplePaymentProcessor.Invoice memory inv = pp.getInvoiceData(invoiceId);
        if (inv.status != pp.CREATED()) return;
        if (block.timestamp > inv.invalidateAt) return;
        _value = bound(_value, inv.price, inv.price);

        vm.prank(buyer);
        pp.pay{ value: _value }(invoiceId, "", false);
    }

    function acceptPayment(uint256 _index) public invoiceExists {
        _index = _bound(_index);
        uint216 invoiceId = invoiceIds[_index];
        ISimplePaymentProcessor.Invoice memory i = pp.getInvoiceData(invoiceId);
        if (i.status != pp.PAID()) return;
        if (block.timestamp > i.expiresAt) return;
        vm.prank(seller);
        pp.acceptPayment(invoiceId);
    }

    function rejectPayment(uint256 _index) public invoiceExists {
        _index = _bound(_index);
        uint216 invoiceId = invoiceIds[_index];
        ISimplePaymentProcessor.Invoice memory i = pp.getInvoiceData(invoiceId);
        if (i.status != pp.PAID()) return;
        if (block.timestamp > i.expiresAt) return;
        vm.prank(seller);
        pp.rejectPayment(invoiceId);
    }

    function release(uint256 _index) public invoiceExists {
        _index = _bound(_index);
        uint216 invoiceId = invoiceIds[_index];

        if (pp.getInvoiceData(invoiceId).status != pp.ACCEPTED()) return;

        uint256 eligibleAt = uint256(pp.getInvoiceData(invoiceId).releaseAt);
        if (block.timestamp <= eligibleAt) {
            vm.warp(eligibleAt + 1);
        }

        vm.prank(seller);
        pp.release(invoiceId);
    }

    function setInvoiceReleaseTime(uint256 _index, uint32 _holdPeriod) public invoiceExists {
        _index = _bound(_index);
        uint216 invoiceId = invoiceIds[_index];
        if (pp.getInvoiceData(invoiceId).status != pp.ACCEPTED()) return;
        _holdPeriod = uint32(bound(uint256(_holdPeriod), 1 hours, 30 days));
        vm.prank(admin);
        pp.setInvoiceReleaseTime(invoiceId, _holdPeriod);
    }

    function setMinimumInvoiceValue(uint256 _newMin) public {
        _newMin = bound(_newMin, 0, 100 ether);
        vm.prank(admin);
        pp.setMinimumInvoiceValue(_newMin);
    }

    function setDecisionWindow(uint256 _newWindow) public {
        _newWindow = bound(_newWindow, 1 hours, 7 days);
        vm.prank(admin);
        pp.setDecisionWindow(_newWindow);
    }

    function refundBuyer(uint256 _index) public invoiceExists {
        _index = _bound(_index);
        uint216 invoiceId = invoiceIds[_index];
        ISimplePaymentProcessor.Invoice memory inv = pp.getInvoiceData(invoiceId);
        if (inv.status != pp.PAID()) return;
        if (block.timestamp < inv.expiresAt) vm.warp(uint256(inv.expiresAt) + 1);
        pp.refundBuyer(invoiceId);
    }

    function performUpkeep() public {
        vm.prank(admin);
        pp.performUpkeep("");
    }

    /// @notice Returns the total number of invoices created by the handler.
    function getTotalInvoiceCreated() external view returns (uint256 totalInvoices) {
        return totalInvoiceCreated;
    }

    /**
     * @notice Bounds an index to the current invoiceIds array length.
     * @param _index The index to bound.
     * @return boundedIndex The bounded index.
     */
    function _bound(uint256 _index) internal view returns (uint256 boundedIndex) {
        return bound(_index, 0, invoiceIds.length - 1);
    }

    /// @notice Returns the number of tracked invoices.
    function getInvoiceCount() external view returns (uint256 count) {
        return invoiceIds.length;
    }

    /// @notice Returns the invoice id at a given index.
    function getInvoiceId(uint256 _index) external view returns (uint216 invoiceId) {
        return invoiceIds[_index];
    }
}
