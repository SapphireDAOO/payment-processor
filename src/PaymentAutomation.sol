// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentAutomation } from "./interface/IPaymentAutomation.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";
import { IERC165, IReceiver } from "./interface/IReceiver.sol";
import { ISimplePaymentProcessor } from "./interface/ISimplePaymentProcessor.sol";
import { IPendingProcessorProvider } from "./interface/IMasterDeployer.sol";

import { CRE_SOURCE, GELATO_SOURCE } from "./constants/Automation.sol";

/**
 * @title PaymentAutomation
 * @notice Keeper adapter that triggers automated release and refund of due invoices on the payment processor.
 * @dev Owns no queue, no invoice state and no funds — it only reads `hasDueTasks()` and calls
 *      `processDueTasks()` on {SimplePaymentProcessor}, behind two keeper entrypoints: `onReport`
 *      (Chainlink CRE) and `checker` (Gelato). Run one network at a time; the other is redundancy.
 *      The processor holds this adapter as an immutable, so changing the pairing means redeploying both.
 */
contract PaymentAutomation is IPaymentAutomation, IReceiver {
    /// @notice The payment processor whose due-task queue this contract drives.
    ISimplePaymentProcessor public immutable PROCESSOR;

    /// @notice Reference to the external Payment Processor storage contract, used for owner checks.
    IPaymentProcessorStorage public immutable PP_STORAGE;

    /// @notice Address of the CRE (Keystone) forwarder contract responsible for delivering workflow reports via `onReport`.
    address public immutable FORWARDER;

    /// @notice Owner address of the CRE workflow authorized to trigger `onReport`, as reported in the report metadata.
    address public immutable WORKFLOW_OWNER;

    /**
     * @notice Restricts access to the payment processor owner or storage contract.
     * @dev Reverts with NotAuthorized if the caller is not permitted.
     */
    modifier onlyAuthorized() {
        _isAuthorized();
        _;
    }

    /**
     * @notice Wires the adapter to the storage contract and the keeper identities it trusts.
     * @dev The processor is read back from the deployer via {IPendingProcessorProvider} rather than
     *      passed in, which keeps this contract's address predictable. Everything is immutable.
     * @param _paymentProcessorStorageAddress The address of the shared payment processor storage contract.
     * @param _forwarderAddress The CRE forwarder allowed to deliver reports to `onReport`.
     * @param _workflowOwner The CRE workflow owner carried in report metadata.
     */
    constructor(address _paymentProcessorStorageAddress, address _forwarderAddress, address _workflowOwner) {
        if (_paymentProcessorStorageAddress == address(0)) revert InvalidAddress();

        address processorAddress = IPendingProcessorProvider(msg.sender).pendingProcessor();
        if (processorAddress == address(0)) revert InvalidAddress();

        PROCESSOR = ISimplePaymentProcessor(processorAddress);
        PP_STORAGE = IPaymentProcessorStorage(_paymentProcessorStorageAddress);
        FORWARDER = _forwarderAddress;
        WORKFLOW_OWNER = _workflowOwner;
    }

    /**
     * @notice Handles a verified report delivered by the CRE forwarder and processes due invoice tasks.
     * @dev The report payload is ignored; delivery of a verified report is itself the trigger.
     *      Reverts with NotAuthorized if the caller is not the configured forwarder, and with
     *      UnauthorizedWorkflowOwner if the metadata does not carry the authorized workflow owner.
     * @inheritdoc IReceiver
     */
    function onReport(bytes calldata _metadata, bytes calldata) external {
        if (msg.sender != FORWARDER) {
            revert NotAuthorized();
        }

        address reportedWorkflowOwner = _decodeWorkflowOwner(_metadata);
        if (reportedWorkflowOwner != WORKFLOW_OWNER) {
            revert UnauthorizedWorkflowOwner(reportedWorkflowOwner);
        }

        PROCESSOR.processDueTasks();

        emit DueTasksProcessed(msg.sender, CRE_SOURCE);
    }

    /// @inheritdoc IPaymentAutomation
    function processDueTasks() external {
        PROCESSOR.processDueTasks();

        emit DueTasksProcessed(msg.sender, GELATO_SOURCE);
    }

    /// @inheritdoc IPaymentAutomation
    function checker() external view returns (bool canExec, bytes memory execPayload) {
        canExec = _hasDueTasks();
        execPayload = abi.encodeCall(IPaymentAutomation.processDueTasks, ());
    }

    /// @inheritdoc IPaymentAutomation
    function hasDueTasks() external view returns (bool dueTasksExist) {
        return _hasDueTasks();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 _interfaceId) external pure returns (bool supported) {
        return _interfaceId == type(IReceiver).interfaceId || _interfaceId == type(IERC165).interfaceId;
    }

    /**
     * @notice Extracts the workflow owner address from CRE report metadata.
     * @dev Metadata layout (tightly packed): workflowId (32 bytes), workflowName (10 bytes),
     *      workflowOwner (20 bytes), reportId (2 bytes). Short metadata reads as zero bytes and so
     *      fails the `onReport` owner check rather than reverting here.
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

    /// @dev A paused system rejects `processDueTasks`, so report no work rather than let keepers revert.
    function _hasDueTasks() internal view returns (bool dueTasksExist) {
        return !PP_STORAGE.isPaused() && PROCESSOR.hasDueTasks();
    }

    /**
     * @notice Validates that the caller is the contract owner or the PaymentProcessorStorage contract.
     * @dev Reverts with NotAuthorized if neither condition is met.
     */
    function _isAuthorized() internal view {
        if (msg.sender != _owner() && msg.sender != address(PP_STORAGE)) {
            revert NotAuthorized();
        }
    }

    /**
     * @notice Returns the owner of the PaymentProcessorStorage contract.
     * @dev This helper reads the owner directly from the linked PaymentProcessorStorage instance.
     * @return ownerAddress The address that currently owns the PaymentProcessorStorage contract.
     */
    function _owner() internal view returns (address ownerAddress) {
        ownerAddress = PaymentProcessorStorage(address(PP_STORAGE)).owner();
    }
}
