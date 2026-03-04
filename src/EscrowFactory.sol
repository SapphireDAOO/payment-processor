// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { CREATE3 } from "solady/utils/CREATE3.sol";

import { Escrow } from "./Escrow.sol";
import { IEscrowFactory } from "./interface/IEscrowFactory.sol";

/**
 * @title EscrowFactory
 * @notice Abstract factory for deploying Escrow contracts deterministically.
 * @dev Uses CREATE3 or CREATE2 to generate predictable addresses. Must be inherited by a processor contract.
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
     *      If the payment is in ERC20, no native ETH is sent during deployment. Constructor arguments include the invoice ID,
     *      seller, buyer, and payment processor (this contract).
     * @param _params Struct containing:
     *  - seller: The address of the seller or invoice creator.
     *  - buyer: The address of the payer (msg.sender).
     *  - invoiceId: The unique identifier of the invoice.
     *  - value: The value of the payment in wei (used only for native ETH payments).
     *  - paymentToken: The token address used for payment; address(0) indicates native ETH.
     * @return escrow The address of the newly deployed Escrow contract.
     */
    function _create(EscrowCreationParams memory _params) internal returns (address escrow) {
        bytes memory constructorArg = abi.encode(_params.invoiceId, _params.seller, _params.buyer, address(this));
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
