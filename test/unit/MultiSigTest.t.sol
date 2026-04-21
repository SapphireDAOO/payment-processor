// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MultiSigSetUp } from "../utils/MultiSigSetUp.sol";
import { IMultiSig } from "../../src/interface/IMultiSig.sol";

import { PENDING, APPROVED, EXECUTED } from "src/constants/MultiSig.sol";

contract MultiSigTest is MultiSigSetUp {
    function test_initialState() public view { }

    function test_proposeTransaction() public { }

    function test_proposeTransactionNonSignerReverts() public { }

    function test_proposeTransaction_revertsIfDuplicateNonce() public { }

    function test_proposeTransaction_revertsIfZeroTarget() public { }

    function test_approveTransaction() public { }

    function test_approveTransactionNonSignerReverts() public { }

    function test_approveTransaction_revertsIfDoesNotExist() public { }

    function test_approveTransaction_revertsIfAlreadyApproved() public { }

    function test_approveTransactionThresholdReached() public { }

    function test_executeTransaction() public { }

    function test_executeTransactionNonSignerReverts() public { }

    function test_executeTransaction_revertsIfNotApproved() public { }

    function test_executeTransaction_revertsIfAlreadyExecuted() public { }

    function test_executeTransaction_revertsIfCallFails() public { }

    function test_addSigner() public { }

    function test_addSignerNotSelfReverts() public { }

    function test_addSigner_revertsIfAlreadySigner() public { }

    function test_removeSigner() public { }

    function test_removeSignerNotSelfReverts() public { }

    function test_removeSigner_revertsIfDropsBelowThreshold() public { }

    function test_updateThreshold() public { }

    function test_updateThresholdNotSelfReverts() public { }

    function test_updateThreshold_revertsIfInvalid() public { }

    function test_constructorInsufficientSignersReverts() public { }

    function test_constructorInvalidThresholdReverts() public { }
}
