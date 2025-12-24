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
    /// @dev orderId => noteId => Note data
    mapping(uint216 orderId => mapping(uint256 noteId => Note note)) private notes;

    /// @notice Tracks the total number of notes created for each order.
    /// @dev Used to assign incremental noteIds per order
    mapping(uint216 orderId => uint256 totalNotes) private noteCount;

    /// @notice Tracks whether a user has opened a specific note.
    /// @dev orderId => noteId => user => opened status
    mapping(uint216 orderId => mapping(uint256 noteId => mapping(address user => bool isOpened))) private opened;

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
    function createNote(uint216 orderId, address author, bytes calldata encryptedContent, bool share)
        external
        override
        isAuthorized
        returns (uint256)
    {
        if (encryptedContent.length == 0) revert EmptyContent();

        uint256 noteId = noteCount[orderId];

        notes[orderId][noteId] = Note({ author: author, share: share, content: encryptedContent, exists: true });

        noteCount[orderId] = noteId + 1;

        if (noteId == 0) {
            _setOpened(orderId, noteId, true);
        }

        emit NoteCreated(orderId, noteId, author, share, encryptedContent);

        return noteId;
    }

    /// @inheritdoc INotes
    function setOpened(uint216 orderId, uint256 noteId, bool open) external override {
        Note memory note = notes[orderId][noteId];
        if (!note.exists) revert NoteNotFound();

        if (!note.share) revert Unauthorized();

        _setOpened(orderId, noteId, open);
    }

    /**
     * @notice Updates the opened state for a note.
     * @param orderId Order identifier.
     * @param noteId Note identifier.
     * @param open New opened state for the caller.
     */
    function _setOpened(uint216 orderId, uint256 noteId, bool open) internal {
        opened[orderId][noteId][msg.sender] = open;

        emit NoteStateChanged(orderId, noteId, msg.sender, open);
    }

    /// @inheritdoc INotes
    function getNoteCount(uint216 orderId) external view override returns (uint256) {
        return noteCount[orderId];
    }

    /// @inheritdoc INotes
    function isOpened(uint216 orderId, uint256 noteId, address user) external view override returns (bool) {
        return opened[orderId][noteId][user];
    }

    /// @inheritdoc INotes
    function getNote(uint216 orderId, uint256 noteId)
        external
        view
        override
        returns (address, bool, bytes memory, bool)
    {
        Note memory note = notes[orderId][noteId];
        if (!note.exists) revert NoteNotFound();

        if (msg.sender != note.author && !note.share) revert Unauthorized();

        return (note.author, note.share, note.content, opened[orderId][noteId][msg.sender]);
    }

    /**
     * @notice Updates the authorization status for a user.
     * @param user The address to update.
     * @param enabled Whether the user should be authorized.
     */
    function setAuthorized(address user, bool enabled) external {
        if (msg.sender != PaymentProcessorStorage(address(ppStorage)).owner()) revert Unauthorized();
        auth[user] = enabled ? ALLOWED : NOT_ALLOWED;
    }

    /**
     * @notice Validates that the caller is authorized.
     * @dev Reverts with Unauthorized if the caller is not allowed.
     */
    function _isAuthorized() internal view {
        if (auth[msg.sender] == 0) revert Unauthorized();
    }
}
