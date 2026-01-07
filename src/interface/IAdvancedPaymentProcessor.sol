// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 *  @title IAdvancedPaymentProcessor
 *  @notice Interface for the advanced payment processor contract with escrow, meta-invoice, and dispute support.
 */
interface IAdvancedPaymentProcessor {
    // ================================================================
    //                              ERRORS
    // ================================================================

    error UnsupportedToken();
    error StalePriceFeed();

    /// @notice Thrown when an account attempts to withdraw or spend more than its available balance.
    error InsufficientBalance();

    /// @notice Thrown when the provided price does not meet the required minimum threshold.
    error PriceIsTooLow();

    /// @notice Thrown when the caller lacks the required role or permission.
    error NotAuthorized();

    /// @notice Thrown when trying to create an invoice that already exists.
    error InvoiceAlreadyExists();

    /// @notice Thrown when an attempt is made to create an invoice with a price of zero.
    error PriceCannotBeZero();

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

    /// @dev This occurs when a computed meta-invoice ID (hash) is already assigned in storage.
    error MetaInvoiceAlreadyExists();

    /// @notice Thrown when a dispute resolution type is invalid.
    error InvalidDisputeResolution();

    /// @notice Thrown when the seller's payout share exceeds the allowed limit (10000 BPS).
    error InvalidSellersPayoutShare();

    // ================================================================
    //                              STRUCTS
    // ================================================================

    /// @notice Represents a single invoice created by a buyer to pay a seller, with escrow and payment tracking.
    struct Invoice {
        /// @notice A unique identifier assigned to this invoice, typically sequentially.
        uint216 invoiceNonce;
        /// @notice Timestamp when the payment was made.
        uint40 paidAt;
        /// @notice Timestamp when the invoice was created.
        uint40 createdAt;
        /// @notice The timestamp when funds in escrow can be released to the seller.
        uint40 releaseAt;
        /// @notice Current state of the invoice.
        uint8 state;
        /// @notice Identifier linking the invoice to a meta invoice. 0 if not part of any meta invoice.
        uint216 metaInvoiceId;
        /// @notice Address of the buyer.
        address buyer;
        /// @notice Address of the seller.
        address seller;
        /// @notice Address of the escrow contract holding the funds.
        address escrow;
        /// @notice Token used for payment. Address zero for native currency.
        address paymentToken;
        /// @notice Total amount paid by the buyer for this invoice, in the payment token (use native token if `paymentToken == address(0)`).
        uint256 amountPaid;
        /// @notice Invoice amount expressed in USD (8 decimals)
        uint256 price;
        /// @notice Returns the current balance of the escrow associated with the order, accounting for the total amount paid minus any refunds or released amounts.
        uint256 balance;
    }

    /// @notice Represents a collection of sub-invoices grouped into a single meta-invoice for batch payment and tracking.
    struct MetaInvoice {
        /// @notice Total price of all sub-invoices under this meta invoice.
        uint256 price;
        /// @notice List of sub-invoice IDs that are grouped under this meta invoice.
        uint216[] subInvoiceIds;
    }

    /// @notice Parameters used to create a new invoice or sub-invoice.
    struct InvoiceCreationParam {
        /// @notice A unique string identifier for the invoice.
        string orderId;
        /// @notice Address of the seller.
        address seller;
        /// @notice Price or amount to be paid for the invoice.
        uint256 price;
        /// @notice Duration (in seconds) that the escrow will lock the payment before it's releasable.
        uint256 escrowHoldPeriod;
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
    function createSingleInvoice(InvoiceCreationParam memory param) external returns (uint216);

    /**
     * @notice Creates a meta-invoice composed of multiple sub-invoices for a buyer.
     * @dev Only callable by the marketplace contract. Each sub-invoice is created using the provided parameters,
     *      and all are linked under a single meta-invoice key.
     * @param param An array of parameters used to create each sub-invoice.
     * @return metaInvoiceOrderId The keccak256 hash representing the meta-invoice ID.
     */
    function createMetaInvoice(InvoiceCreationParam[] memory param) external returns (uint216);

    /**
     * @notice Pays a single invoice using native ETH or an approved ERC20 token.
     * @dev Caller must be the invoice buyer. Use `address(0)` for native payments.
     * @param orderId The ID of the invoice to be paid.
     * @param paymentToken The token address used for payment (or zero address for ETH).
     */
    function paySingleInvoice(uint216 orderId, address paymentToken) external payable;

