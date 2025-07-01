// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { LibString } from "solady/utils/LibString.sol";
import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "../../src/AdvancedPaymentProcessor.sol";

function getInvoiceCreationParam(
    uint256 invoiceId,
    address seller,
    uint256 price,
    uint32 timeBeforeCancelation,
    uint32 releaseWindow
) pure returns (IAdvancedPaymentProcessor.InvoiceCreationParam memory) {
    IAdvancedPaymentProcessor.InvoiceCreationParam memory param;
    param.orderId = LibString.toString(invoiceId);
    param.seller = seller;
    param.price = price;
    param.timeBeforeCancelation = timeBeforeCancelation;
    param.releaseWindow = releaseWindow;
    param.invoiceExpiryDuration = 1 days;

    return param;
}

function getInvoiceCreationParams(
    uint256 invoiceId,
    address[] memory sellers,
    uint256[] memory prices,
    uint32[] memory timeBeforeCancelation,
    uint32[] memory disputeWindow
) pure returns (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory, bytes32[] memory) {
    uint256 numberOfInvoice = sellers.length;
    IAdvancedPaymentProcessor.InvoiceCreationParam[] memory params =
        new IAdvancedPaymentProcessor.InvoiceCreationParam[](numberOfInvoice);
    bytes32[] memory suborderIds = new bytes32[](numberOfInvoice);

    for (uint256 i; i < numberOfInvoice; i++) {
        params[i] =
            getInvoiceCreationParam(invoiceId + i, sellers[i], prices[i], timeBeforeCancelation[i], disputeWindow[i]);
        suborderIds[i] = keccak256(abi.encode(params[i].orderId));
    }
    return (params, suborderIds);
}

function applyBasisPoints(AdvancedPaymentProcessor pp, uint256 amount, uint256 basisPoints) view returns (uint256) {
    return (amount * basisPoints) / pp.BASIS_POINTS();
}

function getEscrowAddress(AdvancedPaymentProcessor pp, address seller, address buyer, bytes32 orderId)
    view
    returns (address)
{
    bytes32 salt = pp.computeSalt(seller, buyer, orderId);
    return pp.getPredictedAddress(salt);
}

function computeSingleorderId(address buyer, address issuer, uint256 invoiceId) pure returns (bytes32) {
    return keccak256(abi.encode(buyer, issuer, invoiceId));
}

function computeMetaorderId(uint256 lower, uint256 upper, uint256 salt) view returns (bytes32) {
    return keccak256(abi.encode(lower, upper, salt, block.timestamp));
}
