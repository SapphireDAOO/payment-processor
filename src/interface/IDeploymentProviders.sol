// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/**
 * @title IAuthorizedAddressProvider
 * @notice Implemented by contracts that deploy Notes.
 * @dev Notes reads its writers from its deployer (`msg.sender`) during construction; they cannot change afterwards.
 */
interface IAuthorizedAddressProvider {
    /// @notice Returns the addresses Notes should authorize at construction.
    function authorizedAddresses() external view returns (address[] memory authorized);
}

/**
 * @title IPendingProcessorProvider
 * @notice Implemented by contracts that deploy PaymentAutomation.
 * @dev PaymentAutomation reads its processor from its deployer (`msg.sender`) during construction, which keeps
 *      the processor out of its init code so both addresses can be predicted.
 */
interface IPendingProcessorProvider {
    /// @notice Returns the SimplePaymentProcessor the PaymentAutomation being constructed should drive.
    function pendingProcessor() external view returns (address processor);
}
