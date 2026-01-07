// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IEscrowFactory
 * @notice Interface for contracts responsible for deploying and managing escrow instances.
 * @dev Used to abstract the creation and configuration of escrow contracts.
 */
interface IEscrowFactory {
    /// @notice Parameters required to initialize an escrow contract.
    /// @param seller The address of the seller who will receive the funds upon successful transaction.
    /// @param buyer The address of the buyer who deposits the funds into escrow.
    /// @param invoiceId The unique identifier associated with the invoice or order.
    /// @param value The total amount to be held in escrow, denominated in the payment token or native currency.
    /// @param paymentToken The address of the token used for payment. Use address(0) for native currency (e.g., ETH).
    struct EscrowCreationParams {
        address seller;
        address buyer;
        uint216 invoiceId;
        uint256 value;
        address paymentToken;
    }

    /**
     * @notice Predicts the address of a contract based on the provided salt.
     * @dev Uses the CREATE2 opcode for deterministic contract deployment.
     * This function allows pre-calculating the address before deployment.
     * @param _salt The unique salt value used for the contract deployment.
     * @return predictedAddress The predicted escrow address.
     */
    function getPredictedAddress(bytes32 _salt) external view returns (address predictedAddress);

    /**
     * @notice Computes a unique salt used for deterministic deployments (e.g., CREATE2/CREATE3).
     * @dev This salt is used to deterministically deploy or reference an Escrow contract via CREATE2,
     * ensuring uniqueness across both standard and meta-invoice deployments.
     * @param _seller The address of the invoice seller.
     * @param _buyer The address of the invoice buyer.
     * @param _invoiceId A hash representing the invoice content or metadata.
     * @return salt The computed salt for the escrow deployment.
     */
    function computeSalt(address _seller, address _buyer, uint216 _invoiceId) external pure returns (bytes32 salt);

    /**
     * @notice Emitted when a new escrow contract is created.
     * @param invoiceId The unique ID of the invoice associated with the escrow.
     * @param escrow The address of the newly created escrow contract.
     */
    event EscrowCreated(uint216 indexed invoiceId, address indexed escrow);
}
