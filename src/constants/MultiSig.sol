// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Transaction has been proposed and is awaiting sufficient approvals.
uint8 constant PROPOSED = 1;

// Transaction has received enough approvals to meet the threshold and is ready for execution.
uint8 constant APPROVED = 2;

// Transaction has been executed; the encoded call was forwarded to the target payment processor.
uint8 constant EXECUTED = 3;

uint8 constant CANCELED = 4;

uint8 constant MINIMUM_THRESHOLD = 2;

uint8 constant MINIMUM_SIGNERS = 2;
