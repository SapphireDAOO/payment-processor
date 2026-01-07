// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IEscrow } from "./interface/IEscrow.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/**
 * @title Escrow
 * @notice Implements the core escrow functionality for holding and releasing payments between buyers and sellers.
 * @dev Conforms to the IEscrow interface. Used by the payment processor for individual invoice escrow handling.
 */
contract Escrow is IEscrow {
    using { SafeTransferLib.safeTransferETH, SafeTransferLib.safeTransfer } for address;

    /// @notice The address of the buyer associated with this escrow.
    address public immutable BUYER;

    /// @notice The address of the seller associated with this escrow.
    address public immutable SELLER;

    /// @notice The address of the payment processor.
    address public immutable PAYMENT_PROCESSOR;

    /// @notice The invoice ID associated with the escrow.
    uint256 public immutable INVOICE;

    /**
     * @notice Restricts access to the payment processor contract.
     * @dev Reverts with Unauthorized if the caller is not the payment processor.
     */
    modifier onlyPaymentProcessor() {
        _onlyPaymentProcessor();
        _;
    }

    /// @notice Handles unknown calls and accepts ETH.
    fallback() external payable { }

    /// @notice Accepts plain ETH transfers.
    receive() external payable { }

    /**
     * @notice Initializes the escrow contract with invoice details and deposits the funds.
     * @dev This constructor sets the invoice ID, creator, payer, and payment processor addresses, and records the sent
     * Ether as the balance.
     * @param orderId The unique identifier of the invoice associated with this escrow.
     * @param creator The address of the invoice creator.
     * @param payer The address of the payer for the invoice.
     * @param paymentProcessorAddress The address of the payment processor contract managing the invoice.
     */
    constructor(uint216 orderId, address creator, address payer, address paymentProcessorAddress) payable {
        INVOICE = orderId;
        SELLER = creator;
        BUYER = payer;
        PAYMENT_PROCESSOR = paymentProcessorAddress;
        emit FundsDeposited(orderId, msg.value);
    }

    /// @inheritdoc IEscrow
    function withdraw(address token, address receiver, uint256 amount) external onlyPaymentProcessor {
        if (token == address(0)) {
            receiver.safeTransferETH(amount);
        } else {
            token.safeTransfer(receiver, amount);
        }
    }

    /**
     * @notice Ensures that the caller is the authorized payment processor.
     * @dev Reverts with `Unauthorized` if `msg.sender` is not equal to `paymentProcessor`.
     */
    function _onlyPaymentProcessor() internal view {
        if (msg.sender != PAYMENT_PROCESSOR) {
            revert Unauthorized();
        }
    }
}
