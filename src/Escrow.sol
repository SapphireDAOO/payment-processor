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
    // review have a base escrow, extend for erc20 or native
    // add emergency withdraw for erc20
    // maybe allow direct transfer for native token
    using { SafeTransferLib.safeTransferETH, SafeTransferLib.safeTransfer } for address;

    /// @notice The address of the buyer associated with this escrow.
    address public immutable BUYER;

    /// @notice The address of the seller associated with this escrow.
    address public immutable SELLER;

    /// @notice The address of the payment processor.
    address public immutable PAYMENT_PROCESSOR;

    /// @notice The invoice ID associated with the escrow.
    uint216 public immutable INVOICE;

    /**
     * @notice Restricts access to the payment processor contract.
     * @dev Reverts with Unauthorized if the caller is not the payment processor.
     */
    modifier onlyPaymentProcessor() {
        _onlyPaymentProcessor();
        _;
    }

    /**
     * @notice Initializes the escrow contract with invoice details and deposits the funds.
     * @dev This constructor sets the invoice ID, creator, payer, and payment processor addresses, and records the sent
     * Ether as the balance.
     * @param _invoiceId The unique identifier of the invoice associated with this escrow.
     * @param _creator The address of the invoice creator.
     * @param _payer The address of the payer for the invoice.
     * @param _paymentProcessorAddress The address of the payment processor contract managing the invoice.
     */
    constructor(uint216 _invoiceId, address _creator, address _payer, address _paymentProcessorAddress) payable {
        INVOICE = _invoiceId;
        SELLER = _creator;
        BUYER = _payer;
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