    /**
     * @notice Pays all sub-invoices in a meta invoice using native ETH or ERC20.
     * @dev Caller must be the buyer of all sub-invoices. Use `address(0)` for native payment.
     * @param orderId The meta invoice ID to be paid.
     * @param paymentToken The token address used for payment (or zero address for ETH).
     */
    function payMetaInvoice(uint216 orderId, address paymentToken) external payable;

    /**
     * @notice Cancels a single invoice.
     * @dev Callable only by the seller of the invoice.
     *      Only valid for invoices in the PAID state.
     * @param orderId The ID of the invoice to cancel.
     */
    function cancelInvoice(uint216 orderId) external;

    /**
     * @notice Creates a dispute for an invoice.
     * @dev Callable only by the buyer of the invoice.
     *      Only valid for invoices in the ACCEPTED state and within the dispute window.
     * @param orderId The ID of the invoice to dispute.
     */
    function createDispute(uint216 orderId) external;

    /**
     * @notice Issues a refund for a given order.
     * @param orderId The identifier of the order to refund.
     * @param refundShare The portion of the invoice price to refund, specified in basis points (1% = 100).
     */
    function refund(uint216 orderId, uint256 refundShare) external;

    /**
     * @notice handle a dispute on a given invoice.
     * @dev Callable only by the marketplace. Must be called after a dispute is created.
     *      The resolution can be DISPUTE_DISMISSED, or DISPUTE_SETTLED.
     *      If settled, the seller and buyer receive a split of the funds based on sellerShare.
     * @param orderId The ID of the invoice.
     * @param resolution The resolution state (must be one of the defined DISPUTE_* constants).
     * @param sellerShare The portion of the invoice price (in basis points) to be awarded to the seller.
     */
    function handleDispute(uint216 orderId, uint8 resolution, uint256 sellerShare) external;

    /**
     * @notice Finalizes a dispute and marks the invoice as resolved.
     * @dev Callable only by the marketplace after a dispute has been raised by the buyer.
     *      This function is used when both parties (buyer and seller) have come to an agreement
     *      without requiring arbitration, or when the dispute period has expired with no further action.
     *      Transitions the invoice state from DISPUTED to DISPUTE_RESOLVED.
     * @param orderId The unique identifier of the disputed invoice.
     */
    function resolveDispute(uint216 orderId) external;

    /**
     *  @notice Releases escrowed funds to the seller after the release window has passed.
     * @dev Callable only by the marketplace. Only valid for invoices in the ACCEPTED state
     *      and only after `releaseAt` timestamp has been reached.
     * @param orderId The ID of the invoice.
     */
    function release(uint216 orderId) external;

    /**
     * @notice Sets the Chainlink price feed aggregator for a specific payment token.
     * @param token The address of the ERC20 token.
     * @param aggregator The address of the Chainlink aggregator for the token.
     */
    function setPriceFeed(address token, address aggregator) external;

    /**
     * @notice Sets a custom release time for a given invoice by adding a hold period to the current timestamp.
     * @dev Callable only by the storage contract (via `execute()`), not directly by users or marketplace.
     * @param orderId The ID of the invoice to update.
     * @param holdPeriod The duration in seconds to wait before the funds can be released.
     */
    function setInvoiceReleaseTime(uint216 orderId, uint256 holdPeriod) external;

    /**
     * @notice Updates the address of the forwarder contract used for relayed or automated calls.
     * @param forwarderAddress The new forwarder contract address to be set.
     */
    function setForwarderAddress(address forwarderAddress) external;

    /**
     * @notice Retrieves the invoice data for a specific invoice ID.
     * @param orderId The ID of the invoice.
     * @return The Invoice struct containing the invoice details.
     */
    function getInvoice(uint216 orderId) external view returns (Invoice memory);

    /**
     * @notice Retrieves the meta-invoice data for a specific meta-invoice ID.
     * @param orderId The ID of the meta-invoice.
     * @return The MetaInvoice struct containing the meta-invoice details.
     */
    function getMetaInvoice(uint216 orderId) external view returns (MetaInvoice memory);

    /**
     * @notice Returns the total number of unique invoices created.
     * @return The count of invoices created so far.
     */
    function totalUniqueInvoiceCreated() external view returns (uint216);

    /**
     * @notice Returns the total number of meta-invoices created.
     * @return The count of meta-invoices created so far.
     */
    function totalMetaInvoiceCreated() external view returns (uint216);

