// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { LibString } from "solady/utils/LibString.sol";
import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";

function getInvoiceCreationParam(uint256 invoiceNonce, address seller, uint256 price)
    pure
    returns (IAdvancedPaymentProcessor.InvoiceCreationParam memory)
{
    IAdvancedPaymentProcessor.InvoiceCreationParam memory param;
    param.invoiceId = LibString.toString(invoiceNonce);
    param.seller = seller;
    param.price = price;

    return param;
}

function getInvoiceCreationParams(uint256 invoiceNonce, address[] memory sellers, uint256[] memory prices)
    pure
    returns (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory, uint216[] memory)
{
    uint256 numberOfInvoice = sellers.length;
    IAdvancedPaymentProcessor.InvoiceCreationParam[] memory params =
        new IAdvancedPaymentProcessor.InvoiceCreationParam[](numberOfInvoice);
    uint216[] memory subinvoiceIds = new uint216[](numberOfInvoice);

    for (uint256 i; i < numberOfInvoice; i++) {
        params[i] = getInvoiceCreationParam(invoiceNonce + i, sellers[i], prices[i]);
        subinvoiceIds[i] = SafeCastLib.toUint216(uint256(keccak256(abi.encode(params[i].invoiceId))) & ((1 << 216) - 1));
    }
    return (params, subinvoiceIds);
}

function applyBasisPoints(AdvancedPaymentProcessor pp, uint256 amount, uint256 basisPoints) view returns (uint256) {
    return (amount * basisPoints) / pp.BASIS_POINTS();
}

function getEscrowAddress(AdvancedPaymentProcessor pp, address seller, address buyer, uint216 invoiceId)
    view
    returns (address)
{
    bytes32 salt = pp.computeSalt(seller, buyer, invoiceId);
    return pp.getPredictedAddress(salt);
}
