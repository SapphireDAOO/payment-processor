// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Notes } from "src/Notes.sol";
import { MockWeth } from "../mock/MockWeth.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { IAuthorizedAddressProvider, IPendingProcessorProvider } from "../../src/interface/IMasterDeployer.sol";
import { Test } from "forge-std/Test.sol";

abstract contract BaseSetUp is Test, IAuthorizedAddressProvider, IPendingProcessorProvider {
    PaymentProcessorStorage ppStorage;
    Notes notes;
    MockWeth weth;

    address internal admin = address(1);
    address internal buyerOne = address(2);
    address internal buyerTwo = address(3);
    address internal sellerOne = address(4);
    address internal sellerTwo = address(5);
    address internal feeReceiver = address(6);

    /// @dev Key the processors recover to authorize a per-invoice fee receiver.
    uint256 internal constant FEE_SIGNER_PK = uint256(keccak256("payment-processor.test.fee-signer"));
    address internal feeSigner = vm.addr(FEE_SIGNER_PK);

    uint256 constant INITIAL_BALANCE = 100_000 ether;
    uint256 public constant FEE_RATE = 500;

    /// @dev The system-wide escrow hold period every test invoice runs with.
    uint32 constant TEST_ESCROW_HOLD_PERIOD = 1 days;
    uint256 constant DEFAULT_GAS_Threshold = 100_000;

    bytes32 internal constant TEST_SALT = keccak256("payment-processor.test");

    /// @dev Read back by PaymentProcessorStorage's and Notes' constructors; populated via {_authorize}.
    address[] private pendingAuthorized;

    /// @dev Read back by PaymentAutomation's constructor, which takes no processor argument.
    address internal pendingProcessorAddress;

    /// @inheritdoc IAuthorizedAddressProvider
    function authorizedAddresses() external view returns (address[] memory authorized) {
        authorized = pendingAuthorized;
    }

    /// @inheritdoc IPendingProcessorProvider
    function pendingProcessor() external view returns (address processor) {
        processor = pendingProcessorAddress;
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

        weth = new MockWeth();

        IPaymentProcessorStorage.Configuration memory config = IPaymentProcessorStorage.Configuration({
            owner: admin, feeReceiver: feeReceiver, intermediatedPlatformsOperator: address(this), weth: address(weth)
        });

        address predictedStorage = _predictStorageAddress(config);
        address predictedNotes = vm.computeCreate2Address(
            TEST_SALT,
            keccak256(abi.encodePacked(type(Notes).creationCode, abi.encode(predictedStorage))),
            address(this)
        );

        _deployAuthorized(predictedStorage, predictedNotes);

        pendingAuthorized.push(address(this));
        notes = new Notes{ salt: TEST_SALT }(predictedStorage);
        assertEq(address(notes), predictedNotes, "notes deployed away from prediction");
        pendingAuthorized.pop();

        ppStorage = new PaymentProcessorStorage{ salt: TEST_SALT }(config);
        delete pendingAuthorized;
        assertEq(address(ppStorage), predictedStorage, "storage deployed away from prediction");

        vm.prank(admin);
        ppStorage.setFeeSigner(feeSigner);

        storageAddress = address(ppStorage);
        notesAddress = address(notes);
    }

    /**
     * @notice Hook for child setups: deploy processors against the predicted storage address and
     *         register them with {_authorize}. Overrides must call `super._deployAuthorized` so
     *         setups compose under multiple inheritance.
     * @param _predictedStorage The address PaymentProcessorStorage will be deployed at.
     * @param _notesAddress The address Notes will be deployed at; it does not exist yet.
     */
    function _deployAuthorized(address _predictedStorage, address _notesAddress) internal virtual { }

    /**
     * @notice Signs a fee-receiver authorization for `_processor` as the configured fee signer.
     * @param _processor The processor the signature is bound to.
     * @param _invoiceId The invoice the fee receiver is attached to.
     * @param _feeReceiver The fee receiver being authorized.
     * @return signature The 65-byte ECDSA signature to pass as the call's `_data`.
     */
    function _feeSig(address _processor, uint216 _invoiceId, address _feeReceiver)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 digest = _feeDigest(_processor, _invoiceId, _feeReceiver);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FEE_SIGNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @notice Signs one authorization covering every fee receiver of a meta-invoice.
     * @param _processor The processor the signature is bound to.
     * @param _metaInvoiceId The meta-invoice being paid.
     * @param _receivers The fee receivers, index-aligned with the meta-invoice's sub-invoice IDs.
     * @return signature The 65-byte ECDSA signature to pass as the call's `_data`.
     */
    function _feeSigMeta(address _processor, uint216 _metaInvoiceId, address[] memory _receivers)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encode(_processor, block.chainid, _metaInvoiceId, _receivers))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(FEE_SIGNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Builds `_count` fee receivers, all pointing at the shared `feeReceiver`.
    function _feeReceivers(uint256 _count) internal view returns (address[] memory receivers) {
        receivers = new address[](_count);
        for (uint256 i; i < _count; i++) {
            receivers[i] = feeReceiver;
        }
    }

    /// @dev Mirrors {FeeAuthorizationLib.digest}, which reads `address(this)` from its caller.
    function _feeDigest(address _processor, uint216 _invoiceId, address _feeReceiver)
        private
        view
        returns (bytes32 digest)
    {
        return keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encode(_processor, block.chainid, _invoiceId, _feeReceiver))
            )
        );
    }

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
