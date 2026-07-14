// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Invoice has been created but no payment has been made yet.
uint8 constant CREATED = 1;

// Invoice has been paid by the buyer.
uint8 constant PAID = 2;

// Invoice has been refunded to the buyer.
uint8 constant REFUNDED = 3;

// Seller has canceled the invoice.
uint8 constant CANCELED = 4;

// Buyer has raised a dispute.
uint8 constant DISPUTED = 5;

// Dispute has been resolved in full favor of both parties.
uint8 constant DISPUTE_RESOLVED = 6;

// Dispute has been dismissed without changes to payouts.
uint8 constant DISPUTE_DISMISSED = 7;

// Dispute has been settled with a split payout.
uint8 constant DISPUTE_SETTLED = 8;

// Payment has been released to the seller after acceptance or resolution.
uint8 constant RELEASED = 9;

// Invoice is permanently locked after all automated withdrawal retries (seller + buyer) failed.
uint8 constant LOCKED = 10;

// Total basis points used for percentage calculations. 10_000 = 100%.
uint256 constant BASIS_POINTS = 10_000;

// Default number of decimals used for internal fixed-point arithmetic (e.g., 1e18 = 1.0).
uint8 constant DEFAULT_DECIMAL = 18;

// Minimum invoice price applied when none is explicitly set (1 USD in 8-decimal Chainlink format).
uint256 constant DEFAULT_MINIMUM_INVOICE_PRICE = 1e8;

// Maximum number of automated seller-payout retry attempts before falling back to a buyer refund.
uint8 constant MAX_WITHDRAWAL_RETRIES = 3;
