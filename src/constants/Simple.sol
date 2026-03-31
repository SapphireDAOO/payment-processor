// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Status code representing that an invoice has been created and is awaiting payment.
uint8 constant CREATED = 1;

// Status code representing that an invoice has been paid by the buyer.
uint8 constant PAID = 2;

// Status code representing that a payment has been accepted by the seller.
uint8 constant ACCEPTED = 3;

// Status code representing that a payment has been rejected by the seller.
uint8 constant REJECTED = 4;

// Status code representing that an invoice has been canceled by the seller.
uint8 constant CANCELED = 5;

// Status code representing that a payment has been refunded to the payer.
uint8 constant REFUNDED = 6;

// Status code representing that a payment has been successfully released to the seller.
uint8 constant RELEASED = 7;

// Status code representing that an invoice is permanently locked after all automated withdrawal retries failed.
uint8 constant LOCKED = 8;

// Basis points denominator used for percentage calculations (1% = 100).
uint256 constant BASIS_POINTS = 10_000;

// Default decision period for the seller after an invoice is paid.
uint256 constant SELLER_DEFAULT_DECISION_WINDOW = 6 hours;

// Maximum number of automated withdrawal retry attempts before falling back.
uint8 constant MAX_WITHDRAWAL_RETRIES = 3;
