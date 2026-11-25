// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

// Invoice has been created but no payment has been made yet.
uint8 constant CREATED = 1;

// Invoice has been paid by the buyer.
uint8 constant PAID = 2;

// Invoice has been refunded to the buyer.
uint8 constant REFUNDED = 3;

// The operator canceled the invoice before payment.
uint8 constant CANCELED = 4;

// The operator opened a dispute on a paid invoice.
uint8 constant DISPUTED = 5;

// Buyer and seller agreed; the invoice is releasable to the seller.
uint8 constant DISPUTE_RESOLVED = 6;

// Dispute has been dismissed without changes to payouts; the invoice is releasable again.
uint8 constant DISPUTE_DISMISSED = 7;

// Dispute has been settled with a split payout.
uint8 constant DISPUTE_SETTLED = 8;

// Dispute lapsed without a resolution; the invoice is releasable again.
uint8 constant DISPUTE_EXPIRED = 9;

// Payment has been released to the seller.
uint8 constant RELEASED = 10;

// Total basis points used for percentage calculations. 10_000 = 100%.
uint256 constant BASIS_POINTS = 10_000;

// Default number of decimals used for internal fixed-point arithmetic (e.g., 1e18 = 1.0).
uint8 constant DEFAULT_DECIMAL = 18;

// Smallest invoice price accepted (1 USD in 8-decimal Chainlink format).
uint256 constant DEFAULT_MINIMUM_INVOICE_PRICE = 1e8;
