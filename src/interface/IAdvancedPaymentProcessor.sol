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

    /// @notice Thrown when a payment is attempted on an invoice that has passed its expiry timestamp.
    error InvoiceExpired();

    /// @notice Thrown when a meta-invoice is created with an empty sub-invoice list.
    error EmptyMetaInvoice();

    /// @notice Thrown when a Chainlink price feed is stale and cannot be trusted for conversion.
    error StalePriceFeed();

    /// @notice Thrown when the Chainlink price feed returns a zero or negative answer.
    error InvalidPrice();

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

    /// @notice Thrown if the buyer and seller are the same address.
    error BuyerCannotBeSeller();

    /// @notice Thrown when the invoice is in a state that does not allow the attempted action.
    error InvalidInvoiceState();

    /// @notice Thrown when the invoice does not exist.
    error InvoiceDoesNotExist();

    /// @notice Thrown when an invalid amount of native currency is sent with a payment.
    error InvalidNativePayment();

    /// @notice Thrown when the native payment for a meta-invoice does not match the expected total.
    /// @param sent The amount of native currency provided.
    /// @param expected The expected native payment total.
    error InvalidMetaInvoicePaymentAmount(uint256 sent, uint256 expected);

    /// @notice Thrown when a computed meta-invoice ID (hash) is already assigned in storage.
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
    /// @param expiresAt The timestamp after which the invoice is no longer payable.
    /// @param state Current state of the invoice.
    /// @param escrowHoldPeriod Custom hold duration (in seconds) between payment and release, set at invoice creation. When non-zero, it overrides the storage default.
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
        uint40 expiresAt;
        uint8 state;
        uint32 escrowHoldPeriod;
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
    /// @param invoiceId A unique string identifier for the invoice, provided by the caller and hashed for use in the contract.
    /// @param seller Address of the seller.
    /// @param price Price or amount to be paid for the invoice in USD (8 decimals).
    /// @param escrowHoldPeriod Duration (in seconds) that the escrow will lock the payment before it's releasable.
    struct InvoiceCreationParam {
        string invoiceId;
        address seller;
        uint256 price;
        uint32 escrowHoldPeriod;
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
     * and all are linked under a single meta-invoice ID.
     * @param _param An array of parameters used to create each sub-invoice.
     * @return metaInvoiceId The keccak256 hash representing the meta-invoice ID.
     */
    function createMetaInvoice(InvoiceCreationParam[] memory _param) external returns (uint216 metaInvoiceId);

    /**
     * @notice Pays a single invoice using native ETH or an approved ERC20 token.
     * @param _invoiceId The ID of the invoice to be paid.
     * @param _paymentToken The token address used for payment (or zero address for ETH).
     */
    function payInvoice(uint216 _invoiceId, address _paymentToken) external payable;

    /**
     * @notice Pays all sub-invoices in a meta-invoice using native ETH.
     * @dev Caller must send exactly the oracle-converted total for the meta-invoice price.
     *      Any dust from per-sub-invoice integer rounding is refunded to the caller.
     *      Canceled sub-invoices are automatically excluded: each cancellation reduces the
     *      stored meta-invoice price, so `msg.value` only needs to cover the remaining
     *      non-canceled sub-invoices. Sub-invoices not in CREATED state are silently skipped.
     * @param _invoiceId The meta-invoice ID to pay.
     */
    function payMetaInvoiceWithValue(uint216 _invoiceId) external payable;

    /**
     * @notice Pays all sub-invoices in a meta invoice using native ETH or ERC20.
     * @dev Caller must be the buyer of all sub-invoices. Use `address(0)` for native payment.
     *      Canceled sub-invoices are automatically excluded: each cancellation reduces the
     *      stored meta-invoice price, so the caller only pays for the remaining non-canceled
     *      sub-invoices. Sub-invoices not in CREATED state are silently skipped.
     * @param _invoiceId The meta invoice ID to be paid.
     * @param _paymentToken The token address used for payment.
     */
    function payMetaInvoice(uint216 _invoiceId, address _paymentToken) external;

    /**
     * @notice Cancels a single invoice before payment.
     * @dev Callable only by the marketplace. If the invoice belongs to a meta-invoice,
     *      the meta-invoice total price is reduced accordingly.
     * @param _invoiceId The ID of the invoice to cancel.
     */
    function cancelInvoice(uint216 _invoiceId) external;

    /**
     * @notice Creates a dispute for an invoice.
     * @dev Callable only by the marketplace. Only valid for invoices in the PAID state.
     *      Removes the invoice from the auto-release queue, canceling the pending release timer
     *      until the dispute is resolved or dismissed.
     * @param _invoiceId The ID of the invoice to dispute.
     */
    function createDispute(uint216 _invoiceId) external;

    /**
     * @notice Issues a partial or full refund for a paid invoice.
     * @dev Callable only by the marketplace. Invoice must be in the PAID state.
     *      `_refundShare` must be between 1 and 10,000 basis points (inclusive). The refund
     *      amount is sent directly to the buyer from escrow.
     *      A full refund (10,000 BPS) transitions the invoice to REFUNDED and removes it from
     *      the auto-release heap. A partial refund reduces the escrow balance but leaves the
     *      invoice in PAID state — it remains in the heap and can still be auto-released.
     * @param _invoiceId The identifier of the invoice to refund.
     * @param _refundShare The portion of the escrow balance to refund, in basis points (1% = 100, 100% = 10000).
     */
    function refund(uint216 _invoiceId, uint256 _refundShare) external;

    /**
     * @notice Handles a dispute on a given invoice.
     * @dev Callable only by the marketplace. Invoice must be in the DISPUTED state.
     *      `_resolution` must be either DISPUTE_DISMISSED or DISPUTE_SETTLED; DISPUTE_RESOLVED
     *      is a separate flow handled by `resolveDispute`.
     *      `_sellerShare` must be between 0 and 10,000 BPS (0 = full refund to buyer).
     *      If dismissed, the invoice is re-inserted into the auto-release heap, restoring its
     *      release timer. If settled, funds are immediately distributed between seller and buyer
     *      according to `_sellerShare` and the invoice balance is zeroed.
     * @param _invoiceId The ID of the invoice.
     * @param _resolution The resolution outcome: DISPUTE_DISMISSED or DISPUTE_SETTLED.
     * @param _sellerShare The portion of the escrow balance (in basis points) awarded to the seller (0–10,000).
     */
    function handleDispute(uint216 _invoiceId, uint8 _resolution, uint256 _sellerShare) external;

    /**
     * @notice Finalizes a dispute and marks the invoice as resolved.
     * @dev Callable only by the marketplace after a dispute has been raised by the buyer.
     * This function is used when both parties (buyer and seller) have come to an agreement
     * Transitions the invoice state from DISPUTED to DISPUTE_RESOLVED.
     * @param _invoiceId The unique identifier of the disputed invoice.
     */
    function resolveDispute(uint216 _invoiceId) external;

    /**
     * @notice Releases escrowed funds to the seller after the release window has passed.
     * @dev Callable only by the marketplace. Valid for invoices in the PAID, DISPUTE_RESOLVED,
     *      or DISPUTE_DISMISSED state once `releaseAt` has been reached. Platform fees are
     *      deducted before the net amount is transferred to the seller. The invoice transitions
     *      to RELEASED, its balance is zeroed, and it is removed from the auto-release heap.
     * @param _invoiceId The ID of the invoice.
     */
    function release(uint216 _invoiceId) external;

    /**
     * @notice Sets the Chainlink price feed aggregator for a specific payment token.
     * @dev Callable only by the owner. Use address(0) for `_token` to set the native currency feed.
     *      Setting `_aggregator` to address(0) removes the token from accepted payment methods.
     * @param _token The payment token address, or address(0) for native currency.
     * @param _aggregator The Chainlink aggregator address, or address(0) to disable the token.
     */
    function setPriceFeed(address _token, address _aggregator) external;

    /**
     * @notice Sets a custom release time for a given invoice by adding a hold period to the current timestamp.
     * @dev Callable only by the owner. Valid for invoices in the PAID, DISPUTE_RESOLVED, or DISPUTE_DISMISSED state
     *      (i.e., invoices currently tracked in the heap).
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
     * @notice Sets the minimum USD price an invoice must have to be created.
     * @param _newMinimumPrice The new minimum price threshold (8 decimals, same unit as invoice prices).
     */
    function setMinimumPrice(uint256 _newMinimumPrice) external;

    /**
     * @notice Retrieves the invoice data for a specific invoice ID.
     * @param _invoiceId The ID of the invoice.
     * @return i The invoice data.
     */
    function getInvoice(uint216 _invoiceId) external view returns (Invoice memory i);

    /**
     * @notice Retrieves the meta-invoice data for a specific meta-invoice ID.
     * @param _metaInvoiceId The ID of the meta-invoice.
     * @return m The meta-invoice data.
     */
    function getMetaInvoice(uint216 _metaInvoiceId) external view returns (MetaInvoice memory m);

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
     * @notice Returns the minimum USD price an invoice must meet to be created.
     * @return minimumPrice The current minimum price threshold (8 decimals).
     */
    function getMinimumPrice() external view returns (uint256 minimumPrice);

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
     * @notice Returns the nonce that will be assigned to the next meta-invoice.
     * @return nextMetaInvoiceNonce The next meta-invoice nonce value.
     */
    function getNextMetaInvoiceNonce() external view returns (uint216 nextMetaInvoiceNonce);

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
     * @notice Emitted when an invoice is successfully paid and an escrow contract is created.
     * @param invoiceId The unique identifier of the paid invoice.
     * @param paymentToken The address of the token used for payment (address(0) for native ETH).
     * @param escrowAddress The address of the escrow contract created to hold the payment.
     * @param amount The amount paid, denominated in the token’s smallest unit.
     * @param releaseAt The UNIX timestamp (in seconds) when the escrowed funds become releasable.
     */
    event InvoicePaid(
        uint216 indexed invoiceId, address paymentToken, address escrowAddress, uint256 amount, uint40 releaseAt
    );

    /**
     * @notice Emitted when escrowed funds for an invoice are released.
     * @param invoiceId The unique identifier of the invoice.
     * @param receiver The address that receives the released funds (typically the seller).
     * @param currency The address of the token used for the payment (address(0) for native ETH).
     * @param sellerAmount The amount transferred to the receiver.
     */
    event PaymentReleased(uint216 indexed invoiceId, address receiver, address currency, uint256 sellerAmount);

    /**
     * @notice Emitted when a refund is issued for a specific order.
     * @param invoiceId The unique identifier of the refunded order.
     * @param amount The amount refunded to the buyer.
     */
    event Refunded(uint216 indexed invoiceId, uint256 indexed amount);

    /**
     * @notice Emitted when an invoice is canceled before any payment has been made.
     * @dev Only valid for invoices in the CREATED state — no buyer exists and no funds are moved.
     *      If the invoice belongs to a meta-invoice, the meta-invoice's total price is reduced
     *      by the canceled sub-invoice's price.
     * @param invoiceId The ID of the canceled invoice.
     */
    event InvoiceCanceled(uint216 indexed invoiceId);

    /**
     * @notice Emitted when a dispute is raised for an invoice by the buyer.
     * @param invoiceId The ID of the disputed invoice.
     */
    event DisputeCreated(uint216 indexed invoiceId);

    /**
     * @notice Emitted when a dispute is dismissed and no party receives a refund or payout.
     * @param invoiceId The ID of the invoice involved in the dispute.
     */
    event DisputeDismissed(uint216 indexed invoiceId);

    /**
     * @notice Emitted when a dispute is resolved in the seller's favor via `resolveDispute`.
     * @dev The invoice transitions to DISPUTE_RESOLVED and is re-inserted into the auto-release
     *      heap. The seller receives the full escrow balance (minus platform fees) once `releaseAt`
     *      is reached. No funds are distributed at the time this event is emitted.
     * @param invoiceId The ID of the invoice involved in the dispute.
     */
    event DisputeResolved(uint216 indexed invoiceId);

    /**
     * @notice Emitted when a dispute is settled and the funds are split between buyer and seller.
     * @param invoiceId The ID of the invoice that was disputed.
     * @param sellerAmount The amount transferred to the seller.
     * @param buyerAmount The amount refunded to the buyer.
     */
    event DisputeSettled(uint216 indexed invoiceId, uint256 sellerAmount, uint256 buyerAmount);

    /**
     * @notice Emitted when the escrow release time is updated for a given invoice.
     * @param invoiceId The unique identifier of the invoice whose release time was modified.
     * @param newHoldPeriod The updated escrow hold duration in seconds.
     */
    event UpdateReleaseTime(uint216 indexed invoiceId, uint256 newHoldPeriod);
}
