// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MultiSigSetUp } from "../utils/MultiSigSetUp.sol";
import { IMultiSig } from "../../src/interface/IMultiSig.sol";

import { PENDING, APPROVED, EXECUTED } from "src/constants/MultiSig.sol";

contract MultiSigTest is MultiSigSetUp {
    function test_initialState() public view {
        assertTrue(multisig.isSigner(signerOne));
        assertTrue(multisig.isSigner(signerTwo));
        assertTrue(multisig.isSigner(signerThree));
        assertEq(multisig.getThreshold(), INITIAL_THRESHOLD);
        assertEq(multisig.getSignerCount(), INITIAL_SIGNER_COUNT);
    }

    function test_proposeTransaction() public {
        uint256 newWindow = 10 days;
        bytes memory data = _encodeSetDecisionWindow(newWindow);

        vm.expectRevert(IMultiSig.NotSigner.selector);
        multisig.proposeTransaction(ppStorage, 0, data);

        vm.startPrank(signerOne);
        vm.expectRevert(IMultiSig.InvalidTarget.selector);
        multisig.proposeTransaction(address(0), 0, data);

        uint256 nonce = multisig.getNonce() + 1;
        bytes32 expectedTxHash = _hashTx(ppStorage, data, nonce);

        vm.expectEmit(address(multisig));
        emit IMultiSig.TransactionProposed(expectedTxHash, ppStorage, 0, data, nonce, signerOne);
        bytes32 txHash = multisig.proposeTransaction(ppStorage, 0, data);
        vm.stopPrank();

        IMultiSig.Transaction memory txn = multisig.getTransaction(txHash);
        assertEq(txn.target, ppStorage);
        assertEq(txn.value, 0);
        assertEq(txn.nonce, nonce);
        assertEq(txn.status, PENDING);
        assertEq(expectedTxHash, txHash);
        assertEq(txn.approvalCount, 1);
        assertTrue(multisig.hasApproved(txHash, signerOne));
    }

    function test_approveTransaction() public {
        uint256 newWindow = 10 days;
        bytes memory data = _encodeSetDecisionWindow(newWindow);

        vm.prank(signerOne);
        bytes32 txHash = multisig.proposeTransaction(ppStorage, 0, data);

        vm.expectRevert(IMultiSig.NotSigner.selector);
        multisig.approveTransaction(txHash);

        vm.startPrank(signerOne);
        vm.expectRevert(IMultiSig.TransactionDoesNotExist.selector);
        multisig.approveTransaction(keccak256(""));

        vm.expectRevert(IMultiSig.AlreadyApprovedByThisSigner.selector);
        multisig.approveTransaction(txHash);

        vm.stopPrank();

        vm.startPrank(signerTwo);
        multisig.approveTransaction(txHash);

        vm.expectRevert(IMultiSig.AlreadyApproved.selector);
        multisig.approveTransaction(txHash);
        vm.stopPrank();

        IMultiSig.Transaction memory txn = multisig.getTransaction(txHash);
        assertEq(txn.status, APPROVED);
        assertEq(txn.approvalCount, 2);
    }

    function test_executeTransaction() public {
        // reverts If Already Executed
        // reverts If Not Approved
        // Non Signer Reverts
        // reverts If Call Fails
    }

    function test_addSigner() public {
        // Not Self Reverts
        // reverts If Already Signer
    }

    function test_removeSigner() public {
        // Not Self Reverts
        // reverts If Drops Below Threshold
    }

    function test_updateThreshold() public {
        // Not Self Reverts
        // reverts If Invalid
    }

    function test_constructor() public {
        // Insufficient Signers Reverts
        // Invalid Threshold Reverts
    }
}
