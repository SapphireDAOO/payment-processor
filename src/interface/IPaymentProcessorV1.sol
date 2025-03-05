// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Invoice } from "../Types/InvoiceType.sol";

/**
 * @title Payment processor interface
 * @notice @notice This interface provides functionality for creating and managing invoices.
 */
interface IPaymentProcessorV1 {
    /// @notice Thrown when the provided value is lower than the required minimum.
    error ValueIsTooLow();

    /// @notice Thrown when a fund transfer fails.
    error TransferFailed();

    /// @notice Thrown when an action is attempted on an invoice that has not been paid.
    error InvoiceNotPaid();

    /// @notice Thrown when the payment amount exceeds the required invoice amount.
    error ExcessivePayment();

    /// @notice Thrown when the fee value provided is zero.
    error FeeValueCanNotBeZero();

    /// @notice Thrown when the hold period provided is zero, which is invalid.
    error HoldPeriodCanNotBeZero();

    /// @notice Thrown when a zero address (`address(0)`) is provided.
    error ZeroAddressIsNotAllowed();

    /// @notice Thrown when the invoice price is below the allowed minimum.
    error InvoicePriceIsTooLow();

    /// @notice Thrown when the invoice is in an invalid state for the requested action.
    /// @param invoiceState The current state of the invoice, which caused the operation to fail
    error InvalidInvoiceState(uint256 invoiceState);

    /// @notice Thrown when the invoice is no longer valid (e.g., cancelled or expired).
    error InvoiceIsNoLongerValid();

    /// @notice Thrown when an invoice that has already been fully paid is attempted to be paid again.
    error InvoiceAlreadyPaid();

    /// @notice Thrown when an action is attempted on a non-existent invoice.
    error InvoiceDoesNotExist();

    /// @notice Thrown when the creator attempts to take action on an invoice after the acceptance window has expired.
    error AcceptanceWindowExceeded();

    /// @notice Thrown when the creator of an invoice attempts to pay for their own invoice.
    error CreatorCannotPayOwnedInvoice();

    /// @notice Reverts when an invoice is not eligible for a refund to the creator.
    error InvoiceNotEligibleForRefund();

    /// @notice Thrown when the hold period for an invoice has not yet been exceeded.
    error HoldPeriodHasNotBeenExceeded();

    /// @notice Thrown when attempting to set a custom hold period that is less than the default hold period.
    error HoldPeriodShouldBeGreaterThanDefault();

    /// @notice Error thrown when attempting to release an invoice that has already been released.
    error InvoiceHasAlreadyBeenReleased();

    /**
     * @notice Creates a new invoice with a specified price.
     * @param _invoicePrice The price of the invoice in wei.
     * @return The ID of the newly created invoice.
     */
    function createInvoice(uint256 _invoicePrice) external returns (uint256);

    /**
     * @notice Makes a payment for a specific invoice.
     * @param _invoiceId The ID of the invoice being paid.
     * @return The address of the escrow contract managing the payment.
     */
    function makeInvoicePayment(uint256 _invoiceId) external payable returns (address);

    /**
     * @notice Allows the creator of the invoice to accept or reject it.
     * @param _invoiceId The ID of the invoice.
     * @param _state True to accept the invoice, false to reject.
     */
    function creatorsAction(uint256 _invoiceId, bool _state) external;

    /**
     * @notice Cancels an existing invoice.
     * @dev Only callable by the invoice creator.
     * @param _invoiceId The ID of the invoice to cancel.
     */
    function cancelInvoice(uint256 _invoiceId) external;

    /**
     * @notice Releases the funds held in escrow for a specific invoice to the creator.
     * @param _invoiceId The ID of the invoice for which funds are released.
     */
    function releaseInvoice(uint256 _invoiceId) external;

    /**
     * @notice Sets a custom hold period for a specific invoice.
     * @dev Overrides the default hold period for this invoice.
     * @param _invoiceId The ID of the invoice.
     * @param _holdPeriod The new hold period in seconds.
     */
    function setInvoiceHoldPeriod(uint256 _invoiceId, uint32 _holdPeriod) external;

