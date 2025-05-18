// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPaymentProcessorV2 {
    error InvalidBuyer();
    error InvalidMetaInvoicePayment();
    error InvalidPaymentToken();
    error InvalidNativePayment();
    error EscrowAddressMismatch();
    error NoSubInvoiceCancelled();
    error InvalidInvoiceState();
    error UnauthorizedSeller();
    error InvoiceDoesNotExist();
    error UnauthorizedBuyer();
    error InvoiceResponseTimeExpired();
    error DisputeWindowExpired();
    error InvalidDisputeResolution();
    error InvalidSellersPayoutShare();
    error NoShareAllocatedToBuyer();
    error NotAuthorized();
    error InvoiceExpired();
    error CancelationRequestDeadlinePassed();
    error ZeroEscrowBalance();
    error AlreadyRefunded();
    error InvoiceStillActive();

    struct Invoice {
        address buyer;
        address seller;
        address escrow;
        address paymentToken;
        uint8 state;
        uint48 paidAt;
        uint48 createdAt;
        uint32 disputeWindow;
        uint32 invoiceExpiryDuration;
        uint32 timeBeforeCancelation;
        uint256 price;
        uint256 metaInvoiceId;
    }

    struct MetaInvoice {
        uint256 price;
        uint256 upper;
        uint256 lower;
        address paymentToken;
        address escrow;
    }

    struct InvoiceCreationParam {
        address seller;
        address buyer;
        uint32 invoiceExpiryDuration;
        uint32 timeBeforeCancelation;
        uint32 disputeWindow;
        uint256 price;
    }

    function createSingleInvoice(InvoiceCreationParam memory param) external;
    function createMetaInvoice(address buyer, InvoiceCreationParam[] memory param) external;
    function paySingleInvoice(uint256 id, address paymentToken) external payable;
    function payMetaInvoice(uint256 id, address paymentToken) external payable;

    function acceptInvoice(uint256[] calldata ids) external;
    function acceptInvoice(uint256 id) external;
    function handleCancelationRequest(uint256 id, bool accept) external;

    function requestCancelation(uint256[] memory ids) external;

    function requestCancelation(uint256 id) external;

    function cancelInvoice(uint256[] memory ids) external;

    function cancelInvoice(uint256 id) external;

    function createDispute(uint256 id) external;

    function resolveDispute(uint256 id, uint8 resolution, uint256 sellerShare) external;

    function releasePayment(uint256 id) external;

    function claimExpiredInvoiceRefunds(uint256 id) external;

    event DisputeDismissed(uint256 indexed invoiceId);
    event DisputeResolved(uint256 indexed invoiceId);
    event InvoiceAccepted(uint256 indexed invoiceId);
    event MetaInvoiceSubPaid(uint256 indexed id);
    event OpenedMetaInvoice(uint256 indexed id, uint256 indexed price);
    event OpenedInvoice(uint256 indexed invoiceId, Invoice invoice);
    event InvoiceCanceled(uint256 indexed invoiceId);
    event InvoiceRejected(uint256 indexed invoiceId);
    event DisputeSettled(uint256 indexed id, uint256 sellerAmount, uint256 buyerAmount);
}
