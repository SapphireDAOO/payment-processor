// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IEscrow } from "./interface/IEscrow.sol";

contract Escrow is IEscrow {
    /// @notice The address of the payer associated with this escrow.
    address public immutable payer;

    /// @notice The address of the creator associated with this escrow.
    address public immutable creator;

    /// @notice The address of the payment processor.
    address public immutable paymentProcessor;

    /// @notice The invoice ID associated with the escrow.
    uint256 public immutable invoiceId;

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
     * @param _paymentProcessor The address of the payment processor contract managing the invoice.
     */
    constructor(uint256 _invoiceId, address _creator, address _payer, address _paymentProcessor)
        payable
    {
        invoiceId = _invoiceId;
        creator = _creator;
        payer = _payer;
        paymentProcessor = _paymentProcessor;
        emit FundsDeposited(_invoiceId, msg.value);
    }

    /// @inheritdoc IEscrow
    function withdrawToCreator(address _creator) external onlyPaymentProcessor {
        uint256 bal = _withdraw(_creator);
        emit FundsWithdrawn(invoiceId, _creator, bal);
    }

    /// @inheritdoc IEscrow
    function refundToPayer(address _payer) external onlyPaymentProcessor {
        uint256 bal = _withdraw(_payer);
        emit FundsRefunded(invoiceId, _payer, bal);
    }

    /**
     * @notice Withdraws the entire balance of the contract to a specified address.
     * @dev This function attempts to transfer the full balance of the contract to the provided address.
     *      The balance is returned to provide feedback on the transaction.
     * @param _to The address to which the funds should be sent.
     * @return The amount of funds (in wei) that was transferred.
     */
    function _withdraw(address _to) internal returns (uint256) {
        uint256 bal = address(this).balance;
        (bool success,) = _to.call{ value: bal }("");
        if (!success) {
            revert TransferFailed();
        }
        return bal;
    }

    function _onlyPaymentProcessor() internal view {
        if (msg.sender != paymentProcessor) {
            revert Unauthorized();
        }
    }
}
