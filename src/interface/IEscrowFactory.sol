// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IEscrowFactory {
    struct EscrowCreationParams {
        address seller;
        address buyer;
        uint256 orderId;
        uint256 value;
        address paymentToken;
    }

    /**
     * @notice Predicts the address of a contract based on the provided salt.
     * @dev Uses the CREATE2 opcode for deterministic contract deployment.
     *      This function allows pre-calculating the address before deployment.
     * @param salt The unique salt value used for the contract deployment.
     * @return The address where the contract would be deployed with the given salt.
     */
    function getPredictedAddress(bytes32 salt) external view returns (address);

    /**
     * @notice Computes a unique salt used for deterministic deployments (e.g., CREATE2/CREATE3).
     * @dev This salt is used to deterministically deploy or reference an Escrow contract via CREATE2,
     *      ensuring uniqueness across both standard and meta-invoice deployments.
     * @param seller The address of the invoice seller.
     * @param buyer The address of the invoice buyer.
     * @param orderId A hash representing the invoice content or metadata.
     * @return  A `bytes32` salt value uniquely derived from the input parameters.
     */
    function computeSalt(address seller, address buyer, uint256 orderId) external pure returns (bytes32);

    /**
     * @notice Emitted when a new escrow contract is created.
     * @param orderId The unique ID of the invoice associated with the escrow.
     * @param escrow The address of the newly created escrow contract.
     */
    event EscrowCreated(uint256 indexed orderId, address indexed escrow);
}
