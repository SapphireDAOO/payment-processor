// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Source tag emitted with `DueTasksProcessed` when the queue is drained by a Chainlink CRE report.
bytes32 constant CRE_SOURCE = keccak256("CRE");

// Source tag emitted with `DueTasksProcessed` when the queue is drained through the Gelato exec entrypoint.
bytes32 constant GELATO_SOURCE = keccak256("GELATO");
