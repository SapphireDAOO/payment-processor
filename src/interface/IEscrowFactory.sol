// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IEscrowFactory
 * @notice Interface for contracts responsible for deploying and managing escrow instances.
 * @dev Used to abstract the creation and configuration of escrow contracts.
 */
interface IEscrowFactory {
    /// @notice Parameters required to initialize an escrow contract.
    /// @param seller The address of the seller.
    /// @param buyer The address of the buyer (payer).
    /// @param invoiceId The unique identifier associated with the invoice.
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
     * @notice Predicts the deterministic address of an escrow contract for a given salt.
     * @dev Uses CREATE2 for address prediction, allowing the address to be known before deployment.
     *      The invoice ID is required because it is encoded into the escrow's constructor args,
     *      which feeds into the CREATE2 bytecode hash.
     * @param _salt The unique salt value used for the contract deployment.
     * @param _invoiceId The invoice ID encoded into the escrow's constructor args.
     * @return predictedAddress The predicted escrow address.
     */
    function getPredictedAddress(bytes32 _salt, uint216 _invoiceId) external view returns (address predictedAddress);

    /**
     * @notice Computes a unique salt for deterministic escrow deployment via CREATE2.
     * @dev The salt is derived from the seller, buyer, and invoice ID, ensuring each
     *      escrow has a unique and reproducible address across all invoice types.
     * @param _seller The address of the invoice seller.
     * @param _buyer The address of the invoice buyer.
     * @param _invoiceId The unique nonce of the invoice.
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
