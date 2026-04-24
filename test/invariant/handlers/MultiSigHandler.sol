// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { MultiSig } from "../../../src/MultiSig.sol";
import { IMultiSig } from "../../../src/interface/IMultiSig.sol";
import { IPaymentProcessorStorage } from "../../../src/interface/IPaymentProcessorStorage.sol";
import { PaymentProcessorStorage } from "../../../src/PaymentProcessorStorage.sol";

import { PENDING, APPROVED, MINIMUM_THRESHOLD } from "src/constants/MultiSig.sol";

contract MultiSigHandler is Test {
    MultiSig public multisig;
    PaymentProcessorStorage public ppStorage;

    address[] internal signers;
    uint256 internal ghostThreshold;

    uint256 public ghostNonce;

    bytes32[] public allTxHashes;
    bytes32[] public executedTxHashes;

    mapping(bytes32 txHash => mapping(address signer => bool approved)) internal ghostApprovals;

    modifier hasSigners() {
        if (signers.length == 0) return;
        _;
    }

    modifier hasTx() {
        if (allTxHashes.length == 0) return;
        _;
    }

    constructor(
        MultiSig _multisig,
        PaymentProcessorStorage _ppStorage,
        address[] memory _initialSigners,
        uint256 _initialThreshold
    ) {
        multisig = _multisig;
        ppStorage = _ppStorage;
        for (uint256 i; i < _initialSigners.length; i++) {
            signers.push(_initialSigners[i]);
        }
        ghostThreshold = _initialThreshold;
    }

    function propose(uint256 _signerIndex, uint96 _feeRate) external hasSigners {
        _signerIndex = bound(_signerIndex, 0, signers.length - 1);
        _feeRate = uint96(bound(uint256(_feeRate), 0, 10_000));
        address signer = signers[_signerIndex];

        bytes memory data = abi.encodeCall(IPaymentProcessorStorage.setFeeRate, _feeRate);

        vm.prank(signer);
        bytes32 txHash = multisig.proposeTransaction(address(ppStorage), 0, data);

        allTxHashes.push(txHash);
        ghostApprovals[txHash][signer] = true;
        ghostNonce++;
    }

    function approve(uint256 _txIndex, uint256 _signerIndex) external hasSigners hasTx {
        _txIndex = bound(_txIndex, 0, allTxHashes.length - 1);
        _signerIndex = bound(_signerIndex, 0, signers.length - 1);

        bytes32 txHash = allTxHashes[_txIndex];
        address signer = signers[_signerIndex];

        if (multisig.getTransaction(txHash).status != PENDING) return;
        if (ghostApprovals[txHash][signer]) return;

        vm.prank(signer);
        multisig.approveTransaction(txHash);

        ghostApprovals[txHash][signer] = true;
    }

    function execute(uint256 _txIndex, uint256 _signerIndex) external hasSigners hasTx {
        _txIndex = bound(_txIndex, 0, allTxHashes.length - 1);
        _signerIndex = bound(_signerIndex, 0, signers.length - 1);

        bytes32 txHash = allTxHashes[_txIndex];
        address signer = signers[_signerIndex];

        if (multisig.getTransaction(txHash).status != APPROVED) return;

        vm.prank(signer);
        multisig.executeTransaction(txHash);

        executedTxHashes.push(txHash);
    }

    function governAddSigner(address _newSigner) external hasSigners {
        if (_newSigner == address(0)) return;
        for (uint256 i; i < signers.length; i++) {
            if (signers[i] == _newSigner) return;
        }

        bytes memory data = abi.encodeCall(IMultiSig.addSigner, _newSigner);
        if (!_proposeApproveExecute(data, address(multisig))) return;

        signers.push(_newSigner);
    }

    function governRemoveSigner(uint256 _removeIndex) external hasSigners {
        if (signers.length <= ghostThreshold) return;
        _removeIndex = bound(_removeIndex, 0, signers.length - 1);
        address toRemove = signers[_removeIndex];

        bytes memory data = abi.encodeCall(IMultiSig.removeSigner, toRemove);
        if (!_proposeApproveExecute(data, address(multisig))) return;

        signers[_removeIndex] = signers[signers.length - 1];
        signers.pop();
    }

    function governUpdateThreshold(uint256 _newThreshold) external hasSigners {
        _newThreshold = bound(_newThreshold, MINIMUM_THRESHOLD, signers.length);

        bytes memory data = abi.encodeCall(IMultiSig.updateThreshold, _newThreshold);
        if (!_proposeApproveExecute(data, address(multisig))) return;

        ghostThreshold = _newThreshold;
    }

    function getTxCount() external view returns (uint256) {
        return allTxHashes.length;
    }

    function getTxHash(uint256 _index) external view returns (bytes32) {
        return allTxHashes[_index];
    }

    function getExecutedTxCount() external view returns (uint256) {
        return executedTxHashes.length;
    }

    function getExecutedTxHash(uint256 _index) external view returns (bytes32) {
        return executedTxHashes[_index];
    }

    function getSignerCount() external view returns (uint256) {
        return signers.length;
    }

    function getGhostThreshold() external view returns (uint256) {
        return ghostThreshold;
    }

    function _proposeApproveExecute(bytes memory _data, address _target) internal returns (bool) {
        if (signers.length < ghostThreshold) return false;

        address proposer = signers[0];

        vm.prank(proposer);
        bytes32 txHash = multisig.proposeTransaction(_target, 0, _data);

        allTxHashes.push(txHash);
        ghostApprovals[txHash][proposer] = true;
        ghostNonce++;

        uint256 needed = ghostThreshold - 1;
        if (needed == 0) return false;

        for (uint256 i = 1; i < signers.length && needed > 0; i++) {
            vm.prank(signers[i]);
            multisig.approveTransaction(txHash);
            ghostApprovals[txHash][signers[i]] = true;
            needed--;
        }

        if (needed > 0) return false;

        vm.prank(proposer);
        multisig.executeTransaction(txHash);
        executedTxHashes.push(txHash);

        return true;
    }
}
