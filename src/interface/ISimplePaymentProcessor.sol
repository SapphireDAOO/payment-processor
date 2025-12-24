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

    /// @notice Thrown when the payment amount sent does not match the expected invoice price.
    /// @param sent The amount of Ether (in wei) sent with the transaction.
    /// @param expected The exact invoice price expected (in wei).
    error IncorrectPaymentAmount(uint256 sent, uint256 expected);

    /// @notice Thrown when the fee value provided is zero.
    error FeeValueCanNotBeZero();

    /// @notice Thrown when a zero address (`address(0)`) is provided.
    error ZeroAddressIsNotAllowed();

    /// @notice Thrown when the invoice price is below the allowed minimum.
    error InvoicePriceIsTooLow();

    /// @notice Thrown when trying to create an invoice that already exists.
    error InvoiceAlreadyExists();

    /// @notice Thrown when the invoice is in an invalid state for the requested action.
    /// @param invoiceState The current state of the invoice, which caused the operation to fail
    error InvalidInvoiceState(uint256 invoiceState);

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
    struct Invoice {
        /// @notice A unique identifier assigned to this invoice, typically sequentially.
        uint216 invoiceId;
        /// @notice The Unix timestamp when the invoice was created.
        uint40 createdAt;
        /// @notice The Unix timestamp when the payment was completed.
        uint40 paidAt;
        /// @notice The timestamp when funds in escrow can be released to the seller.
        uint40 releaseAt;
        /// @notice The timestamp after which the invoice is considered invalid if unpaid.
        uint40 invalidateAt;
        /// @notice The timestamp after which the seller can no longer take action (accept/reject), and the buyer would be refund.
        uint40 expiresAt;
        /// @notice The current am of the invoice.
        uint8 status;
        /// @notice The address of the seller of the invoice.
        address seller;
        /// @notice The address of the buyer of the invoice.
        address buyer;
        /// @notice The address of the escrow contract managing the funds for this invoice.
        address escrow;
        /// @notice The total price of the invoice in wei.
        uint256 price;
        /// @notice The amount that has been paid.
        uint256 amountPaid;
    }

    // ================================================================
    //                            FUNCTIONS
    // ================================================================

    /**
     * @notice Creates a new invoice with a specified price.
     * @dev Optionally stores a reference to the user's off-chain notes file.
     * @param invoicePrice The price of the invoice in wei.
     * @param storageRef A bytes-encoded reference to the user's notes storage.
     * @param share Whether the note is shared with non-authors.
     * @return invoiceId The unique ID of the newly created invoice.
     */
    function createInvoice(uint256 invoicePrice, bytes memory storageRef, bool share) external returns (uint216);

    /**
     * @notice Pays for an existing invoice and optionally updates the user's notes storage reference.
     * @dev The caller must send enough ETH to cover the invoice price.
     * @param orderId The ID of the invoice being paid.
     * @param storageRef A bytes-encoded reference to the caller's notes storage.
     * @param share Whether the note is shared with non-authors.
     * @return escrow The address of the escrow contract created for this payment.
     */
    function pay(uint216 orderId, bytes memory storageRef, bool share) external payable returns (address);

    /**
     * @notice Marks the specified invoice as accepted.
     * @dev This function updates the status of the invoice to `ACCEPTED` and emits the `InvoiceAccepted` event.
     *      It is expected that the creator is approving the payment for the invoice.
     * @param orderId The key of the invoice being accepted.
     */
    function acceptPayment(uint216 orderId) external;

    /**
     * @notice Marks the specified invoice as rejected and refunds the payer.
     * @dev This function updates the invoice status to `REJECTED`, refunds the payer via the escrow contract,
     *      and emits the `InvoiceRejected` event.
     * @param orderId The key of the invoice being rejected.
     * address and payer.
     */
    function rejectPayment(uint216 orderId) external;

    /**
     * @notice Cancels an existing invoice.
     * @dev Only callable by the invoice seller.
     * @param orderId The ID of the invoice to cancel.
     */
    function cancelInvoice(uint216 orderId) external;

    /**
     * @notice Releases the funds held in escrow for a specific invoice to the seller.
     * @param orderId The ID of the invoice for which funds are released.
     */
    function releaseInvoice(uint216 orderId) external;

    /**
     * @notice Sets a custom hold period for a specific invoice.
     * @dev Overrides the default hold period for this invoice.
     * @param orderId The ID of the invoice.
     * @param holdPeriod The new hold period in seconds.
     */
    function setInvoiceReleaseTime(uint216 orderId, uint32 holdPeriod) external;

    /**
     *  @notice Updates the minimum allowed invoice value required for creating an invoice.
     * @dev Should only be callable by the contract owner or an authorized role.
     * @param minimumInvoiceValue The new minimum invoice value to set (in wei).
     */
    function setMinimumInvoiceValue(uint256 minimumInvoiceValue) external;

    /**
     * @notice Updates the address of the forwarder contract used for relayed or automated calls.
     * @param forwarderAddress The new forwarder contract address to be set.
     */
    function setForwarderAddress(address forwarderAddress) external;

    /**
     * @notice Updates the maximum validity duration for newly created invoices.
     * @param newValidPeriod The new validity window in seconds.
     */
    function setValidPeriod(uint256 newValidPeriod) external;

    /**
     * @notice Updates the decision window sellers have to accept payments after buyer payment.
     * @param newDecisionWindow The new decision window in seconds.
     */
    function setDecisionWindow(uint256 newDecisionWindow) external;

    /**
     * @notice Refunds the seller of a specific invoice.
     * @dev This function allows the buyer to be refund if the acceptance window has not been exceeded
     *      and the invoice is eligible for a refund. The refund will be processed through the escrow contract.
     * @param orderId The ID of the invoice to be refunded.
     *
     */
    function refundBuyer(uint216 orderId) external;

    /**
     * @notice Gets the current invoice ID counter.
     * @return The current invoice ID.
     */
    function getNextInvoiceId() external view returns (uint216);

    /**
     * @notice Retrieves detailed data for a specific invoice.
     * @param orderId The ID of the invoice.
     * @return A struct containing the invoice's details.
     */
    function getInvoiceData(uint216 orderId) external view returns (Invoice memory);

    /**
     * @notice Calculates the fee based on the provided amount and current fee rate.
     * @dev Fee rate is expressed in basis points (1% = 100).
     * @param _amount The amount to calculate the fee from.
     * @return The calculated fee amount.
     */
    function calculateFee(uint256 _amount) external view returns (uint256);

    /**
     * @notice Returns the address of the configured forwarder contract.
     * @return The forwarder contract address.
     */
    function getForwarder() external view returns (address);

    /**
     * @notice Returns the minimum allowed invoice value required for invoice creation.
     * @return The minimum invoice value in wei.
     */
    function getMinimumInvoiceValue() external view returns (uint256);

    /**
     * @notice Returns a list of all task IDs currently in the heap.
     * @dev Retrieves the uint216 task identifiers extracted from the internal encoded heap structure.
     * @return An array of task IDs (uint256) currently stored in the heap.
     */
    function getItems() external view returns (uint216[] memory);

    // ================================================================
    //                              EVENTS
    // ================================================================

    /**
     * @notice Emitted when a new invoice is created.
     * @param orderId The unique identifier (hash) for the created invoice.
     * @param invalidateAt The expiration timestamp beyond which the invoice is no longer valid.
     * @param invoice The full invoice struct containing buyer, price, timestamps, state, and metadata.
     */
    event InvoiceCreated(uint216 indexed orderId, uint40 indexed invalidateAt, Invoice invoice);

    /**
     * @notice Emitted when an invoice payment is made.
     * @param orderId The unique key of the accepted invoice.
     * @param amountPaid The amount paid towards the invoice in wei.
     *  @param expiresAt The timestamp by which the seller must accept or reject the invoice.
     *          If no action is taken by then, the buyer would be refund.
     */
    event InvoicePaid(uint216 indexed orderId, address indexed buyer, uint256 indexed amountPaid, uint40 expiresAt);

    /**
     * @notice Emitted when an invoice is rejected by the seller.
     * @param orderId The unique key of the rejected invoice.
     */
    event InvoiceRejected(uint216 indexed orderId);

    /**
     * @notice Emitted when an invoice is refunded to the buyer.
     * @param orderId The unique key of the rejected invoice.
     */
    event InvoiceRefunded(uint216 indexed orderId);

    /**
     * @notice Emitted when an invoice is accepted by the seller.
     * @param orderId The unique key of the accepted invoice.
     */
    event InvoiceAccepted(uint216 indexed orderId);

    /**
     * @notice Emitted when an invoice is canceled.
     * @param orderId The unique key of the canceled invoice.
     */
    event InvoiceCanceled(uint216 indexed orderId);

    /**
     * @notice Emitted when an invoice is released (funds disbursed from escrow).
     * @param orderId The unique key of the released invoice.
     */
    event InvoiceReleased(uint216 indexed orderId);

    /**
     * @notice Emitted when the hold period of a given invoice is updated to a new timestamp.
     * @param orderId The key of the invoice whose hold period was updated.
     * @param releaseDueTimestamp The new hold period expressed as a UNIX timestamp.
     */
    event UpdateHoldPeriod(uint216 indexed orderId, uint256 indexed releaseDueTimestamp);
}
