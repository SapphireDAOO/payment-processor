// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title Payment processor interface
 * @notice This interface provides functionality for creating and managing invoices.
 */
interface ISimplePaymentProcessor {
    // ================================================================
    //                              ERRORS
    // ================================================================

    /// @notice Thrown when the caller lacks the required role or permission.
    error NotAuthorized();

    /// @notice Thrown when the provided value is lower than the required minimum.
    error ValueIsTooLow();

    /// @notice Thrown when a task’s heap index is invalid.
    error InvalidHeapPosition();

    /// @notice Thrown when the decision window value provided is invalid (e.g., zero).
    error InvalidDecisionWindow();

    /// @notice Thrown when the payment amount sent does not match the expected invoice price.
    /// @param _sent The amount of Ether (in wei) sent with the transaction.
    /// @param _expected The exact invoice price expected (in wei).
    error IncorrectPaymentAmount(uint256 _sent, uint256 _expected);

    /// @notice Thrown when trying to create an invoice that already exists.
    error InvoiceAlreadyExists();

    /// @notice Thrown when the invoice is in an invalid state for the requested action.
    /// @param _invoiceState The current state of the invoice, which caused the operation to fail
    error InvalidInvoiceState(uint256 _invoiceState);

    /// @notice Thrown when a payment is attempted after the invoice's payment validity window has expired.
    error InvoiceIsNoLongerValid();

    /// @notice Thrown when the seller attempts to take action on an invoice after the acceptance window has expired.
    error AcceptanceWindowExceeded();

    /// @notice Thrown when the seller of an invoice attempts to pay for their own invoice.
    error SellerCannotPayOwnedInvoice();

    /// @notice Thrown when a refund to the buyer cannot be issued (invoice not PAID or decision window not yet elapsed).
    error InvoiceNotEligibleForRefund();

    /// @notice Thrown when the hold period for an invoice has not yet been exceeded.
    error HoldPeriodHasNotBeenExceeded();

    /// @notice Thrown when the escrow withdrawal fails during a manual release, reject, or refund.
    error EscrowWithdrawFailed();

    /// @notice Thrown when a CRE report's metadata does not carry the authorized workflow owner.
    /// @param _workflowOwner The workflow owner address decoded from the report metadata.
    error UnauthorizedWorkflowOwner(address _workflowOwner);

    // ================================================================
    //                              STRUCTS
    // ================================================================

    /// @notice Represents an invoice between a buyer and seller, with escrow, timestamps, and status tracking.
    /// @param invoiceNonce A unique identifier assigned to this invoice, typically sequentially.
    /// @param createdAt The Unix timestamp when the invoice was created.
    /// @param paidAt The Unix timestamp when the payment was completed.
    /// @param releaseAt The timestamp when funds in escrow can be released to the seller.
    /// @param invalidateAt The timestamp after which the invoice is considered invalid if unpaid.
    /// @param expiresAt The timestamp after which the seller can no longer take action (accept/reject), and the buyer is refunded.
    /// @param state The current state of the invoice.
    /// @param withdrawalRetries Number of failed `IEscrow.withdraw` attempts by the automation path. Resets are not needed
    ///        because an invoice follows only one terminal path. Packed with `state` in the same slot.
    /// @param feeRate The platform fee rate (in basis points) captured at invoice creation. Releases always
    ///        charge this rate, so later changes to the global fee rate do not affect existing invoices.
    /// @param seller The address of the seller of the invoice.
    /// @param buyer The address of the buyer of the invoice.
    /// @param escrow The address of the escrow contract managing the funds for this invoice.
    /// @param price The total price of the invoice in wei.
    /// @param balance The current amount held in escrow, net of any fees deducted upon acceptance. Zeroed on release or refund.
    struct Invoice {
        uint216 invoiceNonce;
        uint40 createdAt;
        uint40 paidAt;
        uint40 releaseAt;
        uint40 invalidateAt;
        uint40 expiresAt;
        uint8 state;
        uint8 withdrawalRetries;
        uint16 feeRate;
        address seller;
        address buyer;
        address escrow;
        uint256 price;
        uint256 balance;
    }

