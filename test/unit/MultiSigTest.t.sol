// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { MultiSigSetUp } from "../utils/MultiSigSetUp.sol";
import { IMultiSig } from "src/interface/IMultiSig.sol";
import { MultiSig } from "../../src/MultiSig.sol";

import { PROPOSED, APPROVED, EXECUTED, CANCELED } from "src/constants/MultiSig.sol";

contract MultiSigTest is MultiSigSetUp {
    function test_initialState() public view {
        assertTrue(multisig.isSigner(signerOne));
        assertTrue(multisig.isSigner(signerTwo));
        assertTrue(multisig.isSigner(signerThree));
        assertEq(multisig.getThreshold(), INITIAL_THRESHOLD);
        assertEq(multisig.getSignerCount(), INITIAL_SIGNER_COUNT);
    }

    function test_proposeTransaction() public {
        bytes memory data = _encodeSetFeeSigner(address(0xf005));
        address target = address(ppStorage);

        vm.expectRevert(IMultiSig.NotSigner.selector);
        multisig.proposeTransaction(target, data);

        vm.startPrank(signerOne);
        vm.expectRevert(IMultiSig.InvalidTarget.selector);
        multisig.proposeTransaction(address(0), data);

        uint256 nonce = multisig.getNonce() + 1;
        bytes32 expectedTxHash = _hashTx(target, data, nonce);

        vm.expectEmit(address(multisig));
        emit IMultiSig.TransactionProposed(expectedTxHash, target, data, nonce, signerOne);
        bytes32 txHash = multisig.proposeTransaction(target, data);
        vm.stopPrank();

        IMultiSig.Transaction memory txn = multisig.getTransaction(txHash);
        assertEq(txn.target, target);
        assertEq(txn.nonce, nonce);
        assertEq(txn.status, PROPOSED);
        assertEq(expectedTxHash, txHash);
        assertEq(txn.approvalCount, 1);
        assertTrue(multisig.hasApproved(txHash, signerOne));
    }

    function test_approveTransaction() public {
        bytes memory data = _encodeSetFeeSigner(address(0xf005));

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
        emit IMultiSig.TransactionApproved(txHash);
        vm.expectEmit(address(multisig));
        emit IMultiSig.ApprovalAdded(txHash, signerTwo, 2);
        multisig.approveTransaction(txHash);

        vm.expectRevert(IMultiSig.AlreadyApprovedByThisSigner.selector);
        multisig.approveTransaction(txHash);
        vm.stopPrank();

        vm.prank(signerThree);
        multisig.approveTransaction(txHash);

        IMultiSig.Transaction memory txn = multisig.getTransaction(txHash);
        assertEq(txn.status, APPROVED);
        assertEq(txn.approvalCount, 3);
    }

    function test_executeTransaction() public {
        address newOperator = address(0x0b5e);
        bytes memory data = _encodeSetOperator(newOperator);

        bytes32 txHash = _propose(data);
        address[] memory approvers = _approversOf(txHash);

        vm.expectRevert(IMultiSig.NotSigner.selector);
        multisig.executeTransaction(txHash, approvers);

        vm.prank(signerOne);
        vm.expectRevert(IMultiSig.TransactionNotApproved.selector);
        multisig.executeTransaction(txHash, approvers);

        vm.prank(signerTwo);
        multisig.approveTransaction(txHash);
        approvers = _approversOf(txHash);

        vm.expectEmit(address(multisig));
        emit IMultiSig.TransactionExecuted(txHash, signerThree);

        vm.prank(signerThree);
        multisig.executeTransaction(txHash, approvers);

        IMultiSig.Transaction memory txn = multisig.getTransaction(txHash);
        assertEq(txn.status, EXECUTED);
        assertEq(ppStorage.getIntermediatedPlatformsOperator(), newOperator);
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
        bytes32 txHash = multisig.proposeTransaction(address(multisig), data);

        vm.prank(signerTwo);
        multisig.approveTransaction(txHash);

        uint256 signerCountBefore = multisig.getSignerCount();
        address[] memory approvers = _approversOf(txHash);

        vm.prank(signerOne);
        vm.expectEmit(address(multisig));
        emit IMultiSig.SignerAdded(outsider);
        multisig.executeTransaction(txHash, approvers);

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
        bytes32 txHash = multisig.proposeTransaction(address(multisig), data);

        vm.prank(signerThree);
        multisig.approveTransaction(txHash);

        uint256 signerCountBefore = multisig.getSignerCount();
        address[] memory approvers = _approversOf(txHash);

        vm.prank(signerOne);
        vm.expectEmit(address(multisig));
        emit IMultiSig.SignerRemoved(signerTwo);
        multisig.executeTransaction(txHash, approvers);

        vm.prank(address(multisig));
        vm.expectRevert(IMultiSig.InsufficientSigners.selector);
        multisig.removeSigner(signerOne);

        assertFalse(multisig.isSigner(signerTwo));
        assertEq(multisig.getSignerCount(), signerCountBefore - 1);
    }

    function test_thresholdTracksMajorityAsSignersAreAdded() public {
        // 3 signers, majority 2.
        assertEq(multisig.getThreshold(), 2);

        vm.prank(address(multisig));
        vm.expectEmit(address(multisig));
        emit IMultiSig.ThresholdUpdated(2, 3);
        multisig.addSigner(outsider);

        // 4 signers, majority 3.
        assertEq(multisig.getThreshold(), 3);
        assertEq(multisig.getSignerCount(), 4);
    }

    function test_removingASignerResetsTheThresholdToMajority() public {
        vm.startPrank(address(multisig));
        multisig.addSigner(outsider);
        multisig.addSigner(address(0xa5));

        // 5 signers, majority 3; raise it to unanimity.
        multisig.updateThreshold(5);
        assertEq(multisig.getThreshold(), 5);

        // Removal recomputes the majority outright, so the supermajority does not survive it.
        vm.expectEmit(address(multisig));
        emit IMultiSig.ThresholdUpdated(5, 3);
        multisig.removeSigner(outsider);
        assertEq(multisig.getThreshold(), 3);
        vm.stopPrank();
    }

    function test_thresholdBelowMajorityIsRejected() public {
        // 3 signers: a majority is 2, so 1 is not allowed even though it is non-zero.
        vm.prank(address(multisig));
        vm.expectRevert(IMultiSig.InvalidThreshold.selector);
        multisig.updateThreshold(1);
    }

    function test_constructorRejectsAThresholdBelowMajority() public {
        address[] memory initialSigners = new address[](3);
        initialSigners[0] = signerOne;
        initialSigners[1] = signerTwo;
        initialSigners[2] = signerThree;

        vm.expectRevert(IMultiSig.InvalidThreshold.selector);
        new MultiSig(initialSigners, 1);
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
        bytes32 txHash = multisig.proposeTransaction(address(multisig), data);

        vm.prank(signerThree);
        multisig.approveTransaction(txHash);

        // The fourth signer lifted the majority to 3, so two approvals no longer execute.
        vm.prank(signerTwo);
        multisig.approveTransaction(txHash);

        uint256 thresholdBefore = multisig.getThreshold();
        address[] memory approvers = _approversOf(txHash);

        vm.prank(signerOne);
        vm.expectEmit(address(multisig));
        emit IMultiSig.ThresholdUpdated(thresholdBefore, newThreshold);
        multisig.executeTransaction(txHash, approvers);
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

    function test_constructorRejectsDuplicateSigners() public {
        address[] memory signers = new address[](3);
        signers[0] = signerOne;
        signers[1] = signerTwo;
        signers[2] = signerOne;

        vm.expectRevert(IMultiSig.AlreadyASigner.selector);
        new MultiSig(signers, 2);
    }

    function test_constructorRejectsZeroAddressSigner() public {
        address[] memory signers = new address[](2);
        signers[0] = signerOne;

        vm.expectRevert(IMultiSig.InvalidSigner.selector);
        new MultiSig(signers, 2);
    }

    function test_addSignerRejectsZeroAddress() public {
        vm.prank(address(multisig));
        vm.expectRevert(IMultiSig.InvalidSigner.selector);
        multisig.addSigner(address(0));
    }

    function test_cancelTransaction() public {
        bytes memory data = _encodeSetFeeSigner(address(0xf005));

        bytes32 txHash = _propose(data);

        vm.prank(signerOne);
        vm.expectRevert(IMultiSig.NotSelf.selector);
        multisig.cancelTransaction(txHash);

        vm.prank(address(multisig));
        vm.expectRevert(IMultiSig.TransactionDoesNotExist.selector);
        multisig.cancelTransaction(keccak256(""));

        vm.expectEmit(address(multisig));
        emit IMultiSig.TransactionCanceled(txHash);
        vm.prank(address(multisig));
        multisig.cancelTransaction(txHash);

        assertEq(multisig.getTransaction(txHash).status, CANCELED);

        vm.prank(address(multisig));
        vm.expectRevert(IMultiSig.TransactionNotProposedOrApproved.selector);
        multisig.cancelTransaction(txHash);

        vm.prank(signerTwo);
        vm.expectRevert(IMultiSig.TransactionNotProposedOrApproved.selector);
        multisig.approveTransaction(txHash);

        address[] memory approvers = _approversOf(txHash);
        vm.prank(signerOne);
        vm.expectRevert(IMultiSig.TransactionNotProposedOrApproved.selector);
        multisig.executeTransaction(txHash, approvers);

        bytes32 approvedTxHash = _proposeAndApprove(data);
        assertEq(multisig.getTransaction(approvedTxHash).status, APPROVED);
        approvers = _approversOf(approvedTxHash);

        vm.prank(address(multisig));
        multisig.cancelTransaction(approvedTxHash);

        assertEq(multisig.getTransaction(approvedTxHash).status, CANCELED);

        vm.prank(signerOne);
        vm.expectRevert(IMultiSig.TransactionNotProposedOrApproved.selector);
        multisig.executeTransaction(approvedTxHash, approvers);
    }

    function test_removedSignerApprovalNoLongerCounts() public {
        bytes32 txHash = _proposeAndApprove(_encodeSetFeeSigner(address(0xf005)));
        assertEq(multisig.getTransaction(txHash).status, APPROVED);

        vm.prank(address(multisig));
        multisig.removeSigner(signerTwo);

        address[] memory approvers = new address[](2);
        approvers[0] = signerOne;
        approvers[1] = signerTwo;
        vm.prank(signerOne);
        vm.expectRevert(abi.encodeWithSelector(IMultiSig.InvalidApprover.selector, signerTwo));
        multisig.executeTransaction(txHash, approvers);

        approvers = _approversOf(txHash);
        assertEq(approvers.length, 1);
        vm.prank(signerOne);
        vm.expectRevert(IMultiSig.TransactionNotApproved.selector);
        multisig.executeTransaction(txHash, approvers);

        vm.prank(signerThree);
        multisig.approveTransaction(txHash);
        approvers = _approversOf(txHash);

        vm.prank(signerOne);
        multisig.executeTransaction(txHash, approvers);

        assertEq(multisig.getTransaction(txHash).status, EXECUTED);
        assertEq(ppStorage.getFeeSigner(), address(0xf005));
    }

    function test_executeRejectsUnsortedDuplicateOrNonApprovingApprovers() public {
        bytes32 txHash = _proposeAndApprove(_encodeSetFeeSigner(address(0xf005)));

        address[] memory approvers = new address[](2);
        approvers[0] = signerTwo;
        approvers[1] = signerOne;
        vm.prank(signerOne);
        vm.expectRevert(IMultiSig.ApproversNotSorted.selector);
        multisig.executeTransaction(txHash, approvers);

        approvers[0] = signerOne;
        approvers[1] = signerOne;
        vm.prank(signerOne);
        vm.expectRevert(IMultiSig.ApproversNotSorted.selector);
        multisig.executeTransaction(txHash, approvers);

        approvers[1] = signerThree;
        vm.prank(signerOne);
        vm.expectRevert(abi.encodeWithSelector(IMultiSig.InvalidApprover.selector, signerThree));
        multisig.executeTransaction(txHash, approvers);
    }
}
