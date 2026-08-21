// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISweeper } from "./interface/ISweeper.sol";

import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/**
 * @title Sweeper
 * @notice Collects ERC20 tokens held by many addresses into a single destination in one transaction.
 * @dev Moves tokens with `transferFrom`, so each holder must have approved this contract first; the
 *      sweeper can never take more than a holder allowed, and under-approved holders are skipped. The destination is chosen per call, so only
 *      the PaymentProcessorStorage owner may sweep: any other caller could otherwise send approved
 *      balances to themselves.
 */
contract Sweeper is ISweeper {
    using { SafeTransferLib.safeTransferFrom, SafeTransferLib.balanceOf } for address;

    /// @notice Reference to the external Payment Processor storage contract, which holds the owner.
    IPaymentProcessorStorage public immutable ppStorage;

    /**
     * @notice Restricts function access to the owner of the PaymentProcessorStorage contract.
     * @dev Reverts with NotAuthorized() if the caller is not the owner.
     */
    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    /**
     * @notice Initializes the sweeper against the shared payment processor storage.
     * @param _paymentProcessorStorageAddress The storage contract whose owner may sweep.
     */
    constructor(address _paymentProcessorStorageAddress) {
        if (_paymentProcessorStorageAddress == address(0)) revert InvalidAddress();

        ppStorage = IPaymentProcessorStorage(_paymentProcessorStorageAddress);
    }

    /// @inheritdoc ISweeper
    function sweep(address _token, address[] calldata _from, uint256[] calldata _amounts, address _destination)
        external
        onlyOwner
        returns (uint256 total)
    {
        uint256 length = _from.length;
        if (length != _amounts.length) revert LengthMismatch();
        if (length == 0) revert EmptySweep();
        if (_token == address(0) || _destination == address(0)) revert InvalidAddress();

        for (uint256 i; i < length; i++) {
            uint256 amount = _amounts[i];
            if (amount == 0) continue;

            uint256 allowance = IERC20(_token).allowance(_from[i], address(this));
            if (amount > allowance) continue;

            _token.safeTransferFrom(_from[i], _destination, amount);
            total += amount;

            emit Swept(_token, _from[i], _destination, amount);
        }
    }

    /// @dev Reverts unless the caller owns the linked PaymentProcessorStorage.
    function _onlyOwner() internal view {
        if (msg.sender != PaymentProcessorStorage(address(ppStorage)).owner()) revert NotAuthorized();
    }

    /// @inheritdoc ISweeper
    function sweepable(address _token, address _holder) external view returns (uint256 amount) {
        uint256 balance = _token.balanceOf(_holder);
        uint256 allowance = IERC20(_token).allowance(_holder, address(this));

        return balance < allowance ? balance : allowance;
    }
}