    // ================================================================
    //                            FUNCTIONS
    // ================================================================

    /**
     * @notice Creates a new invoice with a specified price.
     * @dev Optionally stores a reference to the user's off-chain notes file.
     * @param _price The price of the invoice in wei.
     * @param _storageRef A bytes-encoded reference to the user's notes storage.
     * @param _share Whether the note is shared with the other party.
     * @return invoiceId The unique ID of the newly created invoice.
     */
    function createInvoice(uint256 _price, bytes memory _storageRef, bool _share) external returns (uint216 invoiceId);

    /**
     * @notice Pays for an existing invoice and optionally updates the user's notes storage reference.
     * @dev The caller must send enough ETH to cover the invoice price. The invoice is inserted
     *      into the auto-release heap with priority `expiresAt`, enabling automated refunds if
     *      the seller does not act within the decision window.
     * @param _invoiceId The ID of the invoice being paid.
     * @param _storageRef A bytes-encoded reference to the caller's notes storage.
     * @param _share Whether the note is shared with the other party.
     * @return escrow The address of the escrow contract created for this payment.
     */
    function pay(uint216 _invoiceId, bytes memory _storageRef, bool _share) external payable returns (address escrow);

    /**
     * @notice Marks the specified invoice as accepted by the seller.
     * @dev Only callable by the seller within the decision window. Transitions the invoice to
     *      ACCEPTED, deducts the platform fee from escrow immediately, and sets the `releaseAt`
     *      timestamp based on the default hold period. The invoice's heap entry is rescheduled
     *      from `expiresAt` to `releaseAt` for automated fund release after the hold period.
     * @param _invoiceId The identifier of the invoice being accepted.
     */
    function acceptPayment(uint216 _invoiceId) external;

    /**
     * @notice Marks the specified invoice as rejected and refunds the payer.
     * @dev Only callable by the seller within the decision window. Transitions the invoice to
     *      REJECTED, removes it from the heap, refunds the buyer via the escrow contract,
     *      and emits the `InvoiceRejected` event.
     * @param _invoiceId The identifier of the invoice being rejected.
     */
    function rejectPayment(uint216 _invoiceId) external;

    /**
     * @notice Cancels an existing invoice.
     * @dev Only callable by the invoice seller. Invoice must be in CREATED state (i.e., not yet
     *      paid). Transitions the invoice to CANCELLED. No heap interaction occurs since unpaid
     *      invoices are never inserted into the heap.
     * @param _invoiceId The ID of the invoice to cancel.
     */
    function cancelInvoice(uint216 _invoiceId) external;

    /**
     * @notice Releases the funds held in escrow for a specific invoice to the seller.
     * @dev Only callable by the seller. Invoice must be in ACCEPTED state and `releaseAt`
     *      must have passed. Transitions the invoice to RELEASED, removes it from the heap,
     *      and zeroes the balance.
     * @param _invoiceId The ID of the invoice for which funds are released.
     */
    function release(uint216 _invoiceId) external;

    /**
     * @notice Refunds the buyer of a specific invoice when the seller fails to act in time.
     * @dev Invoice must be in PAID state and the decision window (`expiresAt`) must have elapsed.
     *      Transitions the invoice to REFUNDED, removes it from the heap, zeroes the balance,
     *      and returns funds to the buyer.
     * @param _invoiceId The ID of the invoice to be refunded.
     */
    function refundBuyer(uint216 _invoiceId) external;

    /**
     * @notice Sets a custom release time for a specific invoice.
     * @dev Only callable by the owner. Invoice must be in ACCEPTED state. The new release
     *      time is computed as `block.timestamp + _holdPeriod`. The invoice's heap entry is
     *      rescheduled to the new release time.
     * @param _invoiceId The ID of the invoice.
     * @param _holdPeriod The hold period from now in seconds.
     */
    function setInvoiceReleaseTime(uint216 _invoiceId, uint40 _holdPeriod) external;

