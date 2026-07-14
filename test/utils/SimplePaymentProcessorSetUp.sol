// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { BaseSetUp } from "./BaseSetUp.sol";
import { Notes } from "src/Notes.sol";

abstract contract SimplePaymentProcessorSetUp is BaseSetUp {
    SimplePaymentProcessor simplePP;
    uint256 constant MINIMUM_INVOICE_VALUE = 1 ether;

    address constant FORWARDER_TWO = address(0xb0);
    address constant WORKFLOW_OWNER = address(0xc0ffee);

    /// @notice Initializes the base setup and deploys the simple payment processor.
    function setUp() public virtual {
        (address storageAddress, address notesAddress) = initialize();
        _simplePaymentProcessorSetUp(storageAddress, notesAddress);
    }

    /**
     * @notice Deploys and configures the SimplePaymentProcessor for tests.
     * @param _storageAddress The PaymentProcessorStorage address.
     * @param _notesAddress The Notes contract address.
     * @return simplePaymentProcessor The deployed processor instance.
     */
    function _simplePaymentProcessorSetUp(address _storageAddress, address _notesAddress)
        internal
        virtual
        returns (SimplePaymentProcessor simplePaymentProcessor)
    {
        vm.startPrank(admin);
        simplePP = new SimplePaymentProcessor(_storageAddress, MINIMUM_INVOICE_VALUE, _notesAddress);

        PaymentProcessorStorage(_storageAddress).setAuthorizedAddress(address(simplePP), true);
        Notes(_notesAddress).setAuthorized(address(simplePP), true);
        vm.stopPrank();

        vm.startPrank(_storageAddress);
        simplePP.setForwarderAddress(FORWARDER_TWO);
        simplePP.setWorkflowOwner(WORKFLOW_OWNER);
        vm.stopPrank();

        simplePaymentProcessor = simplePP;
    }

    /**
     * @notice Builds CRE report metadata carrying the given workflow owner.
     * @param _workflowOwner The workflow owner address to embed in the metadata.
     * @return metadata Tightly packed metadata: workflowId, workflowName, workflowOwner, reportId.
     */
    function _workflowMetadata(address _workflowOwner) internal pure returns (bytes memory metadata) {
        metadata = abi.encodePacked(bytes32(0), bytes10("invoices"), _workflowOwner, bytes2(0));
    }
}
