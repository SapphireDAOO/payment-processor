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

function getSubInvoiceIdsForMetaInvoice(AdvancedPaymentProcessor pp, uint256 metaInvoiceId)
    view
    returns (uint256[] memory)
{
    IAdvancedPaymentProcessor.MetaInvoice memory meta = pp.getMetaInvoice(metaInvoiceId);
    uint256 count = meta.upper - meta.lower + 1;
    uint256[] memory ids = new uint256[](count);

    for (uint256 i = 0; i < count; i++) {
        ids[i] = meta.lower + i;
    }

    return ids;
}

function getEscrowAddress(AdvancedPaymentProcessor pp, address seller, address buyer, uint256 invoiceId)
    view
    returns (address)
{
    bytes32 salt = pp.computeSalt(seller, buyer, invoiceId);
    return pp.getPredictedAddress(salt);
}
