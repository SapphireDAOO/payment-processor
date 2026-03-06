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

    /// @notice Thrown when the provided fee rate exceeds the maximum allowed (100% = 10,000 basis points).
    error FeeTooHigh();

    /// @notice Thrown when the caller lacks the required role or permission.
    error NotAuthorized();

    /// @notice Thrown when the provided value is lower than the required minimum.
    error ValueIsTooLow();

    /// @notice Thrown when a fund transfer fails.
    error TransferFailed();

    /// @notice Thrown when an action is attempted on an invoice that has not been paid.
    error InvoiceNotPaid();

    /// @notice Thrown when a task’s heap index is invalid.
    error InvalidHeapPosition();

    /// @notice Thrown when the decision window value provided is invalid (e.g., zero).
    error InvalidDecisionWindow();

    /// @notice Thrown when the payment amount sent does not match the expected invoice price.
    /// @param _sent The amount of Ether (in wei) sent with the transaction.
    /// @param _expected The exact invoice price expected (in wei).
    error IncorrectPaymentAmount(uint256 _sent, uint256 _expected);

    /// @notice Thrown when the fee value provided is zero.
    error FeeValueCanNotBeZero();

    /// @notice Thrown when a zero address (`address(0)`) is provided.
    error ZeroAddressIsNotAllowed();

    /// @notice Thrown when the invoice price is below the allowed minimum.
    error InvoicePriceIsTooLow();

    /// @notice Thrown when trying to create an invoice that already exists.
    error InvoiceAlreadyExists();

    /// @notice Thrown when the invoice is in an invalid state for the requested action.
    /// @param _invoiceState The current state of the invoice, which caused the operation to fail
    error InvalidInvoiceState(uint256 _invoiceState);

    /// @notice Thrown when the invoice is no longer valid (e.g., cancelled or expired).
    error InvoiceIsNoLongerValid();

    /// @notice Thrown when an invoice that has already been fully paid is attempted to be paid again.
    error InvoiceAlreadyPaid();

    /// @notice Thrown when an invoice has not been accepted
    error InvoiceHasNotBeenAccepted();

    /// @notice Thrown when the seller attempts to take action on an invoice after the acceptance window has expired.
    error AcceptanceWindowExceeded();

    /// @notice Thrown when the calculated release time exceeds the maximum value allowed for a uint32.
    error ReleaseTimeOverflow();

    /// @notice Thrown when the seller of an invoice attempts to pay for their own invoice.
    error SellerCannotPayOwnedInvoice();

    /// @notice Reverts when an invoice is not eligible for a refund to the seller.
    error InvoiceNotEligibleForRefund();

    /// @notice Thrown when the hold period for an invoice has not yet been exceeded.
    error HoldPeriodHasNotBeenExceeded();

    /// @notice Thrown when attempting to set a custom hold period that is less than the default hold period.
    error HoldPeriodShouldBeGreaterThanPrevious();

    /// @notice Error thrown when attempting to release an invoice that has already been released.
    error InvoiceHasAlreadyBeenReleased();

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
    /// @param status The current status of the invoice.
    /// @param seller The address of the seller of the invoice.
    /// @param buyer The address of the buyer of the invoice.
    /// @param escrow The address of the escrow contract managing the funds for this invoice.
    /// @param price The total price of the invoice in wei.
    /// @param balance The amount that has been paid.
    struct Invoice {
        uint216 invoiceNonce;
        uint40 createdAt;
        uint40 paidAt;
        uint40 releaseAt;
        uint40 invalidateAt;
        uint40 expiresAt;
        uint8 status;
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
     * @param _invoicePrice The price of the invoice in wei.
     * @param _storageRef A bytes-encoded reference to the user's notes storage.
     * @param _share Whether the note is shared with non-authors.
     * @return invoiceId The unique ID of the newly created invoice.
     */
    function createInvoice(uint256 _invoicePrice, bytes memory _storageRef, bool _share)
        external
        returns (uint216 invoiceId);

    /**
     * @notice Pays for an existing invoice and optionally updates the user's notes storage reference.
     * @dev The caller must send enough ETH to cover the invoice price.
     * @param _invoiceId The ID of the invoice being paid.
     * @param _storageRef A bytes-encoded reference to the caller's notes storage.
     * @param _share Whether the note is shared with non-authors.
     * @return escrow The address of the escrow contract created for this payment.
     */
    function pay(uint216 _invoiceId, bytes memory _storageRef, bool _share) external payable returns (address escrow);

    /**
     * @notice Marks the specified invoice as accepted.
     * @dev This function updates the status of the invoice to `ACCEPTED` and emits the `InvoiceAccepted` event.
     * It is expected that the creator is approving the payment for the invoice.
     * @param _invoiceId The key of the invoice being accepted.
     */
    function acceptPayment(uint216 _invoiceId) external;

    /**
     * @notice Marks the specified invoice as rejected and refunds the payer.
     * @dev This function updates the invoice status to `REJECTED`, refunds the payer via the escrow contract,
     * and emits the `InvoiceRejected` event.
     * @param _invoiceId The key of the invoice being rejected.
     */
    function rejectPayment(uint216 _invoiceId) external;

    /**
     * @notice Cancels an existing invoice.
     * @dev Only callable by the invoice seller.
     * @param _invoiceId The ID of the invoice to cancel.
     */
    function cancelInvoice(uint216 _invoiceId) external;

    /**
     * @notice Releases the funds held in escrow for a specific invoice to the seller.
     * @param _invoiceId The ID of the invoice for which funds are released.
     */
    function release(uint216 _invoiceId) external;

    /**
     * @notice Sets a custom hold period for a specific invoice.
     * @dev Overrides the default hold period for this invoice.
     * @param _invoiceId The ID of the invoice.
     * @param _holdPeriod The new hold period in seconds.
     */
    function setInvoiceReleaseTime(uint216 _invoiceId, uint32 _holdPeriod) external;

    /**
     * @notice Updates the minimum allowed invoice value required for creating an invoice.
     * @dev Should only be callable by the contract owner or an authorized role.
     * @param _minimumInvoiceValue The new minimum invoice value to set (in wei).
     */
    function setMinimumInvoiceValue(uint256 _minimumInvoiceValue) external;

    /**
     * @notice Updates the address of the forwarder contract used for relayed or automated calls.
     * @param _forwarderAddress The new forwarder contract address to be set.
     */
    function setForwarderAddress(address _forwarderAddress) external;

    /**
     * @notice Updates the decision window sellers have to accept payments after buyer payment.
     * @param _newDecisionWindow The new decision window in seconds.
     */
    function setDecisionWindow(uint256 _newDecisionWindow) external;

    /**
     * @notice Refunds the buyer of a specific invoice.
     * @dev This function allows the buyer to be refund if the acceptance window has not been exceeded
     * and the invoice is eligible for a refund. The refund will be processed through the escrow contract.
     * @param _invoiceId The ID of the invoice to be refunded.
     */
    function refundBuyer(uint216 _invoiceId) external;

    /**
     * @notice Gets the current invoice nonce counter.
     * @return nextInvoiceNonceValue The next invoice nonce value.
     */
    function getNextInvoiceNonce() external view returns (uint216 nextInvoiceNonceValue);

    /**
     * @notice Retrieves detailed data for a specific invoice.
     * @param _invoiceId The ID of the invoice.
     * @return invoiceDetails The invoice data.
     */
    function getInvoiceData(uint216 _invoiceId) external view returns (Invoice memory invoiceDetails);

    /**
     * @notice Calculates the fee based on the provided amount and current fee rate.
     * @dev Fee rate is expressed in basis points (1% = 100).
     * @param _amount The amount to calculate the fee from.
     * @return feeValue The calculated fee amount.
     */
    function calculateFee(uint256 _amount) external view returns (uint256 feeValue);

    /**
     * @notice Returns the address of the configured forwarder contract.
     * @return forwarderAddress The configured forwarder address.
     */
    function getForwarder() external view returns (address forwarderAddress);

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
     * @param invoiceId The unique identifier (hash) for the created invoice.
     * @param invalidateAt The expiration timestamp beyond which the invoice is no longer valid.
     * @param invoice The full invoice struct containing buyer, price, timestamps, state, and metadata.
     */
    event InvoiceCreated(uint216 indexed invoiceId, uint40 indexed invalidateAt, Invoice invoice);

    /**
     * @notice Emitted when an invoice payment is made.
     * @param invoiceId The unique key of the accepted invoice.
     * @param amountPaid The amount paid towards the invoice in wei.
     *  @param expiresAt The timestamp by which the seller must accept or reject the invoice.
     *          If no action is taken by then, the buyer would be refund.
     */
    event InvoicePaid(uint216 indexed invoiceId, address indexed buyer, uint256 indexed amountPaid, uint40 expiresAt);

    /**
     * @notice Emitted when an invoice is rejected by the seller.
     * @param invoiceId The unique key of the rejected invoice.
     */
    event InvoiceRejected(uint216 indexed invoiceId);

    /**
     * @notice Emitted when an invoice is refunded to the buyer.
     * @param invoiceId The unique key of the rejected invoice.
     */
    event InvoiceRefunded(uint216 indexed invoiceId);

    /**
     * @notice Emitted when an invoice is accepted by the seller.
     * @param invoiceId The unique key of the accepted invoice.
     */
    event InvoiceAccepted(uint216 indexed invoiceId);

    /**
     * @notice Emitted when an invoice is canceled.
     * @param invoiceId The unique key of the canceled invoice.
     */
    event InvoiceCanceled(uint216 indexed invoiceId);

    /**
     * @notice Emitted when an invoice is released (funds disbursed from escrow).
     * @param invoiceId The unique key of the released invoice.
     */
    event InvoiceReleased(uint216 indexed invoiceId);

    /**
     * @notice Emitted when the hold period of a given invoice is updated to a new timestamp.
     * @param invoiceId The key of the invoice whose hold period was updated.
     * @param releaseDueTimestamp The new hold period expressed as a UNIX timestamp.
     */
    event UpdateHoldPeriod(uint216 indexed invoiceId, uint256 indexed releaseDueTimestamp);
}
