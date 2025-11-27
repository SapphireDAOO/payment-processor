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
    function computeSalt(address seller, address buyer, uint216 orderId) public pure returns (bytes32) {
        return keccak256(abi.encode(seller, buyer, orderId));
    }

    /// @inheritdoc IEscrowFactory
    function getPredictedAddress(bytes32 salt) public view returns (address) {
        return CREATE3.predictDeterministicAddress(salt);
    }

    /**
     * @notice Deploys a new Escrow contract deterministically using CREATE3.
     * @dev Uses a unique salt derived from the seller, buyer, and invoice ID to ensure predictable address generation.
     *      If the payment is in ERC20, no native ETH is sent during deployment. Constructor arguments include the invoice ID,
     *      seller, buyer, and payment processor (this contract).
     * @param params Struct containing:
     *  - seller: The address of the seller or invoice creator.
     *  - buyer: The address of the payer (msg.sender).
     *  - invoiceId: The unique identifier of the invoice.
     *  - value: The value of the payment in wei (used only for native ETH payments).
     *  - paymentToken: The token address used for payment; address(0) indicates native ETH.
     * @return escrow The address of the newly deployed Escrow contract.
     */
    function _create(EscrowCreationParams memory params) internal returns (address) {
        bytes memory constructorArg = abi.encode(params.orderId, params.seller, params.buyer, address(this));
        bytes32 salt = computeSalt(params.seller, params.buyer, params.orderId);

        if (params.paymentToken != address(0)) {
            params.value = 0;
        }

        address escrow = CREATE3.deployDeterministic(
            params.value, abi.encodePacked(type(Escrow).creationCode, constructorArg), salt
        );

        emit EscrowCreated(params.orderId, escrow);
        return escrow;
    }
}
