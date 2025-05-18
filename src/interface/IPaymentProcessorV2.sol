// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPaymentProcessorV2 {
    // ================================================================
    //                              ERRORS
    // ================================================================

    /// @notice Thrown when the caller is not the expected buyer.
    error InvalidBuyer();

    /// @notice Thrown when the caller lacks the required role or permission.
    error NotAuthorized();

    /// @notice Thrown when attempting to interact with an expired invoice.
    error InvoiceExpired();

    /// @notice Thrown when an invoice has already been refunded.
    error AlreadyRefunded();

    /// @notice Thrown when the caller is not the invoice's buyer.
    error UnauthorizedBuyer();

    /// @notice Thrown when an escrow has zero balance during an operation.
    error ZeroEscrowBalance();

    /// @notice Thrown when the caller is not the invoice's seller.
    error UnauthorizedSeller();

    /// @notice Thrown when the invoice is still active and certain actions are not allowed.
    error InvoiceStillActive();

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

    /// @notice Thrown when none of the sub-invoices in a meta-invoice were cancelled.
    error NoSubInvoiceCancelled();

    /// @notice Thrown when the escrow address does not match expectations.
    error EscrowAddressMismatch();

    /// @notice Thrown when no payout share was allocated to the buyer in a dispute resolution.
    error NoShareAllocatedToBuyer();

    /// @notice Thrown when a dispute resolution type is invalid.
    error InvalidDisputeResolution();

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
        /// @notice Address of the buyer.
        address buyer;
        /// @notice Address of the seller.
        address seller;
        /// @notice Address of the escrow contract holding the funds.
        address escrow;
        /// @notice Token used for payment. Address zero for native currency.
        address paymentToken;
        /// @notice Current state of the invoice.
        uint8 state;
        /// @notice Timestamp when the payment was made.
        uint48 paidAt;
        /// @notice Timestamp when the invoice was created.
        uint48 createdAt;
        /// @notice Time window (in seconds) within which a dispute can be created after payment.
        uint32 disputeWindow;
        /// @notice Time window (in seconds) after which the invoice expires if unpaid.
        uint32 invoiceExpiryDuration;
        /// @notice Time window (in seconds) after payment within which the seller must respond.
        uint32 timeBeforeCancelation;
        /// @notice Price or amount to be paid for the invoice.
        uint256 price;
        /// @notice Identifier linking the invoice to a meta invoice. Zero if not part of any meta invoice.
        uint256 metaInvoiceId;
    }

    struct MetaInvoice {
        /// @notice Total price of all sub-invoices under this meta invoice.
        uint256 price;
        /// @notice Upper bound invoice ID within this meta invoice.
        uint256 upper;
        /// @notice Lower bound invoice ID within this meta invoice.
        uint256 lower;
        /// @notice Token used for payment. Address zero for native currency.
        address paymentToken;
        /// @notice Address of the escrow contract managing the meta invoice.
        address escrow;
    }

    struct InvoiceCreationParam {
        /// @notice Address of the seller.
        address seller;
        /// @notice Address of the buyer.
        address buyer;
        /// @notice Duration (in seconds) after which the invoice expires if unpaid.
        uint32 invoiceExpiryDuration;
        /// @notice Duration (in seconds) after payment within which the seller must respond.
        uint32 timeBeforeCancelation;
        /// @notice Duration (in seconds) after payment within which a dispute can be raised.
        uint32 disputeWindow;
        /// @notice Price or amount to be paid for the invoice.
        uint256 price;
    }

    // ================================================================
    //                            FUNCTIONS
    // ================================================================

    /**
     * @notice Creates a single invoice with the specified parameters.
     * @dev Only callable by the marketplace contract.
     * @param param The parameters required to create the invoice.
     */
    function createSingleInvoice(InvoiceCreationParam memory param) external;

    /**
     * @notice Creates a meta invoice composed of multiple sub-invoices for a buyer.
     * @dev Only callable by the marketplace contract.
     * @param buyer The buyer address for the meta invoice.
     * @param param An array of parameters for each sub-invoice.
     */
    function createMetaInvoice(address buyer, InvoiceCreationParam[] memory param) external;

    /**
     * @notice Pays a single invoice using native ETH or an approved ERC20 token.
     * @dev Caller must be the invoice buyer. Use `address(0)` for native payments.
     * @param id The ID of the invoice to be paid.
     * @param paymentToken The token address used for payment (or zero address for ETH).
     */
    function paySingleInvoice(uint256 id, address paymentToken) external payable;

    /**
     * @notice Pays all sub-invoices in a meta invoice using native ETH or ERC20.
     * @dev Caller must be the buyer of all sub-invoices. Use `address(0)` for native payment.
     * @param id The meta invoice ID to be paid.
     * @param paymentToken The token address used for payment (or zero address for ETH).
     */
    function payMetaInvoice(uint256 id, address paymentToken) external payable;

    /**
     * @notice Accepts multiple invoices by their IDs.
     * @dev Callable only by the respective sellers of each invoice.
     * @param ids The array of invoice IDs to be accepted.
     */
    function acceptInvoice(uint256[] calldata ids) external;

    /**
     * @notice Accepts a single invoice.
     * @dev Callable only by the seller of the invoice. The invoice must be in the PAID state.
     * @param id The ID of the invoice to be accepted.
     */
    function acceptInvoice(uint256 id) external;

    /**
     * @notice Handles a cancelation request from a buyer by accepting or rejecting it.
     * @dev Callable only by the seller of the invoice. Only valid for invoices in the CANCELATION_REQUESTED state.
     * @param id The ID of the invoice for which the cancelation is being handled.
     * @param accept A boolean indicating whether to accept (`true`) or reject (`false`) the cancelation.
     */
    function handleCancelationRequest(uint256 id, bool accept) external;

    /**
     * @notice Requests cancelation for multiple invoices.
     * @dev Callable only by the respective buyers of the invoices.
     *      Only valid for invoices in the PAID state and within the allowed cancelation window.
     * @param ids The array of invoice IDs to request cancelation for.
     */
    function requestCancelation(uint256[] memory ids) external;

    /**
     * @notice Requests cancelation for a single invoice.
     * @dev Callable only by the buyer of the invoice.
     *      Only valid for invoices in the PAID state and within the allowed cancelation window.
     * @param id The ID of the invoice to request cancelation for.
     */
    function requestCancelation(uint256 id) external;

    /**
     * @notice Cancels multiple invoices.
     * @dev Callable only by the respective sellers of the invoices.
     *      Only valid for invoices in the PAID state.
     * @param ids The array of invoice IDs to cancel.
     */
    function cancelInvoice(uint256[] memory ids) external;

    /**
     * @notice Cancels a single invoice.
     * @dev Callable only by the seller of the invoice.
     *      Only valid for invoices in the PAID state.
     * @param id The ID of the invoice to cancel.
     */
    function cancelInvoice(uint256 id) external;

    /**
     * @notice Creates a dispute for an invoice.
     * @dev Callable only by the buyer of the invoice.
     *      Only valid for invoices in the ACCEPTED state and within the dispute window.
     * @param id The ID of the invoice to dispute.
     */
    function createDispute(uint256 id) external;

    /**
     * @notice Resolves a dispute on a given invoice.
     * @dev Callable only by the marketplace. Must be called after a dispute is created.
     *      The resolution can be DISPUTE_RESOLVED, DISPUTE_DISMISSED, or DISPUTE_SETTLED.
     *      If settled, the seller and buyer receive a split of the funds based on sellerShare.
     * @param id The ID of the invoice.
     * @param resolution The resolution state (must be one of the defined DISPUTE_* constants).
     * @param sellerShare The portion of the invoice price (in basis points) to be awarded to the seller.
     */
    function resolveDispute(uint256 id, uint8 resolution, uint256 sellerShare) external;

    /**
     * @notice Releases payment to the seller for a successfully completed invoice.
     * @dev Callable only by the marketplace. Only valid for ACCEPTED invoices.
     * @param id The ID of the invoice.
     */
    function releasePayment(uint256 id) external;

    /**
     * @notice Allows a buyer to claim a refund if an invoice expires without seller action.
     * @dev Only callable by the buyer, and only if the invoice has passed the cancelation window
     *      without being accepted or canceled. Prevents double refunds.
     * @param id The ID of the invoice to claim refund for.
     */
    function claimExpiredInvoiceRefunds(uint256 id) external;

    /**
     * @notice Updates the fee rate for seller payouts.
     * @dev Callable only by the contract owner.
     * @param _feeRate The new fee rate in basis points (1% = 100 basis points).
     */
    function setFeeRate(uint256 _feeRate) external;

    /**
     * @notice Updates the marketplace address allowed to perform privileged operations.
     * @dev Callable only by the contract owner.
     * @param marketplaceAddr The new marketplace address.
     */
    function setMarketplace(address marketplaceAddr) external;

    /**
     * @notice Sets the allowance status of a given ERC20 token for payments.
     * @dev Callable only by the contract owner.
     * @param token The address of the ERC20 token.
     * @param state True to allow, false to disallow.
     */
    function setPaymentTokenState(address token, bool state) external;

    /**
     * @notice Sets the address that will receive fees collected from transactions.
     * @dev Callable only by the contract owner.
     * @param feeReceiverAddress The address to receive protocol fees.
     */
    function setFeeReceiver(address feeReceiverAddress) external;

    /**
     * @notice Retrieves the invoice data for a specific invoice ID.
     * @param id The ID of the invoice.
     * @return The Invoice struct containing the invoice details.
     */
    function getInvoice(uint256 id) external view returns (Invoice memory);

    /**
     * @notice Retrieves the meta-invoice data for a specific meta-invoice ID.
     * @param id The ID of the meta-invoice.
     * @return The MetaInvoice struct containing the meta-invoice details.
     */
    function getMetaInvoice(uint256 id) external view returns (MetaInvoice memory);

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
     * @param id The sub-invoice ID.
     * @return The ID of the meta-invoice that includes the given sub-invoice.
     */
    function getMetaInvoiceIdForSub(uint256 id) external view returns (uint256);

    // ================================================================
    //                              EVENTS
    // ================================================================

    /**
     * @notice Emitted when a dispute is dismissed and no party receives a refund or payout.
     * @param invoiceId The ID of the invoice involved in the dispute.
     */
    event DisputeDismissed(uint256 indexed invoiceId);

    /**
     * @notice Emitted when a dispute is resolved in favor of one party without partial refund.
     * @param invoiceId The ID of the invoice involved in the dispute.
     */
    event DisputeResolved(uint256 indexed invoiceId);

    /**
     * @notice Emitted when the seller accepts the invoice, confirming their participation.
     * @param invoiceId The ID of the accepted invoice.
     */
    event InvoiceAccepted(uint256 indexed invoiceId);

    /**
     * @notice Emitted when a sub-invoice under a meta-invoice is paid successfully.
     * @param id The ID of the sub-invoice paid.
     */
    event MetaInvoiceSubPaid(uint256 indexed id);

    /**
     * @notice Emitted when a new meta-invoice is created.
     * @param id The ID of the newly created meta-invoice.
     * @param price The total price of all sub-invoices under this meta-invoice.
     */
    event OpenedMetaInvoice(uint256 indexed id, uint256 indexed price);

    /**
     * @notice Emitted when a new invoice is created.
     * @param invoiceId The ID of the newly created invoice.
     * @param invoice The invoice data.
     */
    event OpenedInvoice(uint256 indexed invoiceId, Invoice invoice);

    /**
     * @notice Emitted when an invoice is canceled by the seller and the buyer is refunded.
     * @param invoiceId The ID of the canceled invoice.
     */
    event InvoiceCanceled(uint256 indexed invoiceId);

    /**
     * @notice Emitted when an invoice is rejected during dispute or cancelation.
     * @param invoiceId The ID of the rejected invoice.
     */
    event InvoiceRejected(uint256 indexed invoiceId);

    /**
     * @notice Emitted when a dispute is settled and the funds are split between buyer and seller.
     * @param id The ID of the invoice that was disputed.
     * @param sellerAmount The amount transferred to the seller.
     * @param buyerAmount The amount refunded to the buyer.
     */
    event DisputeSettled(uint256 indexed id, uint256 sellerAmount, uint256 buyerAmount);
}