    /**
     * @notice Updates the address of the fee receiver.
     * @dev Only callable by the contract owner.
     * @param _newFeeReceiver The new address to receive fees.
     */
    function setFeeReceiversAddress(address _newFeeReceiver) external;

    /**
     * @notice Refunds the creator of a specific invoice.
     * @dev This function allows the payer to be refund if the acceptance window has not been exceeded
     *      and the invoice is eligible for a refund. The refund will be processed through the escrow contract.
     * @param _invoiceId The ID of the invoice to be refunded.
     *
     */
    function refundPayerAfterWindow(uint256 _invoiceId) external;

    /**
     * @notice Updates the default hold period for all new invoices.
     * @dev Only callable by the contract owner.
     * @param _newDefaultHoldPeriod The new default hold period in seconds.
     */
    function setDefaultHoldPeriod(uint256 _newDefaultHoldPeriod) external;

    /**
     * @notice Updates the fee for using Blockhead service.
     * @dev Only callable by the contract owner.
     * @param _newFee The new fee amount in wei.
     */
    function setFee(uint256 _newFee) external;

    /**
     * @notice Gets the current fee for invoice creation.
     * @return The fee amount in wei.
     */
    function getFee() external view returns (uint256);

    /**
     * @notice Gets the current fee receiver address.
     * @return The address of the fee receiver.
     */
    function getFeeReceiver() external view returns (address);

    /**
     * @notice Gets the current invoice ID counter.
     * @return The current invoice ID.
     */
    function getNextInvoiceId() external view returns (uint256);

    /**
     * @notice Gets the default hold period for invoices.
     * @return The default hold period in seconds.
     */
    function getDefaultHoldPeriod() external view returns (uint256);

    /**
     * @notice Returns the total number of invoices created.
     * @return The total count of invoices created as a `uint256` value.
     */
    function totalInvoiceCreated() external view returns (uint256);

    /**
     * @notice Retrieves detailed data for a specific invoice.
     * @param _invoiceId The ID of the invoice.
     * @return A struct containing the invoice's details.
     */
    function getInvoiceData(uint256 _invoiceId) external view returns (Invoice memory);

    /**
     * @notice Allows the fee receiver to withdraw the contract's balance.
     * @dev The caller must be either the contract owner or the fee receiver.
     */
    function withdrawFees() external;

    /**
     * @notice Emitted when a new invoice is created.
     * @param creator The address of the invoice creator.
     * @param invoiceId The unique ID of the created invoice.
     * @param price The price of the invoice that was created.
     */
    event InvoiceCreated(uint256 indexed invoiceId, address indexed creator, uint256 indexed price);

    /**
     * @notice Emitted when an invoice payment is made.
     * @param invoiceId The unique ID of the accepted invoice.
     * @param amountPaid The amount paid towards the invoice in wei.
     */
    event InvoicePaid(uint256 indexed invoiceId, address indexed payer, uint256 indexed amountPaid);

    /**
     * @notice Emitted when an invoice is rejected by the creator.
     * @param invoiceId The unique ID of the rejected invoice.
     */
    event InvoiceRejected(uint256 indexed invoiceId);

    /**
     * @notice Emitted when an invoice is refunded to the payer.
     * @param invoiceId The unique ID of the rejected invoice.
     */
    event InvoiceRefunded(uint256 indexed invoiceId);

    /**
     * @notice Emitted when an invoice is accepted by the creator.
     * @param invoiceId The unique ID of the accepted invoice.
     */
    event InvoiceAccepted(uint256 indexed invoiceId);

    /**
     * @notice Emitted when an invoice is canceled.
     * @param invoiceId The unique ID of the canceled invoice.
     */
    event InvoiceCanceled(uint256 indexed invoiceId);

    /**
     * @notice Emitted when an invoice is released (funds disbursed from escrow).
     * @param invoiceId The unique ID of the released invoice.
     */
    event InvoiceReleased(uint256 indexed invoiceId);

    /**
     * @notice Emitted when the hold period of a given invoice is updated to a new timestamp.
     * @param invoiceId The ID of the invoice whose hold period was updated.
     * @param releaseDueTimestamp The new hold period expressed as a UNIX timestamp.
     */
    event UpdateHoldPeriod(uint256 indexed invoiceId, uint256 indexed releaseDueTimestamp);
}
