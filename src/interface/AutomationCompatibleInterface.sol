// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title Chainlink Automation Compatible Interface
 * @notice Interface for integrating smart contracts with Chainlink Automation (formerly Keepers).
 * @dev Implement this interface to allow off-chain bots to monitor and trigger on-chain actions.
 * @custom:source https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol
 */
interface AutomationCompatibleInterface {
    /**
     * @notice Checks if upkeep is needed.
     * @param _checkData Optional input data passed from the Automation registry.
     * @return upkeepNeeded Data to pass to `performUpkeep` if upkeep is needed.
     * @return performData Boolean indicating whether `performUpkeep` should be called.
     */
    function checkUpkeep(bytes calldata _checkData) external view returns (bool upkeepNeeded, bytes memory performData);

    /**
     * @notice Performs the actual upkeep work, such as executing a function or releasing funds.
     * @param _performData Data returned from `checkUpkeep` to customize the upkeep execution.
     */
    function performUpkeep(bytes calldata _performData) external;
}
