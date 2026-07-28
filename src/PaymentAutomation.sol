// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentAutomation } from "./interface/IPaymentAutomation.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";
import { IERC165, IReceiver } from "./interface/IReceiver.sol";
import { ISimplePaymentProcessor } from "./interface/ISimplePaymentProcessor.sol";

import { CRE_SOURCE, GELATO_SOURCE } from "./constants/Automation.sol";

/**
 * @title PaymentAutomation
 * @notice Keeper adapter that triggers automated release and refund of due invoices on the payment processor.
 * @dev Owns no queue, no invoice state and no funds. The scheduling heap and every state transition stay in
 *      {SimplePaymentProcessor}; this contract only reads `hasDueTasks()` and calls `processDueTasks()`,
 *      wrapping that pair in the entrypoints two keeper networks expect:
 *      - Chainlink CRE: `onReport`, called by the Keystone forwarder with a DON-signed report. The forwarder
 *        confirms this contract advertises {IReceiver} over ERC-165 before delivering.
 *      - Gelato Web3 Functions: `checker`, polled offchain, which names {processDueTasks} as the exec target.
 *      Only one keeper network is meant to be active at a time; the second is redundancy, to be switched on
 *      if the primary stalls or is decommissioned. Both paths converge on the same processor call, so running
 *      both at once is still safe — whichever fires first drains the queue and the other finds nothing due.
 *      The processor must be pointed back at this contract via `setAutomation` for either path to work.
 */
contract PaymentAutomation is IPaymentAutomation, IReceiver {
    /// @notice The payment processor whose due-task queue this contract drives.
    ISimplePaymentProcessor public immutable processor;

    /// @notice Reference to the external Payment Processor storage contract, used for owner checks.
    IPaymentProcessorStorage public immutable ppStorage;

    /// @notice Address of the CRE (Keystone) forwarder contract responsible for delivering workflow reports via `onReport`.
    address private forwarder;

    /// @notice Owner address of the CRE workflow authorized to trigger `onReport`, as reported in the report metadata.
    address private workflowOwner;

    /**
     * @notice Restricts access to the payment processor owner or storage contract.
     * @dev Reverts with NotAuthorized if the caller is not permitted.
     */
    modifier onlyAuthorized() {
        _isAuthorized();
        _;
    }

    /**
     * @notice Wires the adapter to the processor it drives and the storage contract it reads the owner from.
     * @dev Both addresses are immutable; redeploy and re-point the processor via `setAutomation` to change them.
     * @param _processorAddress The SimplePaymentProcessor address whose due tasks are processed.
     * @param _paymentProcessorStorageAddress The address of the shared payment processor storage contract.
     */
    constructor(address _processorAddress, address _paymentProcessorStorageAddress) {
        if (_processorAddress == address(0) || _paymentProcessorStorageAddress == address(0)) revert InvalidAddress();

        processor = ISimplePaymentProcessor(_processorAddress);
        ppStorage = IPaymentProcessorStorage(_paymentProcessorStorageAddress);
    }

    /**
     * @notice Handles a verified report delivered by the CRE forwarder and processes due invoice tasks.
     * @dev The report payload is ignored; delivery of a verified report is itself the trigger.
     *      Reverts with NotAuthorized if the caller is not the configured forwarder, and with
     *      UnauthorizedWorkflowOwner if the metadata does not carry the authorized workflow owner.
     * @inheritdoc IReceiver
     */
    function onReport(bytes calldata _metadata, bytes calldata) external {
        if (msg.sender != forwarder) {
            revert NotAuthorized();
        }

        address reportedWorkflowOwner = _decodeWorkflowOwner(_metadata);
        if (reportedWorkflowOwner != workflowOwner) {
            revert UnauthorizedWorkflowOwner(reportedWorkflowOwner);
        }

        processor.processDueTasks();

        emit DueTasksProcessed(msg.sender, CRE_SOURCE);
    }

    /// @inheritdoc IPaymentAutomation
    function processDueTasks() external {
        processor.processDueTasks();

        emit DueTasksProcessed(msg.sender, GELATO_SOURCE);
    }

    /// @inheritdoc IPaymentAutomation
    function checker() external view returns (bool canExec, bytes memory execPayload) {
        canExec = processor.hasDueTasks();
        execPayload = abi.encodeCall(IPaymentAutomation.processDueTasks, ());
    }

    /// @inheritdoc IPaymentAutomation
    function hasDueTasks() external view returns (bool dueTasksExist) {
        return processor.hasDueTasks();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 _interfaceId) external pure returns (bool supported) {
        return _interfaceId == type(IReceiver).interfaceId || _interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IPaymentAutomation
    function setForwarderAddress(address _forwarderAddress) external onlyAuthorized {
        forwarder = _forwarderAddress;
        emit ForwarderUpdated(_forwarderAddress);
    }

    /// @inheritdoc IPaymentAutomation
    function setWorkflowOwner(address _workflowOwner) external onlyAuthorized {
        workflowOwner = _workflowOwner;
        emit WorkflowOwnerUpdated(_workflowOwner);
    }

    /// @inheritdoc IPaymentAutomation
    function getForwarder() external view returns (address forwarderAddress) {
        return forwarder;
    }

    /// @inheritdoc IPaymentAutomation
    function getWorkflowOwner() external view returns (address workflowOwnerAddress) {
        return workflowOwner;
    }

    /**
     * @notice Extracts the workflow owner address from CRE report metadata.
     * @dev Metadata layout (tightly packed): workflowId (32 bytes), workflowName (10 bytes),
     *      workflowOwner (20 bytes), reportId (2 bytes). Reads past the end of short metadata
     *      yield zero bytes, so malformed metadata decodes to an address that fails the
     *      `onReport` owner check rather than reverting here.
     * @param _metadata The report metadata delivered by the forwarder.
     * @return reportedWorkflowOwner The workflow owner address carried in the metadata.
     */
    function _decodeWorkflowOwner(bytes calldata _metadata) internal pure returns (address reportedWorkflowOwner) {
        assembly {
            // workflowOwner starts at byte 42 (after 32-byte workflowId and 10-byte workflowName);
            // load 32 bytes and shift right so the 20-byte address occupies the low bits.
            reportedWorkflowOwner := shr(96, calldataload(add(_metadata.offset, 42)))
        }
    }

    /**
     * @notice Validates that the caller is the contract owner or the PaymentProcessorStorage contract.
     * @dev Reverts with NotAuthorized if neither condition is met.
     */
    function _isAuthorized() internal view {
        if (msg.sender != _owner() && msg.sender != address(ppStorage)) {
            revert NotAuthorized();
        }
    }

    /**
     * @notice Returns the owner of the PaymentProcessorStorage contract.
     * @dev This helper reads the owner directly from the linked PaymentProcessorStorage instance.
     * @return ownerAddress The address that currently owns the PaymentProcessorStorage contract.
     */
    function _owner() internal view returns (address ownerAddress) {
        ownerAddress = PaymentProcessorStorage(address(ppStorage)).owner();
    }
}
