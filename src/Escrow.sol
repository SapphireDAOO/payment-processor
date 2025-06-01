// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IEscrow } from "./interface/IEscrow.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

contract Escrow is IEscrow {
    using SafeTransferLib for address;

    /// @notice The address of the buyer associated with this escrow.
    address public immutable buyer;

    /// @notice The address of the seller associated with this escrow.
    address public immutable seller;

    /// @notice The address of the payment processor.
    address public immutable paymentProcessor;

    /// @notice The invoice ID associated with the escrow.
    bytes32 public immutable invoice;

    modifier onlyPaymentProcessor() {
        _onlyPaymentProcessor();
        _;
    }

    /**
     * @notice Initializes the escrow contract with invoice details and deposits the funds.
     * @dev This constructor sets the invoice ID, creator, payer, and payment processor addresses, and records the sent
     * Ether as the balance.
     * @param invoiceKey The unique identifier of the invoice associated with this escrow.
     * @param creator The address of the invoice creator.
     * @param payer The address of the payer for the invoice.
     * @param paymentProcessorAddress The address of the payment processor contract managing the invoice.
     */
    constructor(bytes32 invoiceKey, address creator, address payer, address paymentProcessorAddress) payable {
        invoice = invoiceKey;
        seller = creator;
        buyer = payer;
        paymentProcessor = paymentProcessorAddress;
        emit FundsDeposited(invoiceKey, msg.value);
    }

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
        if (msg.sender != paymentProcessor) {
            revert Unauthorized();
        }
    }
}
