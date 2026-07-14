// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { LibString } from "solady/utils/LibString.sol";
import {
    IIntermediatedPaymentProcessor,
    IntermediatedPaymentProcessor
} from "../../src/IntermediatedPaymentProcessor.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";

import { BASIS_POINTS } from "src/constants/Intermediated.sol";

/**
 * @notice Builds a single invoice creation parameter struct.
 * @param _invoiceNonce The invoice nonce used as a string identifier.
 * @param _seller The seller address for the invoice.
 * @param _price The invoice price in USD (8 decimals).
 * @return invoiceParam The populated invoice creation parameters.
 */
function getInvoiceCreationParam(uint256 _invoiceNonce, address _seller, uint256 _price)
    pure
    returns (IIntermediatedPaymentProcessor.InvoiceCreationParam memory invoiceParam)
{
    invoiceParam.invoiceId = LibString.toString(_invoiceNonce);
    invoiceParam.seller = _seller;
    invoiceParam.price = _price;
}

/**
 * @notice Builds invoice creation parameters and expected sub-invoice IDs for a batch.
 * @param _invoiceNonce The starting invoice nonce.
 * @param _sellers The list of sellers.
 * @param _prices The list of prices in USD (8 decimals).
 * @return params The array of invoice creation parameters.
 * @return subInvoiceIds The expected sub-invoice IDs derived from invoice IDs.
 */
function getInvoiceCreationParams(uint256 _invoiceNonce, address[] memory _sellers, uint256[] memory _prices)
    pure
    returns (IIntermediatedPaymentProcessor.InvoiceCreationParam[] memory params, uint216[] memory subInvoiceIds)
{
    uint256 numberOfInvoice = _sellers.length;
    params = new IIntermediatedPaymentProcessor.InvoiceCreationParam[](numberOfInvoice);
    subInvoiceIds = new uint216[](numberOfInvoice);

    for (uint256 i; i < numberOfInvoice; i++) {
        params[i] = getInvoiceCreationParam(_invoiceNonce + i, _sellers[i], _prices[i]);
        subInvoiceIds[i] = SafeCastLib.toUint216(uint256(keccak256(abi.encode(params[i].invoiceId))) & ((1 << 216) - 1));
    }
    return (params, subInvoiceIds);
}

/**
 * @notice Applies basis points to an amount using the processor's BASIS_POINTS constant.
 * @param _amount The base amount to apply the percentage to.
 * @param _basisPoints The basis points value to apply.
 * @return appliedAmount The amount after applying the basis points.
 */
function applyBasisPoints(uint256 _amount, uint256 _basisPoints) pure returns (uint256 appliedAmount) {
    appliedAmount = (_amount * _basisPoints) / BASIS_POINTS;
}

/**
 * @notice Computes the escrow address for a given invoice.
 * @param _pp The intermediated payment processor instance.
 * @param _seller The seller address.
 * @param _buyer The buyer address.
 * @param _invoiceId The invoice ID.
 * @return escrowAddress The predicted escrow contract address.
 */
function getEscrowAddress(IntermediatedPaymentProcessor _pp, address _seller, address _buyer, uint216 _invoiceId)
    view
    returns (address escrowAddress)
{
    bytes32 salt = _pp.computeSalt(_seller, _buyer, _invoiceId);
    escrowAddress = _pp.getPredictedAddress(salt, _invoiceId);
}
