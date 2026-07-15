// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { IAuthorizedAddressProvider, IMasterDeployer } from "./interface/IMasterDeployer.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";
import { SimplePaymentProcessor } from "./SimplePaymentProcessor.sol";
import { IntermediatedPaymentProcessor } from "./IntermediatedPaymentProcessor.sol";
import { OracleManager } from "./OracleManager.sol";
import { Notes } from "./Notes.sol";
import { MultiSig } from "./MultiSig.sol";

/**
 * @title MasterDeployer
 * @notice Deploys the full payment processor system deterministically via CREATE2.
 * @dev See {IMasterDeployer} for the deployment flow and address-prediction scheme.
 */
contract MasterDeployer is IMasterDeployer {
    /// @notice The only address allowed to trigger the deployment.
    address public immutable deployer;

    /// @notice The deployed MultiSig.
    MultiSig public multiSig;

    /// @notice The deployed PaymentProcessorStorage.
    PaymentProcessorStorage public ppStorage;

    /// @notice The deployed Notes contract.
    Notes public notes;

    /// @notice The deployed SimplePaymentProcessor.
    SimplePaymentProcessor public simplePaymentProcessor;

    /// @notice The deployed OracleManager.
    OracleManager public oracleManager;

    /// @notice The deployed IntermediatedPaymentProcessor.
    IntermediatedPaymentProcessor public intermediatedPaymentProcessor;

    /// @dev Read back by PaymentProcessorStorage's constructor; only populated during {deployAll}.
    address[] private pendingAuthorized;

    /**
     * @notice Sets the address allowed to run the deployment.
     * @param _deployer The deployer address. Passed explicitly because this contract is itself
     *        deployed via a CREATE2 factory, so `msg.sender` here is the factory.
     */
    constructor(address _deployer) {
        deployer = _deployer;
    }

    /// @inheritdoc IAuthorizedAddressProvider
    function authorizedAddresses() external view returns (address[] memory authorized) {
        authorized = pendingAuthorized;
    }

    /// @inheritdoc IMasterDeployer
    function predictStorageAddress(
        bytes32 _salt,
        IPaymentProcessorStorage.Configuration memory _config,
        bytes memory _ppStorageCreationCode
    ) public view returns (address predicted) {
        predicted = Create2.computeAddress(_salt, keccak256(_storageInitCode(_ppStorageCreationCode, _config)));
    }

    /// @inheritdoc IMasterDeployer
    function deployAll(Params calldata _params, InitCodes calldata _initCodes)
        external
        returns (address ppStorageAddress)
    {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(ppStorage) != address(0)) revert AlreadyDeployed();

        address predicted = predictStorageAddress(_params.salt, _params.config, _initCodes.ppStorage);

        multiSig = MultiSig(
            Create2.deploy(
                0,
                _params.salt,
                abi.encodePacked(_initCodes.multiSig, abi.encode(_params.multiSigSigners, _params.multiSigThreshold))
            )
        );

        notes = Notes(Create2.deploy(0, _params.salt, abi.encodePacked(_initCodes.notes, abi.encode(predicted))));

        simplePaymentProcessor = SimplePaymentProcessor(
            Create2.deploy(
                0,
                _params.salt,
                abi.encodePacked(
                    _initCodes.simplePaymentProcessor,
                    abi.encode(predicted, _params.minimumInvoiceValue, address(notes))
                )
            )
        );

        oracleManager = OracleManager(
            Create2.deploy(
                0,
                _params.salt,
                abi.encodePacked(_initCodes.oracleManager, abi.encode(predicted, _params.sequencerUptimeFeed))
            )
        );

        intermediatedPaymentProcessor = IntermediatedPaymentProcessor(
            Create2.deploy(
                0,
                _params.salt,
                abi.encodePacked(_initCodes.intermediatedPaymentProcessor, abi.encode(predicted, address(oracleManager)))
            )
        );

        pendingAuthorized.push(address(simplePaymentProcessor));
        pendingAuthorized.push(address(intermediatedPaymentProcessor));

        ppStorage = PaymentProcessorStorage(
            Create2.deploy(0, _params.salt, _storageInitCode(_initCodes.ppStorage, _params.config))
        );

        // Authorization is only available during deployment.
        delete pendingAuthorized;

        if (address(ppStorage) != predicted) revert StorageAddressMismatch(predicted, address(ppStorage));

        emit SystemDeployed(
            address(multiSig),
            address(ppStorage),
            address(notes),
            address(simplePaymentProcessor),
            address(oracleManager),
            address(intermediatedPaymentProcessor)
        );

        ppStorageAddress = address(ppStorage);
    }

    /// @dev PaymentProcessorStorage init code: creation code plus the abi-encoded configuration.
    function _storageInitCode(bytes memory _creationCode, IPaymentProcessorStorage.Configuration memory _config)
        private
        pure
        returns (bytes memory initCode)
    {
        initCode = abi.encodePacked(_creationCode, abi.encode(_config));
    }
}