    /**
     * @notice Updates the minimum allowed invoice value required for creating an invoice.
     * @dev Only callable by the owner or the storage contract.
     * @param _minimumInvoiceValue The new minimum invoice value to set (in wei).
     */
    function setMinimumInvoiceValue(uint256 _minimumInvoiceValue) external;

    /**
     * @notice Updates the address of the CRE (Keystone) forwarder contract that delivers workflow reports.
     * @dev Only the configured forwarder may call `onReport`.
     * @param _forwarderAddress The new forwarder contract address to be set.
     */
    function setForwarderAddress(address _forwarderAddress) external;

    /**
     * @notice Updates the CRE workflow owner authorized to trigger `onReport`.
     * @dev Reports whose metadata carries a different workflow owner are rejected, so workflows
     *      deployed by other owners cannot trigger task processing through the shared forwarder.
     * @param _workflowOwner The address that owns the authorized CRE workflow.
     */
    function setWorkflowOwner(address _workflowOwner) external;

    /**
     * @notice Processes due invoice tasks (auto-release and auto-refund) within the gas threshold.
     * @dev Owner-only manual fallback for the CRE workflow path (`onReport`).
     */
    function processDueTasks() external;

    /**
     * @notice Returns whether any scheduled invoice task is due for processing.
     * @dev Read by the CRE workflow each cron tick to decide whether to submit a report onchain.
     * @return dueTasksExist True when the earliest scheduled task is due.
     */
    function hasDueTasks() external view returns (bool dueTasksExist);

    /**
     * @notice Updates the decision window sellers have to accept/reject payments after buyer payment.
     * @param _newDecisionWindow The new decision window in seconds.
     */
    function setDecisionWindow(uint256 _newDecisionWindow) external;

    /**
     * @notice Recovers funds from a LOCKED invoice by withdrawing from its escrow to a specified recipient.
     * @dev Only callable by the owner or storage contract. The invoice must be in LOCKED state —
     *      meaning all automated withdrawal retries have been exhausted. Transitions the invoice to
     *      RELEASED to prevent double-recovery. The caller is responsible for supplying the correct
     *      `_amount`; use `getInvoiceData` to determine how much remains in escrow. In both PAID-locked
     *      and ACCEPTED-locked cases the full `price` is in escrow, as the fee is only collected at
     *      the point of successful release.
     * @param _invoiceId The ID of the locked invoice.
     * @param _recipient The address to send the recovered funds to.
     * @param _amount The amount to withdraw from escrow.
     */
    function releaseLocked(uint216 _invoiceId, address _recipient, uint256 _amount) external;

    /**
     * @notice Returns the nonce that will be assigned to the next invoice.
     * @return nextInvoiceNonceValue The next invoice nonce value.
     */
    function getNextInvoiceNonce() external view returns (uint216 nextInvoiceNonceValue);

    /**
     * @notice Retrieves detailed data for a specific invoice.
     * @param _invoiceId The ID of the invoice.
     * @return i The invoice data.
     */
    function getInvoiceData(uint216 _invoiceId) external view returns (Invoice memory i);

    /**
     * @notice Calculates the fee based on the provided amount and the current global fee rate.
     * @dev Fee rate is expressed in basis points (1% = 100). This quotes the rate that would be
     *      captured by an invoice created now; releases use the rate snapshotted on the invoice
     *      at creation, not the current global rate.
     * @param _amount The amount to calculate the fee from.
     * @return feeValue The calculated fee amount.
     */
    function calculateFee(uint256 _amount) external view returns (uint256 feeValue);

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

    /**
     * @notice Returns the minimum allowed invoice value required for invoice creation.
     * @return minimumValue The minimum allowed invoice value.
     */
    function getMinimumInvoiceValue() external view returns (uint256 minimumValue);

    /**
     * @notice Returns a list of all task IDs currently in the heap.
     * @dev Retrieves the uint216 task identifiers extracted from the internal encoded heap structure.
     * @return items Array of task IDs.
     */
    function getItems() external view returns (uint216[] memory items);

