// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IEscrowFactory
 * @notice Interface for contracts responsible for deploying and managing escrow instances.
 * @dev Used to abstract the creation and configuration of escrow contracts.
 */
interface IEscrowFactory {
    /// @notice Parameters required to initialize an escrow contract.
    struct EscrowCreationParams {
        ///  @notice The address of the seller who will receive the funds upon successful transaction.
        address seller;
        ///  @notice The address of the buyer who deposits the funds into escrow.
        address buyer;
        ///  @notice The unique identifier associated with the invoice or order.
        uint216 orderId;
        ///  @notice The total amount to be held in escrow, denominated in the payment token or native currency.
        uint256 value;
        ///  @notice The address of the token used for payment. Use address(0) for native currency (e.g., ETH).
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
    function computeSalt(address seller, address buyer, uint216 orderId) external pure returns (bytes32);

    /**
     * @notice Emitted when a new escrow contract is created.
     * @param orderId The unique ID of the invoice associated with the escrow.
     * @param escrow The address of the newly created escrow contract.
     */
    event EscrowCreated(uint216 indexed orderId, address indexed escrow);
}
