// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Notes } from "src/Notes.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { IAuthorizedAddressProvider } from "../../src/interface/IMasterDeployer.sol";
import { Test } from "forge-std/Test.sol";

abstract contract BaseSetUp is Test, IAuthorizedAddressProvider {
    PaymentProcessorStorage ppStorage;
    Notes notes;

    address internal admin = address(1);
    address internal buyerOne = address(2);
    address internal buyerTwo = address(3);
    address internal sellerOne = address(4);
    address internal sellerTwo = address(5);
    address internal feeReceiver = address(6);

    uint256 constant INITIAL_BALANCE = 100_000 ether;
    uint256 public constant FEE_RATE = 500;

    uint256 constant DEFAULT_HOLD_PERIOD = 1 days;
    uint256 constant DEFAULT_GAS_Threshold = 100_000;

    bytes32 internal constant TEST_SALT = keccak256("payment-processor.test");

    /// @dev Read back by PaymentProcessorStorage's constructor; populated via {_authorize}.
    address[] private pendingAuthorized;

    /// @inheritdoc IAuthorizedAddressProvider
    function authorizedAddresses() external view returns (address[] memory authorized) {
        authorized = pendingAuthorized;
    }

    /**
     * @notice Initializes shared storage and notes contracts for tests.
     * @dev PaymentProcessorStorage authorization is fixed at construction, so its address is
     *      predicted first, dependent contracts are deployed against the prediction (via the
     *      {_deployAuthorized} hook), and the storage contract is deployed last via CREATE2.
     * @return storageAddress The deployed PaymentProcessorStorage address.
     * @return notesAddress The deployed Notes address.
     */
    function initialize() public virtual returns (address storageAddress, address notesAddress) {
        vm.deal(buyerOne, INITIAL_BALANCE);
        vm.deal(sellerOne, INITIAL_BALANCE);

        vm.deal(buyerTwo, INITIAL_BALANCE);
        vm.deal(sellerTwo, INITIAL_BALANCE);

        IPaymentProcessorStorage.Configuration memory config = IPaymentProcessorStorage.Configuration({
            owner: admin,
            feeReceiver: feeReceiver,
            marketplace: address(this),
            feeRate: uint96(FEE_RATE),
            defaultHoldPeriod: uint96(DEFAULT_HOLD_PERIOD),
            gasThreshold: uint96(DEFAULT_GAS_Threshold)
        });

        address predictedStorage = _predictStorageAddress(config);
        notes = new Notes(predictedStorage);

        _deployAuthorized(predictedStorage, address(notes));

        ppStorage = new PaymentProcessorStorage{ salt: TEST_SALT }(config);
        delete pendingAuthorized;
        assertEq(address(ppStorage), predictedStorage, "storage deployed away from prediction");

        storageAddress = address(ppStorage);
        notesAddress = address(notes);
    }

    /**
     * @notice Hook for child setups: deploy processors against the predicted storage address and
     *         register them with {_authorize}. Overrides must call `super._deployAuthorized` so
     *         setups compose under multiple inheritance.
     * @param _predictedStorage The address PaymentProcessorStorage will be deployed at.
     * @param _notesAddress The deployed Notes address.
     */
    function _deployAuthorized(address _predictedStorage, address _notesAddress) internal virtual { }

    /// @notice Registers an address to be authorized when PaymentProcessorStorage deploys.
    function _authorize(address _processor) internal {
        pendingAuthorized.push(_processor);
    }

    /// @notice Predicts the CREATE2 address PaymentProcessorStorage will be deployed at.
    function _predictStorageAddress(IPaymentProcessorStorage.Configuration memory _config)
        internal
        view
        returns (address predicted)
    {
        predicted = vm.computeCreate2Address(
            TEST_SALT,
            keccak256(abi.encodePacked(type(PaymentProcessorStorage).creationCode, abi.encode(_config))),
            address(this)
        );
    }
}
