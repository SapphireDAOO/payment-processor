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

    /// @notice The address of the payment processor.
    address public immutable PAYMENT_PROCESSOR;

    /// @notice The invoice ID associated with the escrow.
    uint216 public immutable INVOICE_ID;

    /**
     * @notice Restricts access to the payment processor contract.
     * @dev Reverts with Unauthorized if the caller is not the payment processor.
     */
    modifier onlyPaymentProcessor() {
        _onlyPaymentProcessor();
        _;
    }

    /**
     * @notice Initializes the escrow contract and receives the deposited funds.
     * @dev Sets the immutable invoice ID and payment processor address. Any ETH sent with
     *      deployment is held by the contract and tracked off-chain via the `FundsDeposited` event.
     *      ERC20 escrows receive tokens via a direct transfer before or after deployment.
     * @param _invoiceId The unique identifier of the invoice associated with this escrow.
     * @param _paymentProcessorAddress The address of the payment processor contract managing the invoice.
     */
    constructor(uint216 _invoiceId, address _paymentProcessorAddress) payable {
        INVOICE_ID = _invoiceId;
        PAYMENT_PROCESSOR = _paymentProcessorAddress;
        emit FundsDeposited(_invoiceId, msg.value);
    }

    /// @inheritdoc IEscrow
    function withdraw(address _token, address _receiver, uint256 _amount) external onlyPaymentProcessor {
        if (_token == address(0)) {
            _receiver.safeTransferETH(_amount);
        } else {
            _token.safeTransfer(_receiver, _amount);
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
