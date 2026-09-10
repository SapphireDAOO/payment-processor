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
 *      processors authorized.
 *
 *      Deployment runs in two transactions, {deployCore} then {deploySystem}, because deploying
 *      all eight contracts at once needs ~15.6M gas and RPC providers reject a transaction whose
 *      gas limit exceeds 16,777,216. The two heaviest contracts (SimplePaymentProcessor and
 *      IntermediatedPaymentProcessor) are split across the two calls to keep each well clear of
 *      that ceiling. The pending authorization list spans both calls and is cleared by
 *      {deploySystem}; once it completes, authorization on the storage contract can never change.
 */
interface IMasterDeployer is IAuthorizedAddressProvider {
    /// @notice Thrown when `deployAll` is called by an address other than the deployer.
    error NotDeployer();

    /// @notice Thrown when a deployment phase that has already run is called again.
    error AlreadyDeployed();

    /// @notice Thrown when `deploySystem` is called before `deployCore`.
    error CoreNotDeployed();

    /**
     * @notice Thrown when the deployed storage address does not match the prediction.
     * @param predicted The predicted PaymentProcessorStorage address.
     * @param deployed The address the contract was actually deployed at.
     */
    error StorageAddressMismatch(address predicted, address deployed);

    /**
     * @notice Emitted once the first deployment phase completes.
     * @param multiSig The deployed MultiSig address.
     * @param notes The deployed Notes address.
     * @param simplePaymentProcessor The deployed SimplePaymentProcessor address.
     * @param paymentAutomation The deployed PaymentAutomation adapter address.
     */
    event CoreDeployed(address multiSig, address notes, address simplePaymentProcessor, address paymentAutomation);

    /**
     * @notice Emitted once the full system has been deployed.
     * @param multiSig The deployed MultiSig address.
     * @param ppStorage The deployed PaymentProcessorStorage address.
     * @param notes The deployed Notes address.
     * @param simplePaymentProcessor The deployed SimplePaymentProcessor address.
     * @param paymentAutomation The deployed PaymentAutomation adapter address.
     * @param oracleManager The deployed OracleManager address.
     * @param intermediatedPaymentProcessor The deployed IntermediatedPaymentProcessor address.
     * @param sweeper The deployed Sweeper address.
     */
    event SystemDeployed(
        address multiSig,
        address ppStorage,
        address notes,
        address simplePaymentProcessor,
        address paymentAutomation,
        address oracleManager,
        address intermediatedPaymentProcessor,
        address sweeper
    );

    /**
     * @notice Parameters for the full system deployment.
     * @param salt The CREATE2 salt used for every deployment.
     * @param config The initial PaymentProcessorStorage configuration.
     * @param minimumInvoiceValue Minimum invoice value (in wei) for the SimplePaymentProcessor.
     * @param weth Wrapped native token the SimplePaymentProcessor pays platform fees in.
     * @param sequencerUptimeFeed Chainlink sequencer uptime feed; address(0) disables the check.
     * @param multiSigSigners Initial MultiSig signers.
     * @param multiSigThreshold Initial MultiSig approval threshold.
     */
    struct Params {
        bytes32 salt;
        IPaymentProcessorStorage.Configuration config;
        uint256 minimumInvoiceValue;
        address weth;
        address sequencerUptimeFeed;
        address[] multiSigSigners;
        uint256 multiSigThreshold;
    }

    /**
     * @notice Creation code (without constructor args) for the contracts {deployCore} deploys.
     * @dev Supplied by the caller so the deployer contract does not embed the system's bytecode,
     *      which would put it far past the EIP-170 size limit. The deployer appends the
     *      abi-encoded constructor args itself.
     * @param multiSig MultiSig creation code.
     * @param notes Notes creation code.
     * @param simplePaymentProcessor SimplePaymentProcessor creation code.
     * @param paymentAutomation PaymentAutomation creation code.
     * @param ppStorage PaymentProcessorStorage creation code. Not deployed in this phase; it is
     *        needed to predict the storage address the other contracts are constructed against.
     */
    struct CoreInitCodes {
        bytes multiSig;
        bytes notes;
        bytes simplePaymentProcessor;
        bytes paymentAutomation;
        bytes ppStorage;
    }

    /**
     * @notice Creation code (without constructor args) for the contracts {deploySystem} deploys.
     * @param oracleManager OracleManager creation code.
     * @param intermediatedPaymentProcessor IntermediatedPaymentProcessor creation code.
     * @param sweeper Sweeper creation code.
     * @param ppStorage PaymentProcessorStorage creation code. Must match the one passed to
     *        {deployCore}, otherwise the storage contract lands away from the predicted address
     *        and the call reverts with `StorageAddressMismatch`.
     */
    struct SystemInitCodes {
        bytes oracleManager;
        bytes intermediatedPaymentProcessor;
        bytes sweeper;
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
     * @notice First deployment phase: MultiSig, Notes, SimplePaymentProcessor and PaymentAutomation.
     * @dev Callable once, by the deployer only. Records the predicted PaymentProcessorStorage
     *      address for {deploySystem} to reuse, so both phases construct against the same address.
     * @param _params The deployment parameters.
     * @param _initCodes The creation code of each contract this phase needs.
     * @return predictedStorageAddress The address PaymentProcessorStorage will be deployed at.
     */
    function deployCore(Params calldata _params, CoreInitCodes calldata _initCodes)
        external
        returns (address predictedStorageAddress);

    /**
     * @notice Second deployment phase: OracleManager, IntermediatedPaymentProcessor, Sweeper, and
     *         finally PaymentProcessorStorage at its predicted address with both processors authorized.
     * @dev Callable once, by the deployer only, and only after {deployCore}. Ownership of the storage
     *      contract is left with `_params.config.owner`; post-deploy wiring (notes authorization,
     *      registering the automation adapter on the Simple processor, price feeds, ownership transfer
     *      to the MultiSig) is the deployer's responsibility.
     * @param _params The deployment parameters. Must match those passed to {deployCore}.
     * @param _initCodes The creation code of each contract this phase needs.
     * @return ppStorageAddress The deployed PaymentProcessorStorage address.
     */
    function deploySystem(Params calldata _params, SystemInitCodes calldata _initCodes)
        external
        returns (address ppStorageAddress);
}
