// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MultiSig } from "../../src/MultiSig.sol";
import { IMultiSig } from "../../src/interface/IMultiSig.sol";

abstract contract MultiSigSetUp is Test {
    MultiSig multisig;

    // Signers
    address internal signerOne = address(1);
    address internal signerTwo = address(2);
    address internal signerThree = address(3);

    // Non-signer
    address internal outsider = address(4);

    // Default deployment parameters
    uint256 constant INITIAL_THRESHOLD = 2;
    uint256 constant INITIAL_SIGNER_COUNT = 3;

    // Payment processor targets used across tests
    address internal simplePP = address(0x2001);
    address internal advancedPP = address(0x2002);
    address internal ppStorage = address(0x2003);

    function setUp() public virtual {
        _multiSigSetUp();
    }

    function _multiSigSetUp() internal virtual returns (MultiSig deployedMultiSig) {
        address[] memory initialSigners = new address[](INITIAL_SIGNER_COUNT);
        initialSigners[0] = signerOne;
        initialSigners[1] = signerTwo;
        initialSigners[2] = signerThree;

        multisig = new MultiSig(initialSigners, INITIAL_THRESHOLD);
        deployedMultiSig = multisig;
    }

    // ----------------------------------------------------------------
    //                         HELPER FUNCTIONS
    // ----------------------------------------------------------------

    function _propose(bytes memory data) internal returns (bytes32 txHash) {
        vm.prank(signerOne);
        txHash = multisig.proposeTransaction(simplePP, 0, data);
    }

    function _proposeAndApprove(bytes memory data) internal returns (bytes32 txHash) {
        txHash = _propose(data);

        vm.prank(signerOne);
        multisig.approveTransaction(txHash);

        vm.prank(signerTwo);
        multisig.approveTransaction(txHash);
    }

    function _encodeSetDecisionWindow(uint256 window) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("setDecisionWindow(uint256)", window);
    }

    function _encodeSetMinimumInvoiceValue(uint256 value) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("setMinimumInvoiceValue(uint256)", value);
    }

    function _hashTx(address _target, bytes memory _data, uint256 _newNonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(_target, _data, _newNonce));
    }

    function _call(address _target, bytes memory _data) internal {
        vm.etch(_target, new bytes(0x02));
        vm.mockCall(_target, _data, abi.encode(true));
    }
}
