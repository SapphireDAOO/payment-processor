// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { PaymentAutomation } from "../../src/PaymentAutomation.sol";
import { BaseSetUp } from "./BaseSetUp.sol";

abstract contract SimplePaymentProcessorSetUp is BaseSetUp {
    SimplePaymentProcessor simplePP;
    PaymentAutomation automation;

    address constant FORWARDER_TWO = address(0xb0);
    address constant WORKFLOW_OWNER = address(0xc0ffee);

    /// @notice Initializes the base setup, which deploys and wires the simple payment processor.
    function setUp() public virtual {
        initialize();
    }

    /// @dev Deploys the processor against the predicted storage address so it can be authorized at
    ///      storage construction. The automation adapter needs no authorization — it only calls
    ///      `processDueTasks` on the processor.
    function _deployAuthorized(address _predictedStorage, address _notesAddress) internal virtual override {
        super._deployAuthorized(_predictedStorage, _notesAddress);

        address predictedAutomation = vm.computeCreate2Address(
            TEST_SALT,
            keccak256(
                abi.encodePacked(
                    type(PaymentAutomation).creationCode, abi.encode(_predictedStorage, FORWARDER_TWO, WORKFLOW_OWNER)
                )
            ),
            address(this)
        );

        simplePP =
            new SimplePaymentProcessor(_predictedStorage, _notesAddress, predictedAutomation, TEST_ESCROW_HOLD_PERIOD);
        pendingProcessorAddress = address(simplePP);
        automation = new PaymentAutomation{ salt: TEST_SALT }(_predictedStorage, FORWARDER_TWO, WORKFLOW_OWNER);
        require(address(automation) == predictedAutomation, "automation deployed away from prediction");
        _authorize(address(simplePP));
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
