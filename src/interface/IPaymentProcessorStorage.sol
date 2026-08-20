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

    /// @notice Thrown when the provided fee rate exceeds the maximum allowed (10,000 basis points = 100%).
    error InvalidFeeRate();

    /// @notice Thrown when pausing a system that is already paused, or that has an unresolved emergency pause.
    error AlreadyPaused();

    /// @notice Thrown when unpausing a system that is not paused.
    error NotPaused();

    /// @notice Thrown when approving an emergency pause that is absent or already expired.
    error NoActiveEmergencyPause();

    /// @notice Thrown when setting the fee signer to the zero address.
    error InvalidFeeSigner();

    /// @notice Holds core configuration parameters for the contract.
    /// @param owner The address authorized to modify configuration parameters.
    /// @param feeRate Platform fee rate in basis points (BPS). i.e 100 BPS = 1%; 10,000 BPS = 100%.
    /// @param feeReceiver Address that receives platform fees.
    /// @param intermediatedPlatformsOperator Address authorized to interact with invoice creation and specific
    ///        management functions.
    /// @param gasThreshold The minimum amount of gas that must remain to continue processing tasks.
    struct Configuration {
        address owner;
        uint96 feeRate;
        address feeReceiver;
        address intermediatedPlatformsOperator;
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
     * @notice Updates the sole platform operator wallet authorized to call privileged
     *         `IntermediatedPaymentProcessor` functions: creating invoices, triggering releases and refunds,
     *         and resolving disputes.
     * @dev Callable only by the contract owner.
     * @param _intermediatedPlatformsOperatorWallet The new platform operator wallet address.
     */
    function setIntermediatedPlatformsOperator(address _intermediatedPlatformsOperatorWallet) external;

    /**
     * @notice Sets the key whose signature authorizes the fee receiver supplied when an invoice is
     *         accepted or paid.
     * @dev Callable only by the contract owner. Must be an EOA: the processors recover it with ECDSA,
     *      so it cannot be the MultiSig that owns this contract.
     * @param _feeSigner The new fee signer address.
     */
    function setFeeSigner(address _feeSigner) external;

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
     * @notice Updates the gas threshold used in automated task processing.
     * @dev Only callable by the contract owner. This threshold determines the minimum gas
     *      required to continue processing during `onReport` / `processDueTasks`.
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
     * @notice Halts every value-moving entrypoint on both payment processors.
     * @dev Only callable by the contract owner. Stays in effect until `unpause`.
     */
    function pause() external;

    /**
     * @notice Lifts a pause and clears any unresolved emergency pause.
     * @dev Only callable by the contract owner.
     */
    function unpause() external;

    /**
     * @notice Halts both payment processors for `EMERGENCY_PAUSE_DURATION` without owner involvement.
     * @dev Only callable by the emergency pauser. Lapses automatically unless the owner calls
     *      `approveEmergencyPause` within the window. The pauser may trigger a fresh one once it lapses.
     */
    function emergencyPause() external;

    /**
     * @notice Converts an active emergency pause into an indefinite pause.
     * @dev Only callable by the contract owner, and only while the emergency pause has not expired.
     */
    function approveEmergencyPause() external;

    /**
     * @notice Sets the address allowed to call `emergencyPause`.
     * @dev Only callable by the contract owner. Set to address(0) to revoke.
     * @param _emergencyPauser The new emergency pauser address.
     */
    function setEmergencyPauser(address _emergencyPauser) external;

    /**
     * @notice Returns whether the payment processors are currently paused.
     * @dev True for an owner pause, or an emergency pause that has not yet expired.
     * @return pausedState True when paused.
     */
    function isPaused() external view returns (bool pausedState);

    /**
     * @notice Returns the address allowed to call `emergencyPause`.
     * @return emergencyPauser The emergency pauser address.
     */
    function getEmergencyPauser() external view returns (address emergencyPauser);

    /**
     * @notice Returns the timestamp at which an unresolved emergency pause lapses.
     * @return expiry The expiry timestamp, or 0 when no emergency pause is pending.
     */
    function getEmergencyPauseExpiry() external view returns (uint256 expiry);

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
     * @notice Returns the key whose signature authorizes a per-invoice fee receiver.
     * @return feeSigner The fee signer address.
     */
    function getFeeSigner() external view returns (address feeSigner);

    /**
     * @notice Returns the address of the authorized Intermediated Platforms Operator.
     * @return intermediatedPlatformsOperator The Intermediated Platforms Operator address.
     */
    function getIntermediatedPlatformsOperator() external view returns (address intermediatedPlatformsOperator);

    /**
     * @notice Returns the current gas threshold used to limit the execution loop in automated task processing.
     * @dev This threshold is typically used to prevent out-of-gas errors during batch operations
     *      triggered by the Chainlink CRE workflow.
     * @return gasThreshold The current gas threshold value.
     */
    function getGasThreshold() external view returns (uint256 gasThreshold);

    /**
     * @notice Emitted once at construction with the initial configuration parameters.
     * @param config The configuration the contract was initialized with.
     */
    event ConfigurationInitialized(Configuration config);

    /**
     * @notice Emitted when an address is granted or revoked authorization.
     * @param account The address whose authorization status changed.
     * @param authorized The new authorization status.
     */
    event AuthorizationUpdated(address indexed account, bool authorized);

    /**
     * @notice Emitted when the fee receiver address is updated.
     * @param feeReceiver The new fee receiver address.
     */
    event FeeReceiverUpdated(address indexed feeReceiver);

    /**
     * @notice Emitted when the fee signer is updated.
     * @param feeSigner The new fee signer address.
     */
    event FeeSignerUpdated(address indexed feeSigner);

    /**
     * @notice Emitted when the Intermediated Platforms Operator address is updated.
     * @param intermediatedPlatformsOperator The new Intermediated Platforms Operator address.
     */
    event IntermediatedPlatformsOperatorUpdated(address indexed intermediatedPlatformsOperator);

    /**
     * @notice Emitted when the platform fee rate is updated.
     * @param feeRate The new fee rate in basis points.
     */
    event FeeRateUpdated(uint96 feeRate);

    /**
     * @notice Emitted when the automated-upkeep gas threshold is updated.
     * @param gasThreshold The new gas threshold value.
     */
    event GasThresholdUpdated(uint96 gasThreshold);

    /**
     * @notice Emitted when the payment validity duration is updated.
     * @param validityDuration The new payment validity window in seconds.
     */
    event PaymentValidityDurationUpdated(uint256 validityDuration);

    /**
     * @notice Emitted when the owner pauses the payment processors.
     * @param account The owner that paused.
     */
    event Paused(address indexed account);

    /**
     * @notice Emitted when the owner lifts a pause.
     * @param account The owner that unpaused.
     */
    event Unpaused(address indexed account);

    /**
     * @notice Emitted when the emergency pauser halts the payment processors.
     * @param account The emergency pauser.
     * @param expiry The timestamp at which the pause lapses without owner approval.
     */
    event EmergencyPaused(address indexed account, uint256 expiry);

    /**
     * @notice Emitted when the owner converts an emergency pause into an indefinite pause.
     * @param account The owner that approved.
     */
    event EmergencyPauseApproved(address indexed account);

    /**
     * @notice Emitted when the emergency pauser address is updated.
     * @param emergencyPauser The new emergency pauser address.
     */
    event EmergencyPauserUpdated(address indexed emergencyPauser);
}
