// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IPaymentProcessorStorage
 * @notice Interface for storage layer used by payment processor contracts.
 * @dev Allows interaction with invoice data
 */
interface IPaymentProcessorStorage {
    /// @notice Thrown when a caller attempts an action without the required authorization.
    error NotAuthorized();

    /// @notice Thrown when the hold period provided is zero, which is invalid.
    error HoldPeriodCanNotBeZero();

    /// @notice Thrown when the provided fee rate exceeds the maximum allowed (10,000 basis points = 100%).
    error InvalidFeeRate();

    /// @notice Holds core configuration parameters for the contract.
    /// @param owner The address authorized to modify configuration parameters.
    /// @param feeRate Platform fee rate in basis points (BPS). i.e 100 BPS = 1%; 10,000 BPS = 100%.
    /// @param feeReceiver Address that receives platform fees.
    /// @param defaultHoldPeriod The default hold period for funds in escrow, measured in seconds.
    /// @param marketplace Address authorized to interact with invoice creation and specific management functions.
    /// @param gasThreshold The minimum amount of gas that must remain to continue processing tasks.
    struct Configuration {
        address owner;
        uint96 feeRate;
        address feeReceiver;
        uint96 defaultHoldPeriod;
        address marketplace;
        uint96 gasThreshold;
    }

    /**
     * @notice Updates the invoice nonce counter.
     * @dev Only callable by authorized addresses (e.g., processor contracts). Increments
     *      the internal nonce by the provided amount.
     * @param _by The amount to increment the invoice nonce by.
     * @return totalInvoices The updated total number of invoices created.
     */
    function updateInvoiceNonce(uint216 _by) external returns (uint216 totalInvoices);

    /**
     * @notice Sets or revokes authorization for a specific address.
     * @dev Only callable by the contract owner.
     * @param _authorizedAddress The address to authorize or deauthorize.
     * @param _authorized Whether the address is authorized.
     */
    function setAuthorizedAddress(address _authorizedAddress, bool _authorized) external;

    /**
     * @notice Updates the default hold period for all new invoices.
     * @dev Only callable by the contract owner. Reverts with HoldPeriodCanNotBeZero if zero.
     * @param _newDefaultHoldPeriod The new default hold period in seconds.
     */
    function setDefaultHoldPeriod(uint96 _newDefaultHoldPeriod) external;

    /**
     * @notice Updates the marketplace address allowed to perform privileged operations.
     * @dev Callable only by the contract owner.
     * @param _marketplaceAddress The new marketplace address.
     */
    function setMarketplaceAddress(address _marketplaceAddress) external;

    /**
     * @notice Sets the address that will receive fees collected from transactions.
     * @dev Callable only by the contract owner.
     * @param _feeReceiverAddress The address to receive protocol fees.
     */
    function setFeeReceiver(address _feeReceiverAddress) external;

    /**
     * @notice Updates the fee rate for seller payouts.
     * @dev Callable only by the contract owner.
     * @param _feeRate The new fee rate in basis points (1% = 100 basis points).
     */
    function setFeeRate(uint96 _feeRate) external;

    /**
     * @notice Updates the gas threshold used in automated upkeep logic.
     * @dev Only callable by the contract owner. This threshold determines the minimum gas
     *      required to continue processing during `performUpkeep`.
     * @param _newGasThreshold The new gas threshold value (in units of gas).
     */
    function setGasThreshold(uint96 _newGasThreshold) external;

    /**
     * @notice Updates the window of time after invoice creation during which a buyer can pay.
     * @dev Only callable by the contract owner. Once this period elapses, the invoice is
     *      considered expired and payment attempts will no longer be possible.
     * @param _newValidityDuration The new validity window in seconds.
     */
    function setPaymentValidityDuration(uint256 _newValidityDuration) external;

    /**
     * @notice Returns the nonce that will be assigned to the next invoice.
     * @return nextInvoiceNonceValue The next invoice nonce value.
     */
    function getNextInvoiceNonce() external view returns (uint216 nextInvoiceNonceValue);

    /**
     * @notice Returns the total number of unique invoices created.
     * @return totalInvoices The total number of invoices created.
     */
    function totalInvoiceCreated() external view returns (uint216 totalInvoices);

    /**
     * @notice Returns the window of time after invoice creation during which a buyer can pay.
     * @return validDuration The payment validity window in seconds.
     */
    function getPaymentValidityDuration() external view returns (uint256 validDuration);

    /**
     * @notice Returns the current platform fee rate in basis points.
     * @return feeRate The platform fee rate in basis points.
     */
    function getFeeRate() external view returns (uint256 feeRate);

    /**
     * @notice Returns the address that receives collected platform fees.
     * @return feeReceiver The fee receiver address.
     */
    function getFeeReceiver() external view returns (address feeReceiver);

    /**
     * @notice Returns the address of the authorized marketplace contract.
     * @return marketplace The marketplace address.
     */
    function getMarketplace() external view returns (address marketplace);

    /**
     * @notice Returns the default hold period for invoices.
     * @return defaultHoldPeriod The default hold period in seconds.
     */
    function getDefaultHoldPeriod() external view returns (uint256 defaultHoldPeriod);

    /**
     * @notice Returns the current gas threshold used to limit the execution loop in automated upkeep.
     * @dev This threshold is typically used to prevent out-of-gas errors during batch operations in Chainlink Automation.
     * @return gasThreshold The current gas threshold value.
     */
    function getGasThreshold() external view returns (uint256 gasThreshold);
}
