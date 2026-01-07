// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { INotes } from "./interface/INotes.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";

/**
 * @title Notes
 * @notice Stores encrypted order notes and tracks per-user opened state.
 * @dev Access is gated by an allowlist controlled via setAuthorized.
 */
contract Notes is INotes {
    /// @notice Authorization flag indicating access is denied.
    uint256 public constant NOT_ALLOWED = 0;
    /// @notice Authorization flag indicating access is granted.
    uint256 public constant ALLOWED = 1;

    /// @notice Reference to the external Payment Processor storage contract.
    IPaymentProcessorStorage public immutable ppStorage;

    /// @notice Stores notes per order.
    /// @dev invoiceId => noteId => Note data
    mapping(uint216 invoiceId => mapping(uint256 noteId => Note note)) private notes;

    /// @notice Tracks the total number of notes created for each order.
    /// @dev Used to assign incremental noteIds per order
    mapping(uint216 invoiceId => uint256 totalNotes) private noteCount;

    /// @notice Tracks whether a user has opened a specific note.
    /// @dev invoiceId => noteId => user => opened status
    mapping(uint216 invoiceId => mapping(uint256 noteId => mapping(address user => bool isOpened))) private opened;

    /// @notice Tracks which addresses are allowed to create notes.
    /// @dev Address => ALLOWED/NOT_ALLOWED flag.
    mapping(address => uint256) private auth;

    /**
     * @notice Restricts access to authorized callers.
     * @dev Reverts with Unauthorized if the caller is not allowed.
     */
    modifier isAuthorized() {
        _isAuthorized();
        _;
    }

    /**
     * @notice Initializes the Notes contract with a payment processor storage reference.
     * @param paymentProcessorStorageAddress The address of the storage contract.
     */
    constructor(address paymentProcessorStorageAddress) {
        ppStorage = IPaymentProcessorStorage(paymentProcessorStorageAddress);
    }

    /// @inheritdoc INotes
    function createNote(uint216 invoiceId, address author, bytes calldata encryptedContent, bool share)
        external
        override
        isAuthorized
        returns (uint256)
    {
        if (encryptedContent.length == 0) revert EmptyContent();

        uint256 noteId = noteCount[invoiceId];

        notes[invoiceId][noteId] = Note({ author: author, share: share, content: encryptedContent, exists: true });

        noteCount[invoiceId] = noteId + 1;

        if (noteId == 0) {
            _setOpened(invoiceId, noteId, true);
        }

        emit NoteCreated(invoiceId, noteId, author, share, encryptedContent);

        return noteId;
    }

    /// @inheritdoc INotes
    function setOpened(uint216 invoiceId, uint256 noteId, bool open) external override {
        Note memory note = notes[invoiceId][noteId];
        if (!note.exists) revert NoteNotFound();

        if (!note.share) revert Unauthorized();

        _setOpened(invoiceId, noteId, open);
    }

    /**
     * @notice Updates the opened state for a note.
     * @param invoiceId Order identifier.
     * @param noteId Note identifier.
     * @param open New opened state for the caller.
     */
    function _setOpened(uint216 invoiceId, uint256 noteId, bool open) internal {
        opened[invoiceId][noteId][msg.sender] = open;

        emit NoteStateChanged(invoiceId, noteId, msg.sender, open);
    }

    /// @inheritdoc INotes
    function getNoteCount(uint216 invoiceId) external view override returns (uint256) {
        return noteCount[invoiceId];
    }

    /// @inheritdoc INotes
    function isOpened(uint216 invoiceId, uint256 noteId, address user) external view override returns (bool) {
        return opened[invoiceId][noteId][user];
    }

    /// @inheritdoc INotes
    function getNote(uint216 invoiceId, uint256 noteId)
        external
        view
        override
        returns (address, bool, bytes memory, bool)
    {
        Note memory note = notes[invoiceId][noteId];
        if (!note.exists) revert NoteNotFound();

        if (msg.sender != note.author && !note.share) revert Unauthorized();

        return (note.author, note.share, note.content, opened[invoiceId][noteId][msg.sender]);
    }

    /**
     * @notice Updates the authorization status for a user.
     * @param user The address to update.
     * @param enabled Whether the user should be authorized.
     */
    function setAuthorized(address user, bool enabled) external {
        if (msg.sender != _owner()) revert Unauthorized();
        auth[user] = enabled ? ALLOWED : NOT_ALLOWED;
    }

    /**
     * @notice Returns the owner of the PaymentProcessorStorage contract.
     * @dev This helper reads the owner directly from the linked PaymentProcessorStorage instance.
     * @return owner The address that currently owns the PaymentProcessorStorage contract.
     */
    function _owner() internal view returns (address) {
        return PaymentProcessorStorage(address(ppStorage)).owner();
    }

    /**
     * @notice Validates that the caller is authorized.
     * @dev Reverts with Unauthorized if the caller is not allowed.
     */
    function _isAuthorized() internal view {
        if (auth[msg.sender] == 0) revert Unauthorized();
    }
}
