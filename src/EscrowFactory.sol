// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { CREATE3 } from "solady/utils/CREATE3.sol";

import { Escrow } from "./Escrow.sol";
import { IEscrowFactory } from "./interface/IEscrowFactory.sol";

/**
 * @title EscrowFactory
 * @notice Abstract factory for deploying Escrow contracts deterministically.
 * @dev Uses CREATE3 to generate predictable addresses. Must be inherited by a processor contract.
 */
abstract contract EscrowFactory is IEscrowFactory {
    /// @inheritdoc IEscrowFactory
    function computeSalt(address _seller, address _buyer, uint216 _invoiceId) public pure returns (bytes32 salt) {
        return keccak256(abi.encode(_seller, _buyer, _invoiceId));
    }

    /// @inheritdoc IEscrowFactory
    function getPredictedAddress(bytes32 _salt) public view returns (address predictedAddress) {
        return CREATE3.predictDeterministicAddress(_salt);
    }

    /**
     * @notice Deploys a new Escrow contract deterministically using CREATE3.
     * @dev Uses a unique salt derived from the seller, buyer, and invoice ID to ensure predictable address generation.
     *      The Escrow constructor receives only the invoice ID and the payment processor address (this contract);
     *      seller and buyer are not passed as constructor args — they are used solely for salt derivation.
     *      For ERC20 payments, `value` is forced to zero and tokens are transferred to the escrow separately.
     * @param _params See {IEscrowFactory.EscrowCreationParams}.
     * @return escrow The address of the newly deployed Escrow contract.
     */
    function _create(EscrowCreationParams memory _params) internal returns (address escrow) {
        bytes memory constructorArg = abi.encode(_params.invoiceId, address(this));
        bytes32 salt = computeSalt(_params.seller, _params.buyer, _params.invoiceId);

        if (_params.paymentToken != address(0)) {
            _params.value = 0;
        }

        escrow = CREATE3.deployDeterministic(
            _params.value, abi.encodePacked(type(Escrow).creationCode, constructorArg), salt
        );

        emit EscrowCreated(_params.invoiceId, escrow);
        return escrow;
    }
}
