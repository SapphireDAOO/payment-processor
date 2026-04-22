// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IMultiSig
 * @notice Interface for the multisig transaction system governing privileged payment processor calls.
 */
interface IMultiSig {
    // ================================================================
    //                              ERRORS
    // ================================================================

    /// @notice Thrown when the caller is not a registered signer.
    error NotSigner();

    /// @notice Thrown when the caller is not the multisig contract itself.
    error NotSelf();

    /// @notice Thrown when the referenced transaction hash does not exist.
    error TransactionDoesNotExist();

    /// @notice Thrown when an operation requires PENDING status but the transaction is not pending.
    error TransactionNotPending();

    /// @notice Thrown when execution is attempted but the transaction has not reached APPROVED status.
    error TransactionNotApproved();

    /// @notice Thrown when the signer has already approved this transaction.
    error AlreadyApproved();

    /// @notice Thrown when a signer attempts to approve a transaction they have already approved.
    error AlreadyApprovedByThisSigner();

    /// @notice Thrown when the transaction has already been executed.
    error AlreadyExecuted();

    /// @notice Thrown when the low-level call to the payment processor fails.
    error ExecutionFailed();

    /// @notice Thrown when a provided threshold is zero, exceeds signer count, or is otherwise invalid.
    error InvalidThreshold();

    /// @notice Thrown when the target address is the zero address.
    error InvalidTarget();

    /// @notice Thrown when removing a signer would bring the signer count below the current threshold.
    error SignerCountBelowThreshold();

    /// @notice Thrown when the provided address is already a registered signer.
    error AlreadyASigner();

    /// @notice Thrown when the provided address is not a registered signer.
    error NotASigner();

    /// @notice Thrown when the initial signer array has fewer than two entries.
    error InsufficientSigners();

    // ================================================================
    //                              STRUCTS
    // ================================================================

    /// @notice Represents a proposed administrative transaction awaiting multisig approval.
    /// @param target Payment processor contract to call.
    /// @param value ETH value to forward (0 for admin calls).
    /// @param data ABI-encoded admin function call.
    /// @param nonce Unique identifier preventing replay.
    /// @param status Current lifecycle state: PENDING (1), APPROVED (2), or EXECUTED (3).
    /// @param approvalCount Cumulative approval count per transaction hash.
    struct Transaction {
        address target;
        uint256 value;
        bytes data;
        uint256 nonce;
        uint8 status;
        uint256 approvalCount;
    }

    // ================================================================
    //                              EVENTS
    // ================================================================

    /// @notice Emitted when a new transaction is proposed by a signer.
    /// @param txHash The keccak256 hash identifying this transaction.
    /// @param target The payment processor contract address.
    /// @param value ETH value to forward.
    /// @param data ABI-encoded calldata.
    /// @param nonce Unique proposal nonce.
    /// @param proposer Address of the signer who proposed.
    event TransactionProposed(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 nonce,
        address indexed proposer
    );

    /// @notice Emitted when a signer approves a transaction.
    /// @param txHash The transaction hash that was approved.
    /// @param approver The signer who approved.
    /// @param approvalCount The updated total approval count.
    event TransactionApproved(bytes32 indexed txHash, address indexed approver, uint256 approvalCount);

    /// @notice Emitted when an approved transaction is executed.
    /// @param txHash The transaction hash that was executed.
    /// @param executor The signer who triggered execution.
    event TransactionExecuted(bytes32 indexed txHash, address indexed executor);

    /// @notice Emitted when a new signer is added via a multisig-executed transaction.
    /// @param signer The address added as a signer.
    event SignerAdded(address indexed signer);

    /// @notice Emitted when a signer is removed via a multisig-executed transaction.
    /// @param signer The address removed from the signer set.
    event SignerRemoved(address indexed signer);

    /// @notice Emitted when the approval threshold is updated via a multisig-executed transaction.
    /// @param oldThreshold The previous threshold value.
    /// @param newThreshold The new threshold value.
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    // ================================================================
    //                           FUNCTIONS
    // ================================================================

    /**
     * @notice Proposes a new administrative transaction targeting a payment processor.
     * @param target  Payment processor address (SimplePaymentProcessor or AdvancedPaymentProcessor).
     * @param value   ETH to forward; must be 0 for admin calls.
     * @param data    ABI-encoded payment processor admin function call.
     * @return txHash keccak256 hash of the transaction, used as its identifier.
     */
    function proposeTransaction(address target, uint256 value, bytes calldata data) external returns (bytes32 txHash);

    /**
     * @notice Records the caller's approval for a pending transaction.
     *         Automatically transitions the transaction to APPROVED when the threshold is met.
     * @param txHash Identifier of the transaction to approve.
     */
    function approveTransaction(bytes32 txHash) external;

    /**
     * @notice Executes an APPROVED transaction by forwarding the encoded call to the target.
     * @param txHash Identifier of the approved transaction to execute.
     */
    function executeTransaction(bytes32 txHash) external;

    /**
     * @notice Adds a new signer to the authorized set.
     * @dev Only callable by the multisig contract itself via an executed transaction.
     * @param signer Address to register; must not already be a signer.
     */
    function addSigner(address signer) external;

    /**
     * @notice Removes a signer from the authorized set.
     * @dev Only callable by the multisig contract itself via an executed transaction.
     *      Reverts if removal would leave fewer signers than the current threshold.
     * @param signer Address to deregister; must be a current signer.
     */
    function removeSigner(address signer) external;

    /**
     * @notice Updates the minimum approval threshold.
     * @dev Only callable by the multisig contract itself via an executed transaction.
     * @param newThreshold New required approval count; must be >= 1 and <= signerCount.
     */
    function updateThreshold(uint256 newThreshold) external;

    /**
     * @notice Returns the full Transaction struct for a given hash.
     * @param txHash The transaction identifier.
     * @return The stored Transaction struct.
     */
    function getTransaction(bytes32 txHash) external view returns (Transaction memory);

    /**
     * @notice Returns whether a specific signer has approved a transaction.
     * @param txHash The transaction identifier.
     * @param signer The signer address to check.
     * @return True if the signer has approved.
     */
    function hasApproved(bytes32 txHash, address signer) external view returns (bool);

    /**
     * @notice Returns the current approval count for a transaction.
     * @param txHash The transaction identifier.
     * @return The number of approvals recorded.
     */
    function getApprovalCount(bytes32 txHash) external view returns (uint256);

    /**
     * @notice Returns whether an address is a registered signer.
     * @param account The address to check.
     * @return True if the address is a registered signer.
     */
    function isSigner(address account) external view returns (bool);

    /**
     * @notice Returns the current approval threshold.
     * @return The minimum approvals required for execution.
     */
    function getThreshold() external view returns (uint256);

    /**
     * @notice Returns the total number of registered signers.
     * @return The current signer count.
     */
    function getSignerCount() external view returns (uint256);

    /**
     * @notice Returns the current nonce value, equal to the total number of transactions proposed.
     * @return The latest nonce assigned to a transaction proposal.
     */
    function getNonce() external view returns (uint256);
}
