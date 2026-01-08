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

    /// @notice Active note encryption version used for newly created notes.
    uint8 private version;

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
     * @param _paymentProcessorStorageAddress The address of the storage contract.
     */
    constructor(address _paymentProcessorStorageAddress) {
        ppStorage = IPaymentProcessorStorage(_paymentProcessorStorageAddress);
        version = 1;
    }

    /// @inheritdoc INotes
    function createNote(uint216 _invoiceId, address _author, bytes calldata _encryptedContent, bool _share)
        external
        override
        isAuthorized
        returns (uint256 noteId)
    {
        if (_encryptedContent.length == 0) revert EmptyContent();

        noteId = noteCount[_invoiceId];

        notes[_invoiceId][noteId] =
            Note({ author: _author, share: _share, content: _encryptedContent, exists: true, version: version });

        noteCount[_invoiceId] = noteId + 1;

        if (noteId == 0) {
            _setOpened(_invoiceId, noteId, true);
        }

        emit NoteCreated(_invoiceId, noteId, _author, _share, _encryptedContent);

        return noteId;
    }

    /// @inheritdoc INotes
    function setOpened(uint216 _invoiceId, uint256 _noteId, bool _open) external override {
        Note memory note = notes[_invoiceId][_noteId];
        if (!note.exists) revert NoteNotFound();

        if (!note.share) revert Unauthorized();

        _setOpened(_invoiceId, _noteId, _open);
    }

    /**
     * @notice Updates the opened state for a note.
     * @param _invoiceId Order identifier.
     * @param _noteId Note identifier.
     * @param _open New opened state for the caller.
     */
    function _setOpened(uint216 _invoiceId, uint256 _noteId, bool _open) internal {
        opened[_invoiceId][_noteId][msg.sender] = _open;

        emit NoteStateChanged(_invoiceId, _noteId, msg.sender, _open);
    }

    /// @inheritdoc INotes
    function getNoteCount(uint216 _invoiceId) external view override returns (uint256 totalNotes) {
        return noteCount[_invoiceId];
    }

    /// @inheritdoc INotes
    function isOpened(uint216 _invoiceId, uint256 _noteId, address _user) external view override returns (bool isOpen) {
        return opened[_invoiceId][_noteId][_user];
    }

    /// @inheritdoc INotes
    function getNote(uint216 _invoiceId, uint256 _noteId)
        external
        view
        override
        returns (address author, bool share, bytes memory content, bool openedStatus)
    {
        Note memory note = notes[_invoiceId][_noteId];
        if (!note.exists) revert NoteNotFound();

        if (msg.sender != note.author && !note.share) revert Unauthorized();

        author = note.author;
        share = note.share;
        content = note.content;
        openedStatus = opened[_invoiceId][_noteId][msg.sender];
    }

    /// @inheritdoc INotes
    function updateVersion(uint8 _newVersion) external {
        if (msg.sender != _owner()) revert Unauthorized();
        version = _newVersion;
    }

    /**
     * @notice Updates the authorization status for a user.
     * @param _user The address to update.
     * @param _enabled Whether the user should be authorized.
     */
    function setAuthorized(address _user, bool _enabled) external {
        if (msg.sender != _owner()) revert Unauthorized();
        auth[_user] = _enabled ? ALLOWED : NOT_ALLOWED;
    }

    /**
     * @notice Returns the owner of the PaymentProcessorStorage contract.
     * @dev This helper reads the owner directly from the linked PaymentProcessorStorage instance.
     * @return ownerAddress The address that currently owns the PaymentProcessorStorage contract.
     */
    function _owner() internal view returns (address ownerAddress) {
        ownerAddress = PaymentProcessorStorage(address(ppStorage)).owner();
    }

    /**
     * @notice Validates that the caller is authorized.
     * @dev Reverts with Unauthorized if the caller is not allowed.
     */
    function _isAuthorized() internal view {
        if (auth[msg.sender] == 0) revert Unauthorized();
    }
}
