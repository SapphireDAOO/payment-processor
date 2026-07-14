// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title Chainlink CRE Receiver Interface
 * @notice Interface for contracts that consume reports delivered by Chainlink CRE workflows.
 * @dev The CRE (Keystone) Forwarder verifies the DON signatures on offchain-produced reports, then
 *      delivers them by calling `onReport` on the receiver. The forwarder uses ERC-165 to confirm
 *      the receiver implements this interface before delivery.
 * @custom:source https://github.com/smartcontractkit/chainlink-evm/blob/develop/contracts/src/v0.8/keystone/interfaces/IReceiver.sol
 */
interface IReceiver is IERC165 {
    /**
     * @notice Handles a verified report delivered by the CRE forwarder.
     * @param _metadata Workflow identity data: workflowId (32 bytes), workflowName (10 bytes),
     *        workflowOwner (20 bytes), and reportId (2 bytes), tightly packed.
     * @param _report The ABI-encoded report payload produced by the workflow.
     */
    function onReport(bytes calldata _metadata, bytes calldata _report) external;
}
