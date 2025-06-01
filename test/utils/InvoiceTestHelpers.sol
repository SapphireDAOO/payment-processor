// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";

function getInvoiceCreationParam(
    address buyer,
    address seller,
    uint256 price,
    uint32 timeBeforeCancelation,
    uint32 releaseWindow
) pure returns (IAdvancedPaymentProcessor.InvoiceCreationParam memory) {
    IAdvancedPaymentProcessor.InvoiceCreationParam memory param;
    param.seller = seller;
    param.buyer = buyer;
    param.price = price;
    param.timeBeforeCancelation = timeBeforeCancelation;
    param.releaseWindow = releaseWindow;
    param.invoiceExpiryDuration = 1 days;

    return param;
}

function getInvoiceCreationParams(
    address buyer,
    address[] memory sellers,
    uint256[] memory prices,
    uint32[] memory timeBeforeCancelation,
    uint32[] memory disputeWindow
) pure returns (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory) {
    uint256 numberOfInvoice = sellers.length;
    IAdvancedPaymentProcessor.InvoiceCreationParam[] memory params =
        new IAdvancedPaymentProcessor.InvoiceCreationParam[](numberOfInvoice);

    for (uint256 i; i < numberOfInvoice; i++) {
        params[i] = getInvoiceCreationParam(buyer, sellers[i], prices[i], timeBeforeCancelation[i], disputeWindow[i]);
    }
    return params;
}

function applyBasisPoints(AdvancedPaymentProcessor pp, uint256 amount, uint256 basisPoints) view returns (uint256) {
    return (amount * basisPoints) / pp.BASIS_POINTS();
}

function getSubInvoiceIdsForMetaInvoice(AdvancedPaymentProcessor pp, bytes32 metaInvoiceKey)
    view
    returns (uint256[] memory)
{
    IAdvancedPaymentProcessor.MetaInvoice memory meta = pp.getMetaInvoice(metaInvoiceKey);
    uint256 count = meta.upper - meta.lower + 1;
    uint256[] memory ids = new uint256[](count);

    for (uint256 i = 0; i < count; i++) {
        ids[i] = meta.lower + i;
    }

    return ids;
}

function getSubInvoiceKeyOfMetaInvoice(AdvancedPaymentProcessor pp, address buyer, bytes32 metaInvoiceKey)
    view
    returns (bytes32[] memory)
{
    IAdvancedPaymentProcessor.MetaInvoice memory meta = pp.getMetaInvoice(metaInvoiceKey);
    uint256 count = meta.upper - meta.lower + 1;

    bytes32[] memory subInvoiceKey = new bytes32[](count);

    for (uint256 i = 0; i < count; i++) {
        subInvoiceKey[i] = computeSingleInvoiceKey(buyer, address(pp), meta.lower + i);
    }

    return subInvoiceKey;
}

function getEscrowAddress(AdvancedPaymentProcessor pp, address seller, address buyer, bytes32 invoiceKey)
    view
    returns (address)
{
    bytes32 salt = pp.computeSalt(seller, buyer, invoiceKey);
    return pp.getPredictedAddress(salt);
}

function computeSingleInvoiceKey(address buyer, address issuer, uint256 invoiceId) pure returns (bytes32) {
    return keccak256(abi.encode(buyer, issuer, invoiceId));
}

function computeMetaInvoiceKey(address buyer, uint256 lower, uint256 upper) pure returns (bytes32) {
    return keccak256(abi.encode(buyer, lower, upper, lower + upper));
}
