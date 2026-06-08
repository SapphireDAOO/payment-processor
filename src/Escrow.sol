// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IEscrow } from "./interface/IEscrow.sol";

/**
 * @title Escrow
 * @notice Implements the core escrow functionality for holding and releasing payments between buyers and sellers.
 * @dev Conforms to the IEscrow interface. Used by the payment processor for individual invoice escrow handling.
 */
contract Escrow is IEscrow {
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
     *      deployment is held by the contract and tracked off-chain via the `Deposited` event.
     *      ERC20 escrows receive tokens via a direct transfer before or after deployment.
     * @param _invoiceId The unique identifier of the invoice associated with this escrow.
     * @param _paymentProcessorAddress The address of the payment processor contract managing the invoice.
     */
    constructor(uint216 _invoiceId, address _paymentProcessorAddress) payable {
        INVOICE_ID = _invoiceId;
        PAYMENT_PROCESSOR = _paymentProcessorAddress;
        emit Deposited(_invoiceId, msg.value);
    }

    /// @inheritdoc IEscrow
    function withdraw(address _token, address _receiver, uint256 _amount)
        external
        onlyPaymentProcessor
        returns (bool success)
    {
        if (_token == address(0)) {
            (success,) = _receiver.call{ value: _amount }("");
        } else {
            bytes4 transferSelector = 0xa9059cbb;
            bytes memory ret;
            (success, ret) = _token.call(abi.encodeWithSelector(transferSelector, _receiver, _amount));
            if (success && ret.length > 0) success = abi.decode(ret, (bool));
        }

        emit Withdrawn(_token, _receiver, _amount);
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
