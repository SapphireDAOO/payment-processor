// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { ISimpleDeployer } from "./interface/ISimpleDeployer.sol";
import { SimplePaymentProcessor } from "./SimplePaymentProcessor.sol";
import { PaymentAutomation } from "./PaymentAutomation.sol";
import { Notes } from "./Notes.sol";

/**
 * @title SimpleDeployer
 * @notice Deploys the SimplePaymentProcessor, its PaymentAutomation, and Notes in one transaction.
 */
contract SimpleDeployer is ISimpleDeployer {
    /// @notice The only address allowed to call {deploy}.
    address public immutable DEPLOYER;

    /// @notice The deployed Notes.
    Notes public notes;

    /// @notice The deployed SimplePaymentProcessor.
    SimplePaymentProcessor public simplePaymentProcessor;

    /// @notice The deployed PaymentAutomation.
    PaymentAutomation public paymentAutomation;

    /// @dev Read by Notes' constructor, then cleared.
    address[] private pendingAuthorized;

    /// @param _deployer The deployer address; passed explicitly since this is deployed through a CREATE2 factory.
    constructor(address _deployer) {
        DEPLOYER = _deployer;
    }

    /// @inheritdoc ISimpleDeployer
    function deploy(Params calldata _params, InitCodes calldata _initCodes)
        external
        returns (address simplePaymentProcessorAddress)
    {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (address(simplePaymentProcessor) != address(0)) revert AlreadyDeployed();

        bytes memory notesInitCode = abi.encodePacked(_initCodes.notes, abi.encode(_params.ppStorage));
        bytes memory automationInitCode = abi.encodePacked(
            _initCodes.paymentAutomation, abi.encode(_params.ppStorage, _params.forwarder, _params.workflowOwner)
        );
        address notesAddress = Create2.computeAddress(_params.salt, keccak256(notesInitCode));
        address automationAddress = Create2.computeAddress(_params.salt, keccak256(automationInitCode));

        simplePaymentProcessor = SimplePaymentProcessor(
            payable(Create2.deploy(
                    0,
                    _params.salt,
                    abi.encodePacked(
                        _initCodes.simplePaymentProcessor,
                        abi.encode(_params.ppStorage, notesAddress, automationAddress, _params.escrowHoldPeriod)
                    )
                ))
        );

        paymentAutomation = PaymentAutomation(Create2.deploy(0, _params.salt, automationInitCode));
        if (address(paymentAutomation) != automationAddress) {
            revert AddressMismatch(automationAddress, address(paymentAutomation));
        }

        pendingAuthorized.push(address(simplePaymentProcessor));
        pendingAuthorized.push(DEPLOYER);
        notes = Notes(Create2.deploy(0, _params.salt, notesInitCode));
        delete pendingAuthorized;
        if (address(notes) != notesAddress) revert AddressMismatch(notesAddress, address(notes));

        emit Deployed(address(simplePaymentProcessor), address(paymentAutomation), address(notes));

        simplePaymentProcessorAddress = address(simplePaymentProcessor);
    }

    /// @notice The addresses Notes authorizes while it is being constructed.
    function authorizedAddresses() external view returns (address[] memory authorized) {
        authorized = pendingAuthorized;
    }

    /// @notice The processor PaymentAutomation drives while it is being constructed.
    function pendingProcessor() external view returns (address processor) {
        processor = address(simplePaymentProcessor);
    }
}
