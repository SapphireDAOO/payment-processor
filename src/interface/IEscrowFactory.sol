// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IEscrowFactory {
    /**
     * @notice Predicts the address of a contract based on the provided salt.
     * @dev Uses the CREATE2 opcode for deterministic contract deployment.
     *      This function allows pre-calculating the address before deployment.
     * @param _salt The unique salt value used for the contract deployment.
     * @return The address where the contract would be deployed with the given salt.
     */
    function getPredictedAddress(bytes32 _salt) external view returns (address);

    /**
     * @notice Computes a unique salt value based on the provided parameters.
     * @dev The salt is used to deterministically deploy or identify contracts via CREATE2.
     * @param _creator The address of the invoice creator.
     * @param _payer The address of the payer associated with the invoice.
     * @param _invoiceId The unique ID of the invoice.
     * @return A `bytes32` salt value derived from the input parameters.
     */
    function computeSalt(address _creator, address _payer, uint256 _invoiceId) external pure returns (bytes32);

    /**
     * @notice Emitted when a new escrow contract is created.
     * @param invoiceId The unique ID of the invoice associated with the escrow.
     * @param escrow The address of the newly created escrow contract.
     */
    event EscrowCreated(uint256 indexed invoiceId, address indexed escrow);
}
