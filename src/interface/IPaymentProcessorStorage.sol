// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPaymentProcessorStorage {
    ///@notice Thrown when a caller attempts an action without the required authorization.
    error NotAuthorized();

    /**
     * @notice Updates the invoice ID counter.
     * @dev Should be implemented to increment or modify the invoice ID tracker as needed.
     */
    function updateInvoiceId(uint256 by) external returns (uint256);

    /**
     * @notice Sets or revokes authorization for a specific address.
     * @dev Only callable by the contract owner.
     * @param authorizedAddress The address to authorize or deauthorize.
     * @param authorized A boolean indicating whether to authorize (true) or deauthorize (false) the address.
     */
    function setAuthorizedAddress(address authorizedAddress, bool authorized) external;

    /**
     * @notice Sets the address that will receive fees collected from transactions.
     * @dev Callable only by the contract owner.
     * @param feeReceiverAddress The address to receive protocol fees.
     */
    function setFeeReceiver(address feeReceiverAddress) external;

    /**
     * @notice Updates the fee rate for seller payouts.
     * @dev Callable only by the contract owner.
     * @param _feeRate The new fee rate in basis points (1% = 100 basis points).
     */
    function setFeeRate(uint256 _feeRate) external;

    /**
     * @notice Returns the ID that will be assigned to the next invoice.
     * @return The next invoice ID.
     */
    function getNextInvoiceId() external view returns (uint256);

    /**
     * @notice Returns the total number of unique invoices created.
     * @return The count of invoices created so far.
     */
    function totalInvoiceCreated() external view returns (uint256);

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
}
