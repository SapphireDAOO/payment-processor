// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

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

    /// @notice Thrown when a transaction is not PROPOSED or APPROVED (already executed or canceled).
    error TransactionNotProposedOrApproved();

    /// @notice Thrown when execution is attempted with fewer than `threshold` valid approvers.
    error TransactionNotApproved();

    /// @notice Thrown when a signer attempts to approve a transaction they have already approved.
    error AlreadyApprovedByThisSigner();

    error ThresholdCannotBeZero();

    /// @notice Thrown when a threshold is below a majority of signers, or above the signer count at construction.
    error InvalidThreshold();

    /// @notice Thrown when the target address is the zero address.
    error InvalidTarget();

    /// @notice Thrown when a new threshold exceeds the signer count.
    error SignerCountBelowThreshold();

    /// @notice Thrown when the provided address is already a registered signer.
    error AlreadyASigner();

    /// @notice Thrown when the provided address is not a registered signer.
    error NotASigner();

    /// @notice Thrown when the signer set would have fewer than `MINIMUM_SIGNERS` signers.
    error InsufficientSigners();

    /// @notice Thrown when a signer is the zero address.
    error InvalidSigner();

    /// @notice Thrown when execution approvers are not in strictly ascending order.
    error ApproversNotSorted();

    /// @notice Thrown when an execution approver is no longer a signer or never approved the transaction.
    error InvalidApprover(address approver);

    // ================================================================
    //                              STRUCTS
    // ================================================================

    /// @notice Represents a proposed administrative transaction awaiting multisig approval.
    /// @param target Contract to call.
    /// @param data ABI-encoded admin function call.
    /// @param nonce Unique identifier preventing replay.
    /// @param status Current lifecycle state: PROPOSED (1), APPROVED (2), EXECUTED (3), or CANCELED (4).
    /// @param approvalCount Cumulative approval count; informational, execution re-checks approvers.
    struct Transaction {
        address target;
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
    /// @param target The contract to call.
    /// @param data ABI-encoded calldata.
    /// @param nonce Unique proposal nonce.
    /// @param proposer Address of the signer who proposed.
    event TransactionProposed(
        bytes32 indexed txHash, address indexed target, bytes data, uint256 nonce, address indexed proposer
    );

    /// @notice Emitted when a signer records their approval for a transaction.
    /// @param txHash The transaction hash that was approved.
    /// @param approver The signer who approved.
    /// @param approvalCount The updated total approval count.
    event ApprovalAdded(bytes32 indexed txHash, address indexed approver, uint256 approvalCount);

    /// @notice Emitted when a transaction accumulates enough approvals to reach APPROVED status.
    /// @param txHash The transaction hash that reached the approval threshold.
    event TransactionApproved(bytes32 indexed txHash);

    /// @notice Emitted when an approved transaction is executed.
    /// @param txHash The transaction hash that was executed.
    /// @param executor The signer who triggered execution.
    event TransactionExecuted(bytes32 indexed txHash, address indexed executor);

    /// @notice Emitted when a PROPOSED or APPROVED transaction is canceled via a multisig-executed transaction.
    /// @param txHash The transaction hash that was canceled.
    event TransactionCanceled(bytes32 indexed txHash);

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
     * @notice Proposes a new administrative transaction and records the proposer's approval.
     * @param target  Contract to call, e.g. PaymentProcessorStorage, OracleManager, or this MultiSig.
     * @param data    ABI-encoded payment processor admin function call.
     * @return txHash keccak256 hash of the transaction, used as its identifier.
     */
    function proposeTransaction(address target, bytes calldata data) external returns (bytes32 txHash);

    /**
     * @notice Records the caller's approval for a PROPOSED or APPROVED transaction.
     *         Transitions a PROPOSED transaction to APPROVED when the approval count meets the threshold.
     * @param txHash Identifier of the transaction to approve.
     */
    function approveTransaction(bytes32 txHash) external;

    /**
     * @notice Executes a PROPOSED or APPROVED transaction by forwarding the encoded call to the target.
     * @dev Only approvals from current signers count, so a removed signer's approvals no longer apply.
     * @param txHash Identifier of the transaction to execute.
     * @param approvers At least `threshold` current signers who approved `txHash`, sorted ascending.
     * @return The raw bytes returned by the target call.
     */
    function executeTransaction(bytes32 txHash, address[] calldata approvers) external returns (bytes memory);

    /**
     * @notice Cancels a PROPOSED or APPROVED transaction, preventing execution.
     * @dev Only callable by the multisig contract itself via an executed transaction.
     *      Reverts if the transaction does not exist or is already EXECUTED or CANCELED.
     * @param txHash Identifier of the transaction to cancel.
     */
    function cancelTransaction(bytes32 txHash) external;

    /**
     * @notice Adds a new signer to the authorized set.
     * @dev Only callable by the multisig contract itself via an executed transaction. Resets the
     *      threshold to a majority of the new signer set.
     * @param signer Address to register; must be non-zero and not already a signer.
     */
    function addSigner(address signer) external;

    /**
     * @notice Removes a signer from the authorized set.
     * @dev Only callable by the multisig contract itself via an executed transaction.
     *      Reverts if removal would leave fewer than `MINIMUM_SIGNERS` signers. Resets the threshold to
     *      a majority of the new signer set; the removed signer's approvals stop counting.
     * @param signer Address to deregister; must be a current signer.
     */
    function removeSigner(address signer) external;

    /**
     * @notice Updates the minimum approval threshold.
     * @dev Only callable by the multisig contract itself via an executed transaction.
     * @param newThreshold New required approval count; at least a majority of signers and at most signerCount.
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
