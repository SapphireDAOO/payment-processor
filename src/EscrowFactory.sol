// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { CREATE3 } from "solady/utils/CREATE3.sol";

import { IEscrow, Escrow } from "./Escrow.sol";
import { IEscrowFactory } from "./interface/IEscrowFactory.sol";

abstract contract EscrowFactory is IEscrowFactory {
    /// @inheritdoc IEscrowFactory
    function computeSalt(address _creator, address _payer, uint256 _invoiceId) public pure returns (bytes32) {
        return keccak256(abi.encode(_creator, _payer, _invoiceId));
    }

    /// @inheritdoc IEscrowFactory
    function getPredictedAddress(bytes32 _salt) public view returns (address) {
        return CREATE3.predictDeterministicAddress(_salt);
    }

    /**
     * @notice Creates a new Escrow contract deterministically using CREATE3.
     * @dev This function deploys the `Escrow` contract at a deterministic address, based on the provided arguments.
     *      The function uses `CREATE3.deployDeterministic` to ensure that the contract is deployed at a fixed address
     * @param _creator The address of the creator of the escrow.
     * @param _invoiceId The unique ID of the invoice associated with this escrow.
     * @param _invoicePaymentValue The value of the payment associated with the escrow.
     * @return The address of the newly deployed `Escrow` contract.
     */
    function _create(address _creator, uint256 _invoiceId, uint256 _invoicePaymentValue) internal returns (address) {
        bytes memory constructorArg = abi.encode(_invoiceId, _creator, msg.sender, address(this));
        bytes32 salt = computeSalt(_creator, msg.sender, _invoiceId);

        address escrow = CREATE3.deployDeterministic(
            _invoicePaymentValue, abi.encodePacked(type(Escrow).creationCode, constructorArg), salt
        );

        emit EscrowCreated(_invoiceId, escrow);

        return escrow;
    }
}
