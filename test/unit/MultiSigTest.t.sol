// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MultiSigSetUp } from "../utils/MultiSigSetUp.sol";
import { IMultiSig } from "src/interface/IMultiSig.sol";
import { MultiSig } from "../../src/MultiSig.sol";

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
        bytes memory data = _encodeSetFeeRate(1000);
        address target = address(ppStorage);

        vm.expectRevert(IMultiSig.NotSigner.selector);
        multisig.proposeTransaction(target, 0, data);

        vm.startPrank(signerOne);
        vm.expectRevert(IMultiSig.InvalidTarget.selector);
        multisig.proposeTransaction(address(0), 0, data);

        uint256 nonce = multisig.getNonce() + 1;
        bytes32 expectedTxHash = _hashTx(target, data, nonce);

        vm.expectEmit(address(multisig));
        emit IMultiSig.TransactionProposed(expectedTxHash, target, 0, data, nonce, signerOne);
        bytes32 txHash = multisig.proposeTransaction(target, 0, data);
        vm.stopPrank();

        IMultiSig.Transaction memory txn = multisig.getTransaction(txHash);
        assertEq(txn.target, target);
        assertEq(txn.value, 0);
        assertEq(txn.nonce, nonce);
        assertEq(txn.status, PENDING);
        assertEq(expectedTxHash, txHash);
        assertEq(txn.approvalCount, 1);
        assertTrue(multisig.hasApproved(txHash, signerOne));
    }

    function test_approveTransaction() public {
        bytes memory data = _encodeSetFeeRate(1000);

        bytes32 txHash = _propose(data);

        vm.expectRevert(IMultiSig.NotSigner.selector);
        multisig.approveTransaction(txHash);

        vm.startPrank(signerOne);
        vm.expectRevert(IMultiSig.TransactionDoesNotExist.selector);
        multisig.approveTransaction(keccak256(""));

        vm.expectRevert(IMultiSig.AlreadyApprovedByThisSigner.selector);
        multisig.approveTransaction(txHash);

        vm.stopPrank();

        vm.startPrank(signerTwo);

        vm.expectEmit(address(multisig));
        emit IMultiSig.TransactionApproved(txHash, signerTwo, 2);
        multisig.approveTransaction(txHash);

        vm.expectRevert(IMultiSig.AlreadyApproved.selector);
        multisig.approveTransaction(txHash);
        vm.stopPrank();

        IMultiSig.Transaction memory txn = multisig.getTransaction(txHash);
        assertEq(txn.status, APPROVED);
        assertEq(txn.approvalCount, 2);
    }

    function test_executeTransaction() public {
        uint96 newPeriod = 10 days;
        bytes memory data = _encodeSetDefaultHoldPeriod(newPeriod);

        bytes32 txHash = _propose(data);

        vm.expectRevert(IMultiSig.NotSigner.selector);
        multisig.executeTransaction(txHash);

        vm.prank(signerOne);
        vm.expectRevert(IMultiSig.TransactionNotApproved.selector);
        multisig.executeTransaction(txHash);

        vm.prank(signerTwo);
        multisig.approveTransaction(txHash);

        vm.expectEmit(address(multisig));
        emit IMultiSig.TransactionExecuted(txHash, signerThree);

        vm.prank(signerThree);
        multisig.executeTransaction(txHash);

        IMultiSig.Transaction memory txn = multisig.getTransaction(txHash);
        assertEq(txn.status, EXECUTED);
        assertEq(ppStorage.getDefaultHoldPeriod(), newPeriod);
    }

    function test_addSigner() public {
        vm.prank(signerOne);
        vm.expectRevert(IMultiSig.NotSelf.selector);
        multisig.addSigner(outsider);

        vm.prank(address(multisig));
        vm.expectRevert(IMultiSig.AlreadyASigner.selector);
        multisig.addSigner(signerOne);

        vm.prank(signerOne);
        bytes memory data = abi.encodeCall(IMultiSig.addSigner, outsider);
        bytes32 txHash = multisig.proposeTransaction(address(multisig), 0, data);

        vm.prank(signerTwo);
        multisig.approveTransaction(txHash);

        uint256 signerCountBefore = multisig.getSignerCount();

        vm.prank(signerOne);
        vm.expectEmit(address(multisig));
        emit IMultiSig.SignerAdded(outsider);
        multisig.executeTransaction(txHash);

        assertTrue(multisig.isSigner(outsider));
        assertEq(multisig.getSignerCount(), signerCountBefore + 1);
    }

    function test_removeSigner() public {
        vm.prank(signerOne);
        vm.expectRevert(IMultiSig.NotSelf.selector);
        multisig.removeSigner(outsider);

        vm.prank(address(multisig));
        vm.expectRevert(IMultiSig.NotASigner.selector);
        multisig.removeSigner(outsider);

        vm.prank(signerOne);
        bytes memory data = abi.encodeCall(IMultiSig.removeSigner, signerTwo);
        bytes32 txHash = multisig.proposeTransaction(address(multisig), 0, data);

        vm.prank(signerThree);
        multisig.approveTransaction(txHash);

        uint256 signerCountBefore = multisig.getSignerCount();

        vm.prank(signerOne);
        vm.expectEmit(address(multisig));
        emit IMultiSig.SignerRemoved(signerTwo);
        multisig.executeTransaction(txHash);

        vm.prank(address(multisig));
        vm.expectRevert(IMultiSig.SignerCountBelowThreshold.selector);
        multisig.removeSigner(signerOne);

        assertFalse(multisig.isSigner(signerTwo));
        assertEq(multisig.getSignerCount(), signerCountBefore - 1);
    }

    function test_updateThreshold() public {
        vm.prank(signerOne);
        vm.expectRevert(IMultiSig.NotSelf.selector);
        multisig.updateThreshold(5);

        uint256 signerCount = multisig.getSignerCount();
        uint256 newThreshold = signerCount + 1;

        vm.prank(address(multisig));
        vm.expectRevert(IMultiSig.ThresholdCannotBeZero.selector);
        multisig.updateThreshold(0);

        vm.prank(address(multisig));
        vm.expectRevert(IMultiSig.SignerCountBelowThreshold.selector);
        multisig.updateThreshold(newThreshold);

        vm.prank(address(multisig));
        multisig.addSigner(outsider);

        vm.prank(signerOne);
        bytes memory data = abi.encodeCall(IMultiSig.updateThreshold, newThreshold);
        bytes32 txHash = multisig.proposeTransaction(address(multisig), 0, data);

        vm.prank(signerThree);
        multisig.approveTransaction(txHash);

        uint256 thresholdBefore = multisig.getThreshold();

        vm.prank(signerOne);
        vm.expectEmit(address(multisig));
        emit IMultiSig.ThresholdUpdated(thresholdBefore, newThreshold);
        multisig.executeTransaction(txHash);
    }

    function test_constructor() public {
        address[] memory signers = new address[](1);
        signers[0] = signerOne;

        vm.expectRevert(IMultiSig.InsufficientSigners.selector);
        new MultiSig(signers, 1);

        signers = new address[](2);
        signers[1] = signerTwo;

        vm.expectRevert(IMultiSig.InvalidThreshold.selector);
        new MultiSig(signers, 0);

        vm.expectRevert(IMultiSig.InvalidThreshold.selector);
        new MultiSig(signers, 3);
    }
}
