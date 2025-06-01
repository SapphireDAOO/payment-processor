// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { CREATE3 } from "solady/utils/CREATE3.sol";

import { Escrow, IEscrow } from "./Escrow.sol";
import { IEscrowFactory } from "./interface/IEscrowFactory.sol";

abstract contract EscrowFactory is IEscrowFactory {
    /// @inheritdoc IEscrowFactory
    function computeSalt(address seller, address buyer, bytes32 invoiceKey) public pure returns (bytes32) {
        return keccak256(abi.encode(seller, buyer, invoiceKey));
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
        bytes memory constructorArg = abi.encode(params.invoiceKey, params.seller, params.buyer, address(this));
        bytes32 salt = computeSalt(params.seller, params.buyer, params.invoiceKey);

        if (params.paymentToken != address(0)) {
            params.value = 0;
        }

        address escrow =
            CREATE3.deployDeterministic(params.value, abi.encodePacked(type(Escrow).creationCode, constructorArg), salt);

        emit EscrowCreated(params.invoiceKey, escrow);
        return escrow;
    }
}
