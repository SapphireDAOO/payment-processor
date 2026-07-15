// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { BaseSetUp } from "./BaseSetUp.sol";
import { Notes } from "src/Notes.sol";

abstract contract SimplePaymentProcessorSetUp is BaseSetUp {
    SimplePaymentProcessor simplePP;
    uint256 constant MINIMUM_INVOICE_VALUE = 1 ether;

    address constant FORWARDER_TWO = address(0xb0);
    address constant WORKFLOW_OWNER = address(0xc0ffee);

    /// @notice Initializes the base setup and wires the simple payment processor.
    function setUp() public virtual {
        (address storageAddress, address notesAddress) = initialize();
        _simplePaymentProcessorSetUp(storageAddress, notesAddress);
    }

    /// @dev Deploys the processor against the predicted storage address so it can be authorized at
    ///      storage construction.
    function _deployAuthorized(address _predictedStorage, address _notesAddress) internal virtual override {
        super._deployAuthorized(_predictedStorage, _notesAddress);
        simplePP = new SimplePaymentProcessor(_predictedStorage, MINIMUM_INVOICE_VALUE, _notesAddress);
        _authorize(address(simplePP));
    }

    /**
     * @notice Configures the SimplePaymentProcessor deployed during {initialize}.
     * @param _storageAddress The PaymentProcessorStorage address.
     * @param _notesAddress The Notes contract address.
     * @return simplePaymentProcessor The configured processor instance.
     */
    function _simplePaymentProcessorSetUp(address _storageAddress, address _notesAddress)
        internal
        virtual
        returns (SimplePaymentProcessor simplePaymentProcessor)
    {
        vm.prank(admin);
        Notes(_notesAddress).setAuthorized(address(simplePP), true);

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
