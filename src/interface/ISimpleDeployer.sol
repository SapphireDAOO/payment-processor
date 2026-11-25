// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { IAuthorizedAddressProvider, IPendingProcessorProvider } from "./IDeploymentProviders.sol";

/**
 * @title ISimpleDeployer
 * @notice Deploys the SimplePaymentProcessor with its Notes and PaymentAutomation via CREATE2.
 * @dev The processor holds both addresses as immutables, so they are predicted before it is deployed.
 */
interface ISimpleDeployer is IAuthorizedAddressProvider, IPendingProcessorProvider {
    /// @notice Thrown when {deploy} is called by an address other than the deployer.
    error NotDeployer();

    /// @notice Thrown when {deploy} is called again.
    error AlreadyDeployed();

    /// @notice Thrown when a contract lands away from the address the processor was built against.
    error AddressMismatch(address predicted, address deployed);

    /// @notice Emitted once the Simple processor and its dependencies are deployed.
    event Deployed(address simplePaymentProcessor, address paymentAutomation, address notes);

    /**
     * @param salt CREATE2 salt.
     * @param ppStorage The deployed PaymentProcessorStorage.
     * @param escrowHoldPeriod Seconds an escrow holds a payment before release.
     * @param forwarder CRE forwarder allowed to deliver reports to PaymentAutomation.
     * @param workflowOwner CRE workflow owner carried in report metadata.
     */
    struct Params {
        bytes32 salt;
        address ppStorage;
        uint32 escrowHoldPeriod;
        address forwarder;
        address workflowOwner;
    }

    /// @notice Creation code (without constructor args), passed in to keep the deployer under EIP-170.
    struct InitCodes {
        bytes notes;
        bytes simplePaymentProcessor;
        bytes paymentAutomation;
    }

    /**
     * @notice Deploys the SimplePaymentProcessor, its PaymentAutomation, and Notes. Callable once, by the deployer.
     * @return simplePaymentProcessor The deployed processor.
     */
    function deploy(Params calldata _params, InitCodes calldata _initCodes)
        external
        returns (address simplePaymentProcessor);
}
