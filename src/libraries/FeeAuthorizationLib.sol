// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ECDSA } from "solady/utils/ECDSA.sol";

/**
 * @title FeeAuthorizationLib
 * @notice Verifies that a per-invoice fee receiver was authorized by the configured fee signer.
 * @dev The signed message is an EIP-191 `personal_sign` digest over the processor address, the chain
 *      id, the invoice ID, and the fee receiver(s), so a signature is bound to one invoice on one
 *      processor on one chain. Invoices only accept a fee receiver once, in a state transition that
 *      cannot be repeated, so no separate nonce or deadline is required. A meta-invoice authorizes
 *      the whole array of sub-invoice receivers with a single signature; because the array is
 *      abi-encoded as a dynamic type its digest cannot collide with a single-receiver one.
 */
library FeeAuthorizationLib {
    /**
     * @notice Recovers the signer of a fee authorization and reports whether it matches `_feeSigner`.
     * @param _feeSigner The address expected to have produced the signature.
     * @param _invoiceId The invoice the fee receiver is being attached to.
     * @param _feeReceiver The fee receiver being authorized.
     * @param _signature The 65-byte ECDSA signature over the authorization digest.
     * @return valid True when the recovered address equals `_feeSigner`.
     */
    function isAuthorized(address _feeSigner, uint216 _invoiceId, address _feeReceiver, bytes memory _signature)
        internal
        view
        returns (bool valid)
    {
        address recovered = ECDSA.tryRecover(digest(_invoiceId, _feeReceiver), _signature);
        return recovered != address(0) && recovered == _feeSigner;
    }

    /**
     * @notice Builds the EIP-191 digest a fee signer must sign to authorize a fee receiver.
     * @param _invoiceId The invoice the fee receiver is being attached to.
     * @param _feeReceiver The fee receiver being authorized.
     * @return authorizationDigest The `personal_sign` digest to be signed.
     */
    function digest(uint216 _invoiceId, address _feeReceiver) internal view returns (bytes32 authorizationDigest) {
        return
            ECDSA.toEthSignedMessageHash(keccak256(abi.encode(address(this), block.chainid, _invoiceId, _feeReceiver)));
    }

    /**
     * @notice Recovers the signer of a meta-invoice fee authorization covering every sub-invoice.
     * @param _feeSigner The address expected to have produced the signature.
     * @param _metaInvoiceId The meta-invoice whose sub-invoices are being paid.
     * @param _feeReceivers The fee receivers, index-aligned with the meta-invoice's sub-invoice IDs.
     * @param _signature The 65-byte ECDSA signature over the authorization digest.
     * @return valid True when the recovered address equals `_feeSigner`.
     */
    function isAuthorized(
        address _feeSigner,
        uint216 _metaInvoiceId,
        address[] memory _feeReceivers,
        bytes memory _signature
    ) internal view returns (bool valid) {
        address recovered = ECDSA.tryRecover(digest(_metaInvoiceId, _feeReceivers), _signature);
        return recovered != address(0) && recovered == _feeSigner;
    }

    /**
     * @notice Builds the EIP-191 digest authorizing every fee receiver of a meta-invoice at once.
     * @param _metaInvoiceId The meta-invoice whose sub-invoices are being paid.
     * @param _feeReceivers The fee receivers, index-aligned with the meta-invoice's sub-invoice IDs.
     * @return authorizationDigest The `personal_sign` digest to be signed.
     */
    function digest(uint216 _metaInvoiceId, address[] memory _feeReceivers)
        internal
        view
        returns (bytes32 authorizationDigest)
    {
        return ECDSA.toEthSignedMessageHash(
            keccak256(abi.encode(address(this), block.chainid, _metaInvoiceId, _feeReceivers))
        );
    }
}
