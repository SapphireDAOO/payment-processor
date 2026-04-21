// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MultiSig } from "../../src/MultiSig.sol";
import { IMultiSig } from "../../src/interface/IMultiSig.sol";

abstract contract MultiSigSetUp is Test {
    MultiSig multisig;

    // Signers
    address internal signerOne = address(0x1001);
    address internal signerTwo = address(0x1002);
    address internal signerThree = address(0x1003);

    // Non-signer
    address internal outsider = address(0x1004);

    // Default deployment parameters
    uint256 constant INITIAL_THRESHOLD = 2;
    uint256 constant INITIAL_SIGNER_COUNT = 3;

    // Payment processor targets used across tests
    address internal simplePP = address(0x2001);
    address internal advancedPP = address(0x2002);

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

    /// @notice Returns a valid proposeTransaction calldata targeting simplePP.
    function _buildProposal(bytes memory data, uint256 nonce)
        internal
        view
        returns (address target, uint256 value, bytes memory callData, uint256 proposalNonce)
    {
        target = simplePP;
        value = 0;
        callData = data;
        proposalNonce = nonce;
    }

    /// @notice Proposes a transaction as signerOne and returns the txHash.
    function _propose(bytes memory data, uint256 nonce) internal returns (bytes32 txHash) {
        vm.prank(signerOne);
        txHash = multisig.proposeTransaction(simplePP, 0, data, nonce);
    }

    /// @notice Proposes and fully approves a transaction (signerOne + signerTwo) to reach threshold.
    function _proposeAndApprove(bytes memory data, uint256 nonce) internal returns (bytes32 txHash) {
        txHash = _propose(data, nonce);

        vm.prank(signerOne);
        multisig.approveTransaction(txHash);

        vm.prank(signerTwo);
        multisig.approveTransaction(txHash);
    }

    /// @notice ABI-encodes a setDecisionWindow call for use as proposal data.
    function _encodeSetDecisionWindow(uint256 window) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("setDecisionWindow(uint256)", window);
    }

    /// @notice ABI-encodes a setMinimumInvoiceValue call for use as proposal data.
    function _encodeSetMinimumInvoiceValue(uint256 value) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("setMinimumInvoiceValue(uint256)", value);
    }
}
