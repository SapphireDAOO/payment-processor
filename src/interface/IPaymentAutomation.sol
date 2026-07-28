// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IPaymentAutomation
 * @notice Interface for the automation adapter that drives the payment processor's due-task queue.
 * @dev The adapter is stateless with respect to invoices: it holds no queue and no funds. It only
 *      reads `hasDueTasks()` from the processor and calls `processDueTasks()` on it, exposing that
 *      pair through the entrypoints each keeper network expects — `onReport` for Chainlink CRE and
 *      `checker` for Gelato Web3 Functions.
 */
interface IPaymentAutomation {
    // ================================================================
    //                              ERRORS
    // ================================================================

    /// @notice Thrown when the caller lacks the required role or permission.
    error NotAuthorized();

    /// @notice Thrown when the processor or storage address supplied to the constructor is the zero address.
    error InvalidAddress();

    /// @notice Thrown when a CRE report's metadata does not carry the authorized workflow owner.
    /// @param _workflowOwner The workflow owner address decoded from the report metadata.
    error UnauthorizedWorkflowOwner(address _workflowOwner);

    // ================================================================
    //                            FUNCTIONS
    // ================================================================

    /**
     * @notice Drains the processor's due invoice tasks (auto-release and auto-refund).
     * @dev Permissionless: this is the Gelato exec target named by {checker}, and doubles as the
     *      manual fallback when neither keeper network is running. The call is a no-op when nothing
     *      is due, and the processor enforces every state and authorization rule itself, so an
     *      arbitrary caller can only pay for work the keeper would have done anyway.
     */
    function processDueTasks() external;

    /**
     * @notice Gelato Web3 Function resolver: reports whether the processor has work to do.
     * @dev Gelato calls this offchain each polling interval and submits `execPayload` to this
     *      contract when `canExec` is true.
     * @return canExec True when the processor's earliest scheduled task is due.
     * @return execPayload Calldata for {processDueTasks} on this contract.
     */
    function checker() external view returns (bool canExec, bytes memory execPayload);

    /**
     * @notice Returns whether the processor has any scheduled invoice task due for processing.
     * @dev Read by the CRE workflow each cron tick to decide whether to submit a report onchain.
     *      Passes through to the processor so keepers only need this contract's address.
     * @return dueTasksExist True when the processor's earliest scheduled task is due.
     */
    function hasDueTasks() external view returns (bool dueTasksExist);

    /**
     * @notice Updates the address of the CRE (Keystone) forwarder contract that delivers workflow reports.
     * @dev Only callable by the owner or the storage contract. Only the configured forwarder may call `onReport`.
     * @param _forwarderAddress The new forwarder contract address to be set.
     */
    function setForwarderAddress(address _forwarderAddress) external;

    /**
     * @notice Updates the CRE workflow owner authorized to trigger `onReport`.
     * @dev Only callable by the owner or the storage contract. Reports whose metadata carries a
     *      different workflow owner are rejected, so workflows deployed by other owners cannot
     *      trigger task processing through the shared forwarder.
     * @param _workflowOwner The address that owns the authorized CRE workflow.
     */
    function setWorkflowOwner(address _workflowOwner) external;

    /**
     * @notice Returns the address of the configured CRE forwarder contract.
     * @return forwarderAddress The configured forwarder address.
     */
    function getForwarder() external view returns (address forwarderAddress);

    /**
     * @notice Returns the CRE workflow owner authorized to trigger `onReport`.
     * @return workflowOwnerAddress The authorized workflow owner address.
     */
    function getWorkflowOwner() external view returns (address workflowOwnerAddress);

    // ================================================================
    //                              EVENTS
    // ================================================================

    /**
     * @notice Emitted whenever the due-task queue is drained through this adapter.
     * @param caller The address that triggered processing.
     * @param source The keeper path used: `CRE_SOURCE` for `onReport`, `GELATO_SOURCE` for `processDueTasks`.
     */
    event DueTasksProcessed(address indexed caller, bytes32 indexed source);

    /**
     * @notice Emitted when the CRE forwarder address is updated.
     * @param forwarder The new forwarder contract address.
     */
    event ForwarderUpdated(address indexed forwarder);

    /**
     * @notice Emitted when the authorized CRE workflow owner is updated.
     * @param workflowOwner The new authorized workflow owner address.
     */
    event WorkflowOwnerUpdated(address indexed workflowOwner);
}
