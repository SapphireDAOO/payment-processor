// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPaymentProcessorStorage {
    /// @notice Thrown when a low-level external call fails.
    error CallFailed();

    ///@notice Thrown when a caller attempts an action without the required authorization.
    error NotAuthorized();

    /// @notice Thrown when the hold period provided is zero, which is invalid.
    error HoldPeriodCanNotBeZero();

    /// @notice Holds core configuration parameters for the contract.
    struct Configuration {
        /// @notice The address authorized to modify configuration parameters.
        address owner;
        /// @notice Address that receives platform fees upon seller payout.
        address feeReceiver;
        /// @notice Address authorized to interact with invoice creation and specific management functions.
        address marketplace;
        /// @notice Platform fee rate in basis points (BPS). i.e 100 BPS = 1%; 10,000 BPS = 100%.
        uint256 feeRate;
        /// @notice The default hold period for funds in escrow, measured in seconds.
        uint256 defaultHoldPeriod;
    }

    /**
     * @notice Updates the invoice ID counter.
     * @dev Should be implemented to increment or modify the invoice ID tracker as needed.
     */
    function updateInvoiceId(uint216 by) external returns (uint216);

    /**
     * @notice Sets or revokes authorization for a specific address.
     * @dev Only callable by the contract owner.
     * @param authorizedAddress The address to authorize or deauthorize.
     * @param authorized A boolean indicating whether to authorize (true) or deauthorize (false) the address.
     */
    function setAuthorizedAddress(address authorizedAddress, bool authorized) external;

    /**
     * @notice Updates the default hold period for all new invoices.
     * @dev Only callable by the contract owner.
     * @param newDefaultHoldPeriod The new default hold period in seconds.
     */
    function setDefaultHoldPeriod(uint256 newDefaultHoldPeriod) external;

    /**
     * @notice Updates the marketplace address allowed to perform privileged operations.
     * @dev Callable only by the contract owner.
     * @param marketplaceAddress The new marketplace address.
     */
    function setMarketplace(address marketplaceAddress) external;

    /**
     * @notice Sets the address that will receive fees collected from transactions.
     * @dev Callable only by the contract owner.
     * @param feeReceiverAddress The address to receive protocol fees.
     */
    function setFeeReceiver(address feeReceiverAddress) external;

    /**
     * @notice Updates the fee rate for seller payouts.
     * @dev Callable only by the contract owner.
     * @param feeRate The new fee rate in basis points (1% = 100 basis points).
     */
    function setFeeRate(uint256 feeRate) external;

    // /**
    //  * @notice Executes a low-level call to an invoice contract.
    //  * @dev Used by ppStorage to trigger state changes (e.g., setting release times)
    //  *      in external invoice contracts. The target and calldata must be properly
    //  *      encoded off-chain. Only callable by authorized contracts or managers.
    //  * @param target The address of the invoice contract to call.
    //  * @param data ABI-encoded calldata including the function selector and arguments.
    //  * @return result The raw returned data from the low-level call.
    //  */
    // function execute(address target, bytes calldata data) external returns (bytes memory);

    /**
     * @notice Returns the ID that will be assigned to the next invoice.
     * @return The next invoice ID.
     */
    function getNextInvoiceId() external view returns (uint216);

    /**
     * @notice Returns the total number of unique invoices created.
     * @return The count of invoices created so far.
     */
    function totalInvoiceCreated() external view returns (uint216);

    /**
     * @notice Returns the current platform fee rate in basis points.
     * @return The fee rate, where 10,000 basis points = 100%.
     */
    function getFeeRate() external view returns (uint256);

    /**
     * @notice Returns the address that receives collected platform fees.
     * @return The fee receiver address.
     */
    function getFeeReceiver() external view returns (address);

    /**
     * @notice Returns the address of the authorized marketplace contract.
     * @return The marketplace address allowed to manage invoice creation and updates.
     */
    function getMarketplace() external view returns (address);

    /**
     * @notice Gets the default hold period for invoices.
     * @return The default hold period in seconds.
     */
    function getDefaultHoldPeriod() external view returns (uint256);
}
