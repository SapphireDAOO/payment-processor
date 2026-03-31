// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

uint8 constant CREATED = 1;

uint8 constant PAID = 2;

uint8 constant REFUNDED = 3;

uint8 constant CANCELED = 4;

uint8 constant DISPUTED = 5;

uint8 constant DISPUTE_RESOLVED = 6;

uint8 constant DISPUTE_DISMISSED = 7;

uint8 constant DISPUTE_SETTLED = 8;

uint8 constant RELEASED = 9;

uint8 constant LOCKED = 10;

uint256 constant BASIS_POINTS = 10_000;

uint8 constant DEFAULT_DECIMAL = 18;

uint256 constant DEFAULT_MINIMUM_INVOICE_PRICE = 1e8;

uint8 constant MAX_WITHDRAWAL_RETRIES = 3;

//  /// @notice Invoice has been created but no payment has been made yet.
//     uint8 public constant CREATED = 1;

//     /// @notice Invoice has been paid by the buyer.
//     uint8 public constant PAID = 2;

//     /// @notice Invoice has been refunded to the buyer.
//     uint8 public constant REFUNDED = 3;

//     /// @notice Seller has canceled the invoice.
//     uint8 public constant CANCELED = 4;

//     /// @notice Buyer has raised a dispute.
//     uint8 public constant DISPUTED = 5;

//     /// @notice Dispute has been resolved in full favor of both parties.
//     uint8 public constant DISPUTE_RESOLVED = 6;

//     /// @notice Dispute has been dismissed without changes to payouts.
//     uint8 public constant DISPUTE_DISMISSED = 7;

//     /// @notice Dispute has been settled with a split payout.
//     uint8 public constant DISPUTE_SETTLED = 8;

//     /// @notice Payment has been released to the seller after acceptance or resolution.
//     uint8 public constant RELEASED = 9;

//     /// @notice Invoice is permanently locked after all automated withdrawal retries (seller + buyer) failed.
//     uint8 public constant LOCKED = 10;

//     /// @notice Total basis points used for percentage calculations. 10_000 = 100%.
//     uint256 public constant BASIS_POINTS = 10_000;

//     /// @notice Default number of decimals used for internal fixed-point arithmetic (e.g., 1e18 = 1.0)
//     uint8 public constant DEFAULT_DECIMAL = 18;

//     /// @notice Minimum invoice price applied when none is explicitly set (1 USD in 8-decimal Chainlink format).
//     uint256 public constant DEFAULT_MINIMUM_INVOICE_PRICE = 1e8;

//     /// @notice Maximum number of automated seller-payout retry attempts before falling back to a buyer refund.
//     uint8 public constant MAX_WITHDRAWAL_RETRIES = 3;
