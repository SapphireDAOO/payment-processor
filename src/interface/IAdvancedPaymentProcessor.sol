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

    /// @notice Thrown when a payment is attempted with a token that is not supported by the processor.
    error UnsupportedToken();

    /// @notice Thrown when a Chainlink price feed is stale and cannot be trusted for conversion.
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
    /// @param invoiceNonce A unique identifier assigned to this invoice, typically sequentially.
    /// @param paidAt Timestamp when the payment was made.
    /// @param createdAt Timestamp when the invoice was created.
    /// @param releaseAt The timestamp when funds in escrow can be released to the seller.
    /// @param state Current state of the invoice.
    /// @param metaInvoiceId Identifier linking the invoice to a meta invoice. 0 if not part of any meta invoice.
    /// @param buyer Address of the buyer.
    /// @param seller Address of the seller.
    /// @param escrow Address of the escrow contract holding the funds.
    /// @param paymentToken Token used for payment. Address zero for native currency.
    /// @param amountPaid Total amount paid by the buyer for this invoice, in the payment token (use native token if `paymentToken == address(0)`).
    /// @param price Invoice amount expressed in USD (8 decimals).
    /// @param balance Current balance of the escrow associated with the order, accounting for total amount paid minus refunds or releases.
    struct Invoice {
        uint216 invoiceNonce;
        uint40 paidAt;
        uint40 createdAt;
        uint40 releaseAt;
        uint8 state;
        uint216 metaInvoiceId;
        address buyer;
        address seller;
        address escrow;
        address paymentToken;
        uint256 amountPaid;
        uint256 price;
        uint256 balance;
    }

    /// @notice Represents a collection of sub-invoices grouped into a single meta-invoice for batch payment and tracking.
    /// @param price Total price of all sub-invoices under this meta invoice.
    /// @param subInvoiceIds List of sub-invoice IDs that are grouped under this meta invoice.
    struct MetaInvoice {
        uint256 price;
        uint216[] subInvoiceIds;
    }

    /// @notice Parameters used to create a new invoice or sub-invoice.
    /// @param invoiceId A unique string identifier for the invoice.
    /// @param seller Address of the seller.
    /// @param price Price or amount to be paid for the invoice.
    /// @param escrowHoldPeriod Duration (in seconds) that the escrow will lock the payment before it's releasable.
    struct InvoiceCreationParam {
        string invoiceId;
        address seller;
        uint256 price;
        uint256 escrowHoldPeriod;
    }

    // ================================================================
    //                            FUNCTIONS
    // ================================================================

    /**
     * @notice Creates a single invoice with the specified parameters and returns its unique hash.
     * @dev Only callable by the marketplace contract.
     * @param _param The parameters required to create the invoice.
     * @return invoiceId The unique ID of the newly created invoice.
     */
    function createSingleInvoice(InvoiceCreationParam memory _param) external returns (uint216 invoiceId);

    /**
     * @notice Creates a meta-invoice composed of multiple sub-invoices for a buyer.
     * @dev Only callable by the marketplace contract. Each sub-invoice is created using the provided parameters,
     * and all are linked under a single meta-invoice key.
     * @param _param An array of parameters used to create each sub-invoice.
     * @return metaInvoiceId The keccak256 hash representing the meta-invoice ID.
     */
    function createMetaInvoice(InvoiceCreationParam[] memory _param) external returns (uint216 metaInvoiceId);

    /**
     * @notice Pays a single invoice using native ETH or an approved ERC20 token.
     * @dev Caller must be the invoice buyer. Use `address(0)` for native payments.
     * @param _invoiceId The ID of the invoice to be paid.
     * @param _paymentToken The token address used for payment (or zero address for ETH).
     */
    function paySingleInvoice(uint216 _invoiceId, address _paymentToken) external payable;

    /**
     * @notice Pays all sub-invoices in a meta invoice using native ETH or ERC20.
     * @dev Caller must be the buyer of all sub-invoices. Use `address(0)` for native payment.
     * @param _invoiceId The meta invoice ID to be paid.
     * @param _paymentToken The token address used for payment (or zero address for ETH).
     */
    function payMetaInvoice(uint216 _invoiceId, address _paymentToken) external payable;

    /**
     * @notice Cancels a single invoice.
     * @dev Callable only by the seller of the invoice.
     * Only valid for invoices in the PAID state.
     * @param _invoiceId The ID of the invoice to cancel.
     */
    function cancelInvoice(uint216 _invoiceId) external;

    /**
     * @notice Creates a dispute for an invoice.
     * @dev Callable only by the buyer of the invoice.
     * Only valid for invoices in the ACCEPTED state and within the dispute window.
     * @param _invoiceId The ID of the invoice to dispute.
     */
    function createDispute(uint216 _invoiceId) external;

    /**
     * @notice Issues a refund for a given order.
     * @param _invoiceId The identifier of the order to refund.
     * @param _refundShare The portion of the invoice price to refund, specified in basis points (1% = 100).
     */
    function refund(uint216 _invoiceId, uint256 _refundShare) external;

    /**
     * @notice handle a dispute on a given invoice.
     * @dev Callable only by the marketplace. Must be called after a dispute is created.
     * The resolution can be DISPUTE_DISMISSED, or DISPUTE_SETTLED.
     * If settled, the seller and buyer receive a split of the funds based on sellerShare.
     * @param _invoiceId The ID of the invoice.
     * @param _resolution The resolution state (must be one of the defined DISPUTE_* constants).
     * @param _sellerShare The portion of the invoice price (in basis points) to be awarded to the seller.
     */
    function handleDispute(uint216 _invoiceId, uint8 _resolution, uint256 _sellerShare) external;

    /**
     * @notice Finalizes a dispute and marks the invoice as resolved.
     * @dev Callable only by the marketplace after a dispute has been raised by the buyer.
     * This function is used when both parties (buyer and seller) have come to an agreement
     * without requiring arbitration, or when the dispute period has expired with no further action.
     * Transitions the invoice state from DISPUTED to DISPUTE_RESOLVED.
     * @param _invoiceId The unique identifier of the disputed invoice.
     */
    function resolveDispute(uint216 _invoiceId) external;

    /**
     * @notice Releases escrowed funds to the seller after the release window has passed.
     * @dev Callable only by the marketplace. Only valid for invoices in the ACCEPTED state
     * and only after `releaseAt` timestamp has been reached.
     * @param _invoiceId The ID of the invoice.
     */
    function release(uint216 _invoiceId) external;

    /**
     * @notice Sets the Chainlink price feed aggregator for a specific payment token.
     * @param _token The address of the ERC20 token.
     * @param _aggregator The address of the Chainlink aggregator for the token.
     */
    function setPriceFeed(address _token, address _aggregator) external;

    /**
     * @notice Sets a custom release time for a given invoice by adding a hold period to the current timestamp.
     * @dev Callable only by the storage contract (via `execute()`), not directly by users or marketplace.
     * @param _invoiceId The ID of the invoice to update.
     * @param _holdPeriod Additional hold period (in seconds) to add to the current timestamp.
     */
    function setInvoiceReleaseTime(uint216 _invoiceId, uint256 _holdPeriod) external;

    /**
     * @notice Updates the address of the forwarder contract used for relayed or automated calls.
     * @param _forwarderAddress The new forwarder contract address to be set.
     */
    function setForwarderAddress(address _forwarderAddress) external;

    /**
     * @notice Retrieves the invoice data for a specific invoice ID.
     * @param _invoiceId The ID of the invoice.
     * @return invoiceData The invoice data.
     */
    function getInvoice(uint216 _invoiceId) external view returns (Invoice memory invoiceData);

    /**
     * @notice Retrieves the meta-invoice data for a specific meta-invoice ID.
     * @param _metaInvoiceId The ID of the meta-invoice.
     * @return metaInvoiceData The meta-invoice data.
     */
    function getMetaInvoice(uint216 _metaInvoiceId) external view returns (MetaInvoice memory metaInvoiceData);

    /**
     * @notice Returns the total number of unique invoices created.
     * @return totalInvoices The total number of unique invoices created.
     */
    function totalUniqueInvoiceCreated() external view returns (uint216 totalInvoices);

    /**
     * @notice Returns the total number of meta-invoices created.
     * @return totalMetaInvoices The total number of meta-invoices created.
     */
    function totalMetaInvoiceCreated() external view returns (uint216 totalMetaInvoices);

    /**
     * @notice Returns the address of the configured forwarder contract.
     * @return forwarderAddress The configured forwarder address.
     */
    function getForwarder() external view returns (address forwarderAddress);

    /**
     * @notice Returns the nonce that will be assigned to the next invoice.
     * @return nextInvoiceNonce The next invoice nonce value.
     */
    function getNextInvoiceNonce() external view returns (uint216 nextInvoiceNonce);

    /**
     * @notice Returns the ID that will be assigned to the next meta-invoice.
     * @return nextMetaInvoiceId The next meta-invoice nonce value.
     */
    function getNextMetaInvoiceNonce() external view returns (uint216 nextMetaInvoiceId);

    /**
     * @notice Returns a list of all task IDs currently in the heap.
     * @dev Retrieves the uint216 task identifiers extracted from the internal encoded heap structure.
     * @return items Array of task IDs.
     */
    function getItems() external view returns (uint216[] memory items);

    /**
     * @notice Converts a USD-denominated price to the equivalent amount in the specified payment token.
     * @param _paymentToken The address of the payment token (use address(0) for the native token).
     * @param _usdAmount The USD amount to convert, expressed in 8 decimals (e.g., 100e8 = $100).
     * @return tokenValue The converted payment token amount.
     */
    function getTokenValueFromUsd(address _paymentToken, uint256 _usdAmount) external view returns (uint256 tokenValue);

    // ================================================================
    //                              EVENTS
    // ================================================================

    /**
     * @notice Emitted when a dispute is dismissed and no party receives a refund or payout.
     * @param invoiceId The ID of the invoice involved in the dispute.
     */
    event DisputeDismissed(uint216 indexed invoiceId);

    /**
     * @notice Emitted when a dispute is resolved in favor of one party without partial refund.
     * @param invoiceId The ID of the invoice involved in the dispute.
     */
    event DisputeResolved(uint216 indexed invoiceId);

    /**
     * @notice Emitted when a new invoice is created.
     * @param invoiceId The ID of the newly created invoice.
     * @param invoice The invoice data.
     */
    event InvoiceCreated(uint216 indexed invoiceId, Invoice invoice);

    /**
     * @notice Emitted when a meta-invoice is successfully created.
     * @param metaInvoiceId The unique identifier of the newly created meta-invoice.
     * @param totalPrice The aggregated total price (in USD, 8 decimals) of all sub-invoices under this meta-invoice.
     */
    event MetaInvoiceCreated(uint216 indexed metaInvoiceId, uint256 indexed totalPrice);

    /**
     * @notice Emitted when an invoice is canceled by the seller and the buyer is refunded.
     * @param invoiceId The ID of the canceled invoice.
     */
    event InvoiceCanceled(uint216 indexed invoiceId);

    /**
     * @notice Emitted when a dispute is settled and the funds are split between buyer and seller.
     * @param invoiceId The ID of the invoice that was disputed.
     * @param sellerAmount The amount transferred to the seller.
     * @param buyerAmount The amount refunded to the buyer.
     */
    event DisputeSettled(uint216 indexed invoiceId, uint256 sellerAmount, uint256 buyerAmount);

    /**
     * @notice Emitted when an invoice has been successfully paid and escrow is created.
     * @param invoiceId The ID of the paid invoice.
     * @param paymentToken The address of the token used for payment (use address(0) for native token).
     * @param escrowAddress The address of the newly created escrow contract holding the funds.
     * @param amount The amount paid in the token's smallest denomination (based on token decimals).
     */
    event InvoicePaid(uint216 indexed invoiceId, address paymentToken, address escrowAddress, uint256 amount);

    /**
     * @notice Emitted when the escrow release time is updated for a given invoice.
     * @param invoiceId The unique identifier of the invoice whose release time was modified.
     * @param newHoldPeriod The updated escrow hold duration in seconds.
     */
    event UpdateReleaseTime(uint216 indexed invoiceId, uint256 newHoldPeriod);

    /**
     * @notice Emitted when the payment is released to the seller.
     * @param invoiceId The ID of the invoice for which payment was released.
     * @param sellerAmount The amount transferred to the seller.
     */
    event PaymentReleased(uint216 indexed invoiceId, uint256 sellerAmount);

    /**
     * @notice Emitted when a dispute is raised for an invoice by the buyer.
     * @param invoiceId The ID of the disputed invoice.
     */
    event DisputeCreated(uint216 indexed invoiceId);

    /**
     * @notice Emitted when a refund is issued for a specific order.
     * @param invoiceId The unique identifier of the refunded order.
     * @param amount The amount refunded to the buyer.
     */
    event Refunded(uint216 indexed invoiceId, uint256 indexed amount);
}
