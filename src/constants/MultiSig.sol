// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

// Transaction has been proposed and is collecting approvals.
uint8 constant PROPOSED = 1;

// Approval count reached the threshold; execution still re-checks that the approvers are current signers.
uint8 constant APPROVED = 2;

// Transaction has been executed; the encoded call was forwarded to its target.
uint8 constant EXECUTED = 3;

// Transaction was canceled by a multisig-executed `cancelTransaction` and can no longer execute.
uint8 constant CANCELED = 4;

// Smallest signer set the multisig allows.
uint8 constant MINIMUM_SIGNERS = 2;
