// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { MultiSigSetUp } from "../utils/MultiSigSetUp.sol";
import { MultiSigHandler } from "./handlers/MultiSigHandler.sol";

import { PENDING, APPROVED, EXECUTED, CANCELED } from "src/constants/MultiSig.sol";

contract MultiSigInvariant is StdInvariant, MultiSigSetUp {
    MultiSigHandler handler;

    function setUp() public override {
        super.setUp();

        address[] memory initialSigners = new address[](INITIAL_SIGNER_COUNT);
        initialSigners[0] = signerOne;
        initialSigners[1] = signerTwo;
        initialSigners[2] = signerThree;

        handler = new MultiSigHandler(multisig, ppStorage, initialSigners, INITIAL_THRESHOLD);

        targetContract(address(handler));
    }

    function invariant_thresholdBounds() external view {
        uint256 t = multisig.getThreshold();
        assertGe(t, 1);
        assertLe(t, multisig.getSignerCount());
    }

    function invariant_executedStatusIsPermanent() external view {
        uint256 count = handler.getExecutedTxCount();
        for (uint256 i; i < count; i++) {
            bytes32 txHash = handler.getExecutedTxHash(i);
            assertEq(multisig.getTransaction(txHash).status, EXECUTED);
        }
    }

    function invariant_validTransactionStatus() external view {
        uint256 count = handler.getTxCount();
        for (uint256 i; i < count; i++) {
            bytes32 txHash = handler.getTxHash(i);
            uint8 status = multisig.getTransaction(txHash).status;
            assertTrue(status == PENDING || status == APPROVED || status == EXECUTED || status == CANCELED);
        }
    }

    function invariant_canceledStatusIsPermanent() external view {
        uint256 count = handler.getCanceledTxCount();
        for (uint256 i; i < count; i++) {
            bytes32 txHash = handler.getCanceledTxHash(i);
            assertEq(multisig.getTransaction(txHash).status, CANCELED);
        }
    }

}
