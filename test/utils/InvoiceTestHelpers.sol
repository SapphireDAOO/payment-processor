// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { LibString } from "solady/utils/LibString.sol";
import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";

function getInvoiceCreationParam(uint256 invoiceId, address seller, uint256 price)
    pure
    returns (IAdvancedPaymentProcessor.InvoiceCreationParam memory)
{
    IAdvancedPaymentProcessor.InvoiceCreationParam memory param;
    param.orderId = LibString.toString(invoiceId);
    param.seller = seller;
    param.price = price;

    return param;
}

function getInvoiceCreationParams(uint256 invoiceId, address[] memory sellers, uint256[] memory prices)
    pure
    returns (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory, uint256[] memory)
{
    uint256 numberOfInvoice = sellers.length;
    IAdvancedPaymentProcessor.InvoiceCreationParam[] memory params =
        new IAdvancedPaymentProcessor.InvoiceCreationParam[](numberOfInvoice);
    uint256[] memory suborderIds = new uint256[](numberOfInvoice);

    for (uint256 i; i < numberOfInvoice; i++) {
        params[i] = getInvoiceCreationParam(invoiceId + i, sellers[i], prices[i]);
        suborderIds[i] = uint256(keccak256(abi.encode(params[i].orderId)));
    }
    return (params, suborderIds);
}

function applyBasisPoints(AdvancedPaymentProcessor pp, uint256 amount, uint256 basisPoints) view returns (uint256) {
    return (amount * basisPoints) / pp.BASIS_POINTS();
}

function getEscrowAddress(AdvancedPaymentProcessor pp, address seller, address buyer, uint256 orderId)
    view
    returns (address)
{
    bytes32 salt = pp.computeSalt(seller, buyer, orderId);
    return pp.getPredictedAddress(salt);
}