    /**
     * @notice Returns the address of the configured forwarder contract.
     * @return The forwarder contract address.
     */
    function getForwarder() external view returns (address);

    /**
     * @notice Returns the ID that will be assigned to the next invoice.
     * @return The next invoice ID.
     */
    function getNextInvoiceNonce() external view returns (uint216);

    /**
     * @notice Returns the ID that will be assigned to the next meta-invoice.
     * @return The next meta-invoice ID.
     */
    function getNextMetaInvoiceNonce() external view returns (uint216);

    /**
     * @notice Returns a list of all task IDs currently in the heap.
     * @dev Retrieves the uint216 task identifiers extracted from the internal encoded heap structure.
     * @return An array of task IDs (uint256) currently stored in the heap.
     */
    function getItems() external view returns (uint216[] memory);

    /**
     * @notice Converts a USD-denominated price to the equivalent amount in the specified payment token.
     * @param paymentToken The address of the payment token (use address(0) for the native token).
     * @param usdAmount The USD amount to convert, expressed in 8 decimals (e.g., 100e8 = $100).
     * @return The equivalent amount in the payment token's smallest unit (according to its decimals).
     */
    function getTokenValueFromUsd(address paymentToken, uint256 usdAmount) external view returns (uint256);

    // ================================================================
    //                              EVENTS
    // ================================================================

    /**
     * @notice Emitted when a dispute is dismissed and no party receives a refund or payout.
     * @param orderId The ID of the invoice involved in the dispute.
     */
    event DisputeDismissed(uint216 indexed orderId);

    /**
     * @notice Emitted when a dispute is resolved in favor of one party without partial refund.
     * @param orderId The ID of the invoice involved in the dispute.
     */
    event DisputeResolved(uint216 indexed orderId);

    /**
     * @notice Emitted when a new invoice is created.
     * @param orderId The ID of the newly created invoice.
     * @param invoice The invoice data.
     */
    event InvoiceCreated(uint216 indexed orderId, Invoice invoice);

    /**
     * @notice Emitted when a meta-invoice is successfully created.
     * @param metaInvoiceId The unique identifier of the newly created meta-invoice.
     * @param totalPrice The aggregated total price (in USD, 8 decimals) of all sub-invoices under this meta-invoice.
     */
    event MetaInvoiceCreated(uint216 indexed metaInvoiceId, uint256 indexed totalPrice);

    /**
     * @notice Emitted when an invoice is canceled by the seller and the buyer is refunded.
     * @param orderId The ID of the canceled invoice.
     */
    event InvoiceCanceled(uint216 indexed orderId);

    /**
     * @notice Emitted when a dispute is settled and the funds are split between buyer and seller.
     * @param orderId The ID of the invoice that was disputed.
     * @param sellerAmount The amount transferred to the seller.
     * @param buyerAmount The amount refunded to the buyer.
     */
    event DisputeSettled(uint216 indexed orderId, uint256 sellerAmount, uint256 buyerAmount);

    /**
     * @notice Emitted when an invoice has been successfully paid and escrow is created.
     * @param orderId The ID of the paid invoice.
     * @param paymentToken The address of the token used for payment (use address(0) for native token).
     * @param escrowAddress The address of the newly created escrow contract holding the funds.
     * @param amount The amount paid in the token's smallest denomination (based on token decimals).
     */
    event InvoicePaid(uint216 indexed orderId, address paymentToken, address escrowAddress, uint256 amount);

    /**
     * @notice Emitted when the escrow release time is updated for a given invoice.
     * @param orderId The unique identifier of the invoice whose release time was modified.
     * @param newHoldPeriod The updated escrow hold duration in seconds.
     */
    event UpdateReleaseTime(uint216 indexed orderId, uint256 newHoldPeriod);

    /**
     * @notice Emitted when the payment is released to the seller.
     * @param orderId The ID of the invoice for which payment was released.
     * @param sellerAmount The amount transferred to the seller.
     */
    event PaymentReleased(uint216 indexed orderId, uint256 sellerAmount);

    /**
     * @notice Emitted when a dispute is raised for an invoice by the buyer.
     * @param orderId The ID of the disputed invoice.
     */
    event DisputeCreated(uint216 indexed orderId);

    /**
     * @notice Emitted when a refund is issued for a specific order.
     * @param orderId The unique identifier of the refunded order.
     * @param amount The amount refunded to the buyer.
     */
    event Refunded(uint216 indexed orderId, uint256 indexed amount);
}
