// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MultiSig } from "../../src/MultiSig.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { IAuthorizedAddressProvider } from "../../src/interface/IMasterDeployer.sol";

abstract contract MultiSigSetUp is Test, IAuthorizedAddressProvider {
    MultiSig multisig;
    PaymentProcessorStorage ppStorage;

    // Signers
    address internal signerOne = address(1);
    address internal signerTwo = address(2);
    address internal signerThree = address(3);

    // Non-signer
    address internal outsider = address(4);

    address internal feeReceiver = address(5);

    // Default deployment parameters
    uint256 constant INITIAL_THRESHOLD = 2;
    uint256 constant INITIAL_SIGNER_COUNT = 3;
    uint96 constant FEE_RATE = 500;
    uint96 constant DEFAULT_HOLD_PERIOD = 1 days;
    uint96 constant GAS_THRESHOLD = 100_000;

    function setUp() public virtual {
        _multiSigSetUp();
    }

    /// @dev PaymentProcessorStorage reads this from its deployer at construction; the multisig
    ///      tests need no authorized processors.
    function authorizedAddresses() external pure returns (address[] memory authorized) {
        authorized = new address[](0);
    }

    function _multiSigSetUp() internal virtual returns (MultiSig deployedMultiSig) {
        address[] memory initialSigners = new address[](INITIAL_SIGNER_COUNT);
        initialSigners[0] = signerOne;
        initialSigners[1] = signerTwo;
        initialSigners[2] = signerThree;

        multisig = new MultiSig(initialSigners, INITIAL_THRESHOLD);

        IPaymentProcessorStorage.Configuration memory config = IPaymentProcessorStorage.Configuration({
            owner: address(multisig),
            feeReceiver: feeReceiver,
            marketplace: address(this),
            feeRate: FEE_RATE,
            defaultHoldPeriod: DEFAULT_HOLD_PERIOD,
            gasThreshold: GAS_THRESHOLD
        });

        ppStorage = new PaymentProcessorStorage(config);
        deployedMultiSig = multisig;
    }

    // ----------------------------------------------------------------
    //                         HELPER FUNCTIONS
    // ----------------------------------------------------------------

    function _propose(bytes memory data) internal returns (bytes32 txHash) {
        vm.prank(signerOne);
        txHash = multisig.proposeTransaction(address(ppStorage), 0, data);
    }

    /// @dev signerOne auto-approves on propose; one more signer reaches the threshold of 2.
    function _proposeAndApprove(bytes memory data) internal returns (bytes32 txHash) {
        txHash = _propose(data);

        vm.prank(signerTwo);
        multisig.approveTransaction(txHash);
    }

    function _encodeSetFeeRate(uint96 _feeRate) internal pure returns (bytes memory) {
        return abi.encodeCall(IPaymentProcessorStorage.setFeeRate, _feeRate);
    }

    function _encodeSetDefaultHoldPeriod(uint96 _period) internal pure returns (bytes memory) {
        return abi.encodeCall(IPaymentProcessorStorage.setDefaultHoldPeriod, _period);
    }

    function _encodeSetGasThreshold(uint96 _threshold) internal pure returns (bytes memory) {
        return abi.encodeCall(IPaymentProcessorStorage.setGasThreshold, _threshold);
    }

    function _hashTx(address _target, bytes memory _data, uint256 _newNonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(_target, _data, _newNonce));
    }
}
