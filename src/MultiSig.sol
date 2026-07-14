// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IMultiSig } from "./interface/IMultiSig.sol";
import { PROPOSED, APPROVED, EXECUTED, CANCELED, MINIMUM_THRESHOLD, MINIMUM_SIGNERS } from "./constants/MultiSig.sol";
import { LibCall } from "solady/utils/LibCall.sol";

/**
 * @title MultiSig
 * @notice Multisignature governance contract for privileged payment processor administration.
 *         Replaces a single-owner key with collective authorization across a defined signer set.
 *         Administrative calls (fee updates, decision windows, locked fund recovery, etc.) to
 *         SimplePaymentProcessor, IntermediatedPaymentProcessor and PaymentProcessorStorage must pass through this contract.
 */
contract MultiSig is IMultiSig {
    using LibCall for address;

    /// @notice Tracks whether an address is an authorized signer.
    mapping(address signer => bool authorized) private signers;

    /// @notice Minimum number of approvals required to transition a transaction to APPROVED.
    uint256 private threshold;

    /// @notice Total number of registered signers.
    uint256 private signerCount;

    /// @notice All proposed transactions, keyed by their keccak256 hash.
    mapping(bytes32 txHash => Transaction data) private transactions;

    /// @notice Per-transaction approval record.
    mapping(bytes32 txHash => mapping(address signer => bool approved)) private approvals;

    /// @notice Auto-incrementing nonce assigned to each new transaction proposal.
    uint256 private nonce;

    /**
     * @notice Restricts the function to registered signers only.
     * @dev Reverts with NotSigner if the caller is not a registered signer.
     */
    modifier onlySigner() {
        _onlySigner();
        _;
    }

    /**
     * @notice Restricts the function to the multisig contract itself.
     * @dev Administrative changes must be executed via an approved multisig transaction.
     *      Reverts with NotSelf if the caller is not address(this).
     */
    modifier onlySelf() {
        _onlySelf();
        _;
    }

    /**
     * @notice Deploys the multisig with an initial signer set and approval threshold.
     * @param _initialSigners Array of addresses to register as signers (minimum 2).
     * @param _initialThreshold Minimum approvals required for execution; must be >= 1
     *        and <= _initialSigners.length.
     */
    constructor(address[] memory _initialSigners, uint256 _initialThreshold) {
        uint256 len = _initialSigners.length;
        if (len < MINIMUM_SIGNERS) revert InsufficientSigners();
        if (_initialThreshold < MINIMUM_THRESHOLD || _initialThreshold > len) revert InvalidThreshold();

        for (uint256 i; i < len; i++) {
            signers[_initialSigners[i]] = true;
            emit SignerAdded(_initialSigners[i]);
        }
        signerCount = len;
        threshold = _initialThreshold;
    }

    /// @inheritdoc IMultiSig
    function proposeTransaction(address _target, uint256 _value, bytes calldata _data)
        external
        onlySigner
        returns (bytes32 txHash)
    {
        if (_target == address(0)) revert InvalidTarget();

        nonce++;
        uint256 newNonce = nonce;

        Transaction memory txn = Transaction({
            target: _target, value: _value, nonce: newNonce, data: _data, status: PROPOSED, approvalCount: 1
        });

        txHash = keccak256(abi.encode(_target, _data, newNonce));

        transactions[txHash] = txn;
        approvals[txHash][msg.sender] = true;

        emit TransactionProposed(txHash, _target, _value, _data, newNonce, msg.sender);
    }

    /// @inheritdoc IMultiSig
    function approveTransaction(bytes32 _txHash) external onlySigner {
        Transaction memory txn = transactions[_txHash];
        if (txn.nonce == 0) revert TransactionDoesNotExist();
        if (txn.status != PROPOSED) revert AlreadyApproved();
        if (approvals[_txHash][msg.sender]) revert AlreadyApprovedByThisSigner();

        uint256 newApprovalCount = txn.approvalCount + 1;
        transactions[_txHash].approvalCount = newApprovalCount;
        approvals[_txHash][msg.sender] = true;

        if (newApprovalCount >= threshold) {
            transactions[_txHash].status = APPROVED;
            emit TransactionApproved(_txHash);
        }

        emit ApprovalAdded(_txHash, msg.sender, newApprovalCount);
    }

    /// @inheritdoc IMultiSig
    function executeTransaction(bytes32 _txHash) external onlySigner returns (bytes memory) {
        Transaction memory txn = transactions[_txHash];
        if (txn.status != APPROVED) revert TransactionNotApproved();
        transactions[_txHash].status = EXECUTED;

        emit TransactionExecuted(_txHash, msg.sender);
        return txn.target.callContract(txn.data);
    }

    /// @inheritdoc IMultiSig
    function cancelTransaction(bytes32 _txHash) external onlySelf {
        Transaction memory txn = transactions[_txHash];
        if (txn.nonce == 0) revert TransactionDoesNotExist();
        if (txn.status != PROPOSED && txn.status != APPROVED) revert TransactionNotProposedOrApproved();

        transactions[_txHash].status = CANCELED;
        emit TransactionCanceled(_txHash);
    }

    /// @inheritdoc IMultiSig
    function addSigner(address _signer) external onlySelf {
        if (signers[_signer]) revert AlreadyASigner();

        signerCount++;
        signers[_signer] = true;
        emit SignerAdded(_signer);
    }

    /// @inheritdoc IMultiSig
    function removeSigner(address _signer) external onlySelf {
        if (!signers[_signer]) revert NotASigner();
        if (threshold > signerCount - 1) revert SignerCountBelowThreshold();

        signerCount--;
        signers[_signer] = false;
        emit SignerRemoved(_signer);
    }

    /// @inheritdoc IMultiSig
    function updateThreshold(uint256 _newThreshold) external onlySelf {
        if (_newThreshold == 0) revert ThresholdCannotBeZero();
        if (_newThreshold > signerCount) revert SignerCountBelowThreshold();
        if (_newThreshold < MINIMUM_THRESHOLD) revert InvalidThreshold();

        emit ThresholdUpdated(threshold, _newThreshold);
        threshold = _newThreshold;
    }

    /// @inheritdoc IMultiSig
    function getTransaction(bytes32 _txHash) external view returns (Transaction memory) {
        return transactions[_txHash];
    }

    /// @inheritdoc IMultiSig
    function hasApproved(bytes32 _txHash, address _signer) external view returns (bool) {
        return approvals[_txHash][_signer];
    }

    /// @inheritdoc IMultiSig
    function isSigner(address _account) external view returns (bool) {
        return signers[_account];
    }

    /// @inheritdoc IMultiSig
    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    /// @inheritdoc IMultiSig
    function getSignerCount() external view returns (uint256) {
        return signerCount;
    }

    /// @inheritdoc IMultiSig
    function getNonce() external view returns (uint256) {
        return nonce;
    }

    /**
     * @notice Ensures the caller is a registered signer.
     * @dev Reverts with NotSigner if the caller is not authorized.
     */
    function _onlySigner() internal view {
        if (!signers[msg.sender]) revert NotSigner();
    }

    /**
     * @notice Ensures the caller is the multisig contract itself.
     * @dev Reverts with NotSelf if the caller is not address(this).
     */
    function _onlySelf() internal view {
        if (msg.sender != address(this)) revert NotSelf();
    }
}
