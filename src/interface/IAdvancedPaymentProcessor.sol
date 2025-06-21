// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAdvancedPaymentProcessor {
    // ================================================================
    //                              ERRORS
    // ================================================================

    /// @notice Thrown when the caller is not the expected buyer.
    error InvalidBuyer();

    /// @notice Thrown when the caller lacks the required role or permission.
    error NotAuthorized();

    /// @notice Thrown when attempting to interact with an expired invoice.
    error InvoiceExpired();

    /// @notice Thrown when trying to create an invoice that already exists.
    error InvoiceAlreadyExists();

    /// @notice Thrown when an invoice has already been refunded.
    error AlreadyRefunded();

    /// @notice Thrown when the caller is not the invoice's buyer.
    error UnauthorizedBuyer();

    /// @notice Thrown when the caller is not the invoice's seller.
    error UnauthorizedSeller();

    /// @notice Thrown when the invoice is still active and certain actions are not allowed.
    error InvoiceStillActive();

    /// @notice Reverts if the buyer and seller are the same address.
    error BuyerCannotBeSeller();

    /// @notice Thrown when the invoice is in a state that does not allow the attempted action.
    error InvalidInvoiceState();

    /// @notice Thrown when an unsupported or disallowed token is used for payment.
    error InvalidPaymentToken();

    /// @notice Thrown when the invoice does not exist.
    error InvoiceDoesNotExist();

    /// @notice Thrown when an invalid amount of native currency is sent with a payment.
    error InvalidNativePayment();

    /// @notice Thrown when the dispute window has already passed.
    error DisputeWindowExpired();

    /// @notice Thrown when a dispute resolution type is invalid.
    error InvalidDisputeResolution();

    /// @notice Reverts if the caller is not the buyer or seller of the invoice.
    error UnauthorizedParticipant();

    /// @notice Reverts if the same participant attempts to initiate resolution more than once.
    error DuplicateResolutionAttempt();

    /// @notice Thrown when the seller's payout share exceeds the allowed limit (10000 BPS).
    error InvalidSellersPayoutShare();

    /// @notice Thrown when the meta-invoice payment does not match expected parameters.
    error InvalidMetaInvoicePayment();

    /// @notice Thrown when the seller fails to respond to an invoice before the deadline.
    error InvoiceResponseTimeExpired();

    /// @notice Thrown when the buyer attempts to cancel the invoice after the deadline.
    error CancelationRequestDeadlinePassed();

    // ================================================================
    //                              STRUCTS
    // ================================================================

    struct Invoice {
        /// @notice A unique identifier assigned to this invoice, typically sequentially.
        uint256 invoiceId;
        /// @notice Address of the buyer.
        address buyer;
        /// @notice Address of the seller.
        address seller;
        /// @notice Address of the escrow contract holding the funds.
        address escrow;
        /// @notice Token used for payment. Address zero for native currency.
        address paymentToken;
        /// @notice Stores the address of the first party (buyer or seller) that initiated the resolution process
        address resolutionInitiator;
        /// @notice Current state of the invoice.
        uint8 state;
        /// @notice Tracks the number of parties (buyer and seller) who have confirmed resolution.
        uint8 resolutionState;
        /// @notice Timestamp when the payment was made.
        uint48 paidAt;
        /// @notice Timestamp when the invoice was created.
        uint48 createdAt;
        /// @notice Duration (in seconds) after payment before funds are auto-released unless disputed.
        uint32 releaseWindow;
        /// @notice Time window (in seconds) after which the invoice expires if unpaid.
        uint32 invoiceExpiryDuration;
        /// @notice Time window (in seconds) after payment within which the seller must respond.
        uint32 timeBeforeCancelation;
        /// @notice Invoice amount expressed in USD (8 decimals)
        uint256 price;
        /// @notice The total amount paid by the buyer for this invoice, denominated in the payment token (native token if address(0)).
        uint256 amountPaid;
        /// @notice Identifier linking the invoice to a meta invoice. bytes32(0) if not part of any meta invoice.
        bytes32 metaInvoiceOrderId;
    }

    struct MetaInvoice {
        /// @notice Address of the seller.
        address buyer;
        /// @notice Total price of all sub-invoices under this meta invoice.
        uint256 price;
        /// @notice Upper bound invoice ID within this meta invoice.
        uint256 upper;
        /// @notice Lower bound invoice ID within this meta invoice.
        uint256 lower;
        /// @notice Token used for payment. Address zero for native currency.
        address paymentToken;
        /// @notice A unique identifier assigned to this invoice, typically sequentially.
        uint256 invoiceId;
    }

    struct InvoiceCreationParam {
        string orderId;
        /// @notice Address of the seller.
        address seller;
        /// @notice Address of the buyer.
        address buyer;
        /// @notice Duration (in seconds) after which the invoice expires if unpaid.
        uint32 invoiceExpiryDuration;
        /// @notice Duration (in seconds) after payment within which the seller must respond.
        uint32 timeBeforeCancelation;
        /// @notice Duration (in seconds) after payment before funds are auto-released unless disputed.
        uint32 releaseWindow;
        /// @notice Price or amount to be paid for the invoice.
        uint256 price;
    }

    // ================================================================
    //                            FUNCTIONS
    // ================================================================

    /**
     * @notice Creates a single invoice with the specified parameters and returns its unique hash.
     * @dev Only callable by the marketplace contract.
     * @param param The parameters required to create the invoice.
     * @return The keccak256 hash representing the created invoice ID.
     */
    function createSingleInvoice(InvoiceCreationParam memory param) external returns (bytes32);

    /**
     * @notice Creates a meta-invoice composed of multiple sub-invoices for a buyer.
     * @dev Only callable by the marketplace contract. Each sub-invoice is created using the provided parameters,
     *      and all are linked under a single meta-invoice key.
     * @param buyer The address of the buyer for whom the meta-invoice is created.
     * @param param An array of parameters used to create each sub-invoice.
     * @return metaInvoiceOrderId The keccak256 hash representing the meta-invoice ID.
     */
    function createMetaInvoice(address buyer, InvoiceCreationParam[] memory param) external returns (bytes32);

    /**
     * @notice Pays a single invoice using native ETH or an approved ERC20 token.
     * @dev Caller must be the invoice buyer. Use `address(0)` for native payments.
     * @param orderId The ID of the invoice to be paid.
     * @param paymentToken The token address used for payment (or zero address for ETH).
     */
    function paySingleInvoice(bytes32 orderId, address paymentToken) external payable;

    /**
     * @notice Pays all sub-invoices in a meta invoice using native ETH or ERC20.
     * @dev Caller must be the buyer of all sub-invoices. Use `address(0)` for native payment.
     * @param orderId The meta invoice ID to be paid.
     * @param paymentToken The token address used for payment (or zero address for ETH).
     */
    function payMetaInvoice(bytes32 orderId, address paymentToken) external payable;

    /**
     * @notice Accepts multiple invoices by their IDs.
     * @dev Callable only by the respective sellers of each invoice.
     * @param orderIds The array of invoice IDs to be accepted.
     */
    function acceptInvoice(bytes32[] calldata orderIds) external;

    /**
     * @notice Accepts a single invoice.
     * @dev Callable only by the seller of the invoice. The invoice must be in the PAID state.
     * @param orderId The ID of the invoice to be accepted.
     */
    function acceptInvoice(bytes32 orderId) external;

    /**
     * @notice Handles a cancelation request from a buyer by accepting or rejecting it.
     * @dev Callable only by the seller of the invoice. Only valid for invoices in the CANCELATION_REQUESTED state.
     * @param orderId The ID of the invoice for which the cancelation is being handled.
     * @param accept A boolean indicating whether to accept (`true`) or reject (`false`) the cancelation.
     */
    function handleCancelationRequest(bytes32 orderId, bool accept) external;

    /**
     * @notice Requests cancelation for multiple invoices.
     * @dev Callable only by the respective buyers of the invoices.
     *      Only valid for invoices in the PAID state and within the allowed cancelation window.
     * @param orderIds The array of invoice IDs to request cancelation for.
     */
    function requestCancelation(bytes32[] memory orderIds) external;

    /**
     * @notice Requests cancelation for a single invoice.
     * @dev Callable only by the buyer of the invoice.
     *      Only valid for invoices in the PAID state and within the allowed cancelation window.
     * @param orderId The ID of the invoice to request cancelation for.
     */
    function requestCancelation(bytes32 orderId) external;

    /**
     * @notice Cancels multiple invoices.
     * @dev Callable only by the respective sellers of the invoices.
     *      Only valid for invoices in the PAID state.
     * @param orderIds The array of invoice IDs to cancel.
     */
    function cancelInvoice(bytes32[] memory orderIds) external;

    /**
     * @notice Cancels a single invoice.
     * @dev Callable only by the seller of the invoice.
     *      Only valid for invoices in the PAID state.
     * @param orderId The ID of the invoice to cancel.
     */
    function cancelInvoice(bytes32 orderId) external;

    /**
     * @notice Creates a dispute for an invoice.
     * @dev Callable only by the buyer of the invoice.
     *      Only valid for invoices in the ACCEPTED state and within the dispute window.
     * @param orderId The ID of the invoice to dispute.
     */
    function createDispute(bytes32 orderId) external;

    /**
     * @notice handle a dispute on a given invoice.
     * @dev Callable only by the marketplace. Must be called after a dispute is created.
     *      The resolution can be DISPUTE_DISMISSED, or DISPUTE_SETTLED.
     *      If settled, the seller and buyer receive a split of the funds based on sellerShare.
     * @param orderId The ID of the invoice.
     * @param resolution The resolution state (must be one of the defined DISPUTE_* constants).
     * @param sellerShare The portion of the invoice price (in basis points) to be awarded to the seller.
     */
    function handleDispute(bytes32 orderId, uint8 resolution, uint256 sellerShare) external;
    /**
     * @notice Allows the buyer or seller to resolve a disputed invoice by mutual confirmation.
     *  @dev Both parties must call this function once to resolve the dispute. The first caller is recorded,
     *  and the second call finalizes the resolution.
     *  @param orderId The unique identifier (hash) of the invoice to be resolved.
     */
    function resolveDispute(bytes32 orderId) external;

    /**
     * @notice Releases payment to the seller for a successfully completed invoice.
     * @dev Callable only by the marketplace. Only valid for ACCEPTED invoices.
     * @param orderId The ID of the invoice.
     */
    function releasePayment(bytes32 orderId) external;

    /**
     * @notice Allows a buyer to claim a refund if an invoice expires without seller action.
     * @dev Only callable by the buyer, and only if the invoice has passed the cancelation window
     *      without being accepted or canceled. Prevents double refunds.
     * @param orderId The ID of the invoice to claim refund for.
     */
    function claimExpiredInvoiceRefunds(bytes32 orderId) external;

    /**
     * @notice Updates the marketplace address allowed to perform privileged operations.
     * @dev Callable only by the contract owner.
     * @param marketplaceAddr The new marketplace address.
     */
    function setMarketplace(address marketplaceAddr) external;

    /**
     * @notice
     * @param token The address of the ERC20 token.
     * @param aggregator The address of the Chainlink aggregator for the token.
     */
    function setPriceFeed(address token, address aggregator) external;

    /**
     * @notice Retrieves the invoice data for a specific invoice ID.
     * @param orderId The ID of the invoice.
     * @return The Invoice struct containing the invoice details.
     */
    function getInvoice(bytes32 orderId) external view returns (Invoice memory);

    /**
     * @notice Retrieves the meta-invoice data for a specific meta-invoice ID.
     * @param orderId The ID of the meta-invoice.
     * @return The MetaInvoice struct containing the meta-invoice details.
     */
    function getMetaInvoice(bytes32 orderId) external view returns (MetaInvoice memory);

    /**
     * @notice Returns the total number of unique invoices created.
     * @return The count of invoices created so far.
     */
    function totalUniqueInvoiceCreated() external view returns (uint256);

    /**
     * @notice Returns the total number of meta-invoices created.
     * @return The count of meta-invoices created so far.
     */
    function totalMetaInvoiceCreated() external view returns (uint256);

    /**
     * @notice Returns the ID that will be assigned to the next invoice.
     * @return The next invoice ID.
     */
    function getNextInvoiceId() external view returns (uint256);

    /**
     * @notice Returns the ID that will be assigned to the next meta-invoice.
     * @return The next meta-invoice ID.
     */
    function getNextMetaInvoiceId() external view returns (uint256);

    /**
     * @notice Gets the meta-invoice ID associated with a specific sub-invoice.
     * @param orderId The sub-invoice ID.
     * @return The ID of the meta-invoice that includes the given sub-invoice.
     */
    function getMetaInvoiceIdForSub(bytes32 orderId) external view returns (bytes32);

    /**
     * @notice Converts a USD-denominated price to the equivalent amount in the specified payment token.
     * @param paymentToken The address of the payment token (use address(0) for the native token).
     * @param price The USD amount to convert, expressed in 8 decimals (e.g., 100e8 = $100).
     * @return The equivalent amount in the payment token's smallest unit (according to its decimals).
     */
    function getTokenValueFromUsd(address paymentToken, uint256 price) external view returns (uint256);

    /**
     * @notice Returns the address of the authorized marketplace contract.
     * @return The marketplace address allowed to manage invoice creation and updates.
     */
    function getMarketplace() external view returns (address);

    // ================================================================
    //                              EVENTS
    // ================================================================

    /**
     * @notice Emitted when a dispute is dismissed and no party receives a refund or payout.
     * @param orderId The ID of the invoice involved in the dispute.
     */
    event DisputeDismissed(bytes32 indexed orderId);

    /**
     * @notice Emitted when a dispute is resolved in favor of one party without partial refund.
     * @param orderId The ID of the invoice involved in the dispute.
     */
    event DisputeResolved(bytes32 indexed orderId);

    /**
     * @notice Emitted when the seller accepts the invoice, confirming their participation.
     * @param orderId The ID of the accepted invoice.
     */
    event InvoiceAccepted(bytes32 indexed orderId);

    /**
     * @notice Emitted when a new meta-invoice is created.
     * @param metaInvoiceOrderId The unique identifier of the newly created meta-invoice.
     * @param metaInvoice The full meta-invoice struct containing aggregated price and related configuration.
     */
    event MetaInvoiceCreated(bytes32 indexed metaInvoiceOrderId, MetaInvoice metaInvoice);

    /**
     * @notice Emitted when a new invoice is created.
     * @param orderId The ID of the newly created invoice.
     * @param invoice The invoice data.
     */
    event InvoiceCreated(bytes32 indexed orderId, Invoice invoice);

    /**
     * @notice Emitted when an invoice is canceled by the seller and the buyer is refunded.
     * @param orderId The ID of the canceled invoice.
     */
    event InvoiceCanceled(bytes32 indexed orderId);

    /**
     * @notice Emitted when an invoice is rejected during dispute or cancelation.
     * @param orderId The ID of the rejected invoice.
     */
    event InvoiceRejected(bytes32 indexed orderId);

    /**
     * @notice Emitted when a dispute is settled and the funds are split between buyer and seller.
     * @param orderId The ID of the invoice that was disputed.
     * @param sellerAmount The amount transferred to the seller.
     * @param buyerAmount The amount refunded to the buyer.
     */
    event DisputeSettled(bytes32 indexed orderId, uint256 sellerAmount, uint256 buyerAmount);

    /**
     * @notice Emitted when a buyer initiates a cancellation request for an invoice.
     * @param orderId The ID of the invoice for which cancellation was requested.
     */
    event CancelationRequested(bytes32 indexed orderId);

    /**
     * @notice Emitted when an invoice has been successfully paid and escrow is created.
     * @param orderId The ID of the paid invoice.
     * @param paymentToken The address of the token used for payment (use address(0) for native token).
     * @param escrowAddress The address of the newly created escrow contract holding the funds.
     * @param amount The amount paid in the token's smallest denomination (based on token decimals).
     */
    event InvoicePaid(bytes32 indexed orderId, address paymentToken, address escrowAddress, uint256 amount);

    /**
     * @notice Emitted when a cancellation request is either accepted or rejected by the seller.
     * @param orderId The ID of the invoice under consideration.
     * @param accepted Whether the cancellation request was accepted (true) or rejected (false).
     */
    event CancelationRequestHandled(bytes32 indexed orderId, bool indexed accepted);

    /**
     * @notice Emitted when the payment is released to the seller.
     * @param orderId The ID of the invoice for which payment was released.
     */
    event PaymentReleased(bytes32 indexed orderId);

    /**
     * @notice Emitted when a dispute is raised for an invoice by the buyer.
     * @param orderId The ID of the disputed invoice.
     */
    event DisputeCreated(bytes32 indexed orderId);

    /**
     * @notice Emitted when a payment is released before the predefined release timestamp.
     * @param orderId The ID of the invoice that was released early.
     */
    event EarlyRelease(bytes32 indexed orderId);

    /**
     * @notice Emitted when a refund is claimed for an expired invoice.
     * @param orderId The ID of the expired invoice that was refunded.
     */
    event ExpiredInvoiceRefunded(bytes32 indexed orderId);
}
