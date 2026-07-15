// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentProcessorStorage } from "./IPaymentProcessorStorage.sol";

/**
 * @title IAuthorizedAddressProvider
 * @notice Implemented by contracts that deploy PaymentProcessorStorage.
 * @dev PaymentProcessorStorage calls this on its deployer (`msg.sender`) during construction
 *      to fetch the addresses to authorize. Authorization can only be granted this way, at
 *      deployment time; no setter exists to change it afterwards.
 */
interface IAuthorizedAddressProvider {
    /**
     * @notice Returns the addresses PaymentProcessorStorage should authorize at construction.
     * @return authorized The list of addresses to authorize.
     */
    function authorizedAddresses() external view returns (address[] memory authorized);
}

/**
 * @title IMasterDeployer
 * @notice Deploys the full payment processor system deterministically via CREATE2.
 * @dev PaymentProcessorStorage's address is predicted upfront: its init code contains only the
 *      configuration (the authorized processors are fetched from the deployer via
 *      {IAuthorizedAddressProvider.authorizedAddresses} during its constructor), so the address
 *      is known before the processors exist. The processors are deployed first against the
 *      predicted address, then the storage contract is deployed at exactly that address with the
 *      processors authorized. The pending authorization list only exists for the duration of
 *      {deployAll}; once it completes, authorization on the storage contract can never change.
 */
interface IMasterDeployer is IAuthorizedAddressProvider {
    /// @notice Thrown when `deployAll` is called by an address other than the deployer.
    error NotDeployer();

    /// @notice Thrown when `deployAll` is called more than once.
    error AlreadyDeployed();

    /**
     * @notice Thrown when the deployed storage address does not match the prediction.
     * @param predicted The predicted PaymentProcessorStorage address.
     * @param deployed The address the contract was actually deployed at.
     */
    error StorageAddressMismatch(address predicted, address deployed);

    /**
     * @notice Emitted once the full system has been deployed.
     * @param multiSig The deployed MultiSig address.
     * @param ppStorage The deployed PaymentProcessorStorage address.
     * @param notes The deployed Notes address.
     * @param simplePaymentProcessor The deployed SimplePaymentProcessor address.
     * @param oracleManager The deployed OracleManager address.
     * @param intermediatedPaymentProcessor The deployed IntermediatedPaymentProcessor address.
     */
    event SystemDeployed(
        address multiSig,
        address ppStorage,
        address notes,
        address simplePaymentProcessor,
        address oracleManager,
        address intermediatedPaymentProcessor
    );

    /**
     * @notice Parameters for the full system deployment.
     * @param salt The CREATE2 salt used for every deployment.
     * @param config The initial PaymentProcessorStorage configuration.
     * @param minimumInvoiceValue Minimum invoice value (in wei) for the SimplePaymentProcessor.
     * @param sequencerUptimeFeed Chainlink sequencer uptime feed; address(0) disables the check.
     * @param multiSigSigners Initial MultiSig signers.
     * @param multiSigThreshold Initial MultiSig approval threshold.
     */
    struct Params {
        bytes32 salt;
        IPaymentProcessorStorage.Configuration config;
        uint256 minimumInvoiceValue;
        address sequencerUptimeFeed;
        address[] multiSigSigners;
        uint256 multiSigThreshold;
    }

    /**
     * @notice Creation code (without constructor args) for each contract in the system.
     * @dev Supplied by the caller so the deployer contract does not embed the system's bytecode,
     *      which would put it far past the EIP-170 size limit. The deployer appends the
     *      abi-encoded constructor args itself.
     * @param multiSig MultiSig creation code.
     * @param notes Notes creation code.
     * @param simplePaymentProcessor SimplePaymentProcessor creation code.
     * @param oracleManager OracleManager creation code.
     * @param intermediatedPaymentProcessor IntermediatedPaymentProcessor creation code.
     * @param ppStorage PaymentProcessorStorage creation code.
     */
    struct InitCodes {
        bytes multiSig;
        bytes notes;
        bytes simplePaymentProcessor;
        bytes oracleManager;
        bytes intermediatedPaymentProcessor;
        bytes ppStorage;
    }

    /**
     * @notice Predicts the PaymentProcessorStorage address for a given salt and configuration.
     * @param _salt The CREATE2 salt.
     * @param _config The storage configuration (part of the init code).
     * @param _ppStorageCreationCode PaymentProcessorStorage creation code without constructor args.
     * @return predicted The address PaymentProcessorStorage will be deployed at.
     */
    function predictStorageAddress(
        bytes32 _salt,
        IPaymentProcessorStorage.Configuration memory _config,
        bytes memory _ppStorageCreationCode
    ) external view returns (address predicted);

    /**
     * @notice Deploys the full system: MultiSig, Notes, SimplePaymentProcessor, OracleManager,
     *         IntermediatedPaymentProcessor, and finally PaymentProcessorStorage at its predicted
     *         address with both processors authorized.
     * @dev Callable once, by the deployer only. Ownership of the storage contract is left with
     *      `_params.config.owner`; post-deploy wiring (notes authorization, price feeds, ownership
     *      transfer to the MultiSig) is the deployer's responsibility.
     * @param _params The deployment parameters.
     * @param _initCodes The creation code of each contract to deploy.
     * @return ppStorageAddress The deployed PaymentProcessorStorage address.
     */
    function deployAll(Params calldata _params, InitCodes calldata _initCodes)
        external
        returns (address ppStorageAddress);
}