    // ================================================================
    //                              EVENTS
    // ================================================================

    /**
     * @notice Emitted when a new invoice is created.
     * @param invoiceId The unique identifier for the created invoice.
     * @param invoice The full invoice struct containing buyer, price, timestamps, state, and metadata.
     */
    event InvoiceCreated(uint216 indexed invoiceId, Invoice invoice);

    /**
     * @notice Emitted when an invoice payment is made.
     * @param invoiceId The unique ID of the paid invoice.
     * @param buyer The address that paid the invoice.
     * @param amountPaid The amount paid towards the invoice in wei.
     * @param expiresAt The timestamp by which the seller must accept or reject the invoice.
     *          If no action is taken by then, the buyer will be refunded.
     */
    event InvoicePaid(uint216 indexed invoiceId, address indexed buyer, uint256 indexed amountPaid, uint40 expiresAt);

    /**
     * @notice Emitted when an invoice is rejected by the seller.
     * @param invoiceId The unique ID of the rejected invoice.
     * @param amount The escrow balance refunded to the buyer in wei.
     */
    event InvoiceRejected(uint216 indexed invoiceId, uint256 amount);

    /**
     * @notice Emitted when an invoice is refunded to the buyer.
     * @param invoiceId The unique ID of the refunded invoice.
     * @param amount The escrow balance refunded to the buyer in wei.
     */
    event InvoiceRefunded(uint216 indexed invoiceId, uint256 amount);

    /**
     * @notice Emitted when an invoice is accepted by the seller.
     * @param invoiceId The unique ID of the accepted invoice.
     */
    event InvoiceAccepted(uint216 indexed invoiceId);

    /**
     * @notice Emitted when an invoice is canceled.
     * @param invoiceId The unique ID of the canceled invoice.
     */
    event InvoiceCanceled(uint216 indexed invoiceId);

    /**
     * @notice Emitted when an invoice is released (funds disbursed from escrow).
     * @param invoiceId The unique ID of the released invoice.
     * @param sellerAmount The net amount transferred to the seller, after fees.
     * @param fee The platform fee deducted and sent to the fee receiver.
     */
    event InvoiceReleased(uint216 indexed invoiceId, uint256 sellerAmount, uint256 fee);

    /**
     * @notice Emitted when the hold period of a given invoice is updated to a new timestamp.
     * @param invoiceId The key of the invoice whose hold period was updated.
     * @param releaseDueTimestamp The new hold period expressed as a UNIX timestamp.
     */
    event UpdateHoldPeriod(uint216 indexed invoiceId, uint256 indexed releaseDueTimestamp);

    /**
     * @notice Emitted when an ETH transfer to a recipient fails during reject, refund, or release.
     * @dev The invoice state and heap entry are already updated before this event; funds remain
     *      in the escrow contract and can be recovered by the owner via `releaseLocked`.
     * @param invoiceId The invoice whose transfer failed.
     * @param recipient The intended ETH recipient (buyer or seller).
     * @param amount The amount of ETH that could not be delivered.
     */
    event TransferFailed(uint216 indexed invoiceId, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when an admin recovers funds from a LOCKED invoice.
     * @param invoiceId The invoice from which funds were recovered.
     * @param recipient The address that received the recovered funds.
     * @param amount The amount of ETH recovered from escrow.
     */
    event LockedPaymentRecovered(uint216 indexed invoiceId, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when an automated withdrawal fails and the invoice is rescheduled for a retry.
     * @dev The invoice remains in its current state and the heap entry is rescheduled by RETRY_DELAY.
     *      After MAX_WITHDRAWAL_RETRIES attempts, the processor falls back to a buyer refund instead.
     * @param invoiceId The invoice being retried.
     * @param recipient The intended recipient (seller for ACCEPTED, buyer for PAID).
     * @param amount The amount that could not be delivered.
     * @param attempt The retry attempt number (1 through MAX_WITHDRAWAL_RETRIES).
     */
    event WithdrawalRetried(uint216 indexed invoiceId, address indexed recipient, uint256 amount, uint8 attempt);
}
