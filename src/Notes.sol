// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { INotes } from "./interface/INotes.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "./PaymentProcessorStorage.sol";
import { IAuthorizedAddressProvider } from "./interface/IMasterDeployer.sol";

/**
 * @title Notes
 * @notice Stores encrypted invoice notes and tracks per-user opened state.
 * @dev Access is gated by an allowlist fixed at construction via {IAuthorizedAddressProvider}.
 */
contract Notes is INotes {
    /// @notice Authorization flag indicating access is denied.
    uint256 public constant NOT_ALLOWED = 0;
    /// @notice Authorization flag indicating access is granted.
    uint256 public constant ALLOWED = 1;

    /// @notice Active note encryption version used for newly created notes.
    uint8 public constant CURRENT_VERSION = 1;

    /// @notice Reference to the external Payment Processor storage contract.
    IPaymentProcessorStorage public immutable PP_STORAGE;

    /// @notice Stores notes per invoice.
    mapping(uint216 invoiceId => mapping(uint256 noteId => Note data)) private notes;

    /// @notice Tracks the total number of notes created for each invoice.
    /// @dev Used to assign incremental noteIds per invoice
    mapping(uint216 invoiceId => uint256 totalNotes) private noteCount;

    /// @notice Tracks whether a user has opened a specific note.
    mapping(uint216 invoiceId => mapping(uint256 noteId => mapping(address user => bool isOpened))) private opened;

    /// @notice Tracks which addresses are allowed to create notes.
    /// @dev Address => ALLOWED/NOT_ALLOWED flag.
    mapping(address => uint256) private auth;

    /// @notice Public key each account registered, so others can encrypt notes to it.
    /// @dev Written only by the account itself, once, via {setPublicKey}.
    mapping(address account => PublicKey publicKey) private publicKeys;

    /**
     * @notice Restricts access to authorized callers.
     * @dev Reverts with Unauthorized if the caller is not allowed.
     */
    modifier onlyAuthorized() {
        _isAuthorized();
        _;
    }

    /**
     * @notice Initializes the Notes contract with a payment processor storage reference.
     * @param _paymentProcessorStorageAddress The address of the storage contract.
     */
    constructor(address _paymentProcessorStorageAddress) {
        PP_STORAGE = IPaymentProcessorStorage(_paymentProcessorStorageAddress);

        address[] memory authorized = IAuthorizedAddressProvider(msg.sender).authorizedAddresses();
        for (uint256 i; i < authorized.length; i++) {
            auth[authorized[i]] = ALLOWED;
        }
    }

    /// @inheritdoc INotes
    function createNote(uint216 _invoiceId, address _author, bytes calldata _encryptedContent, bool _share)
        external
        onlyAuthorized
        returns (uint256 noteId)
    {
        if (_encryptedContent.length == 0) revert EmptyContent();

        noteId = noteCount[_invoiceId];

        notes[_invoiceId][noteId] = Note({
            author: _author, share: _share, content: _encryptedContent, exists: true, version: CURRENT_VERSION
        });

        noteCount[_invoiceId] = noteId + 1;

        _setOpened(_invoiceId, _author, noteId);

        emit NoteCreated(_invoiceId, noteId, _author, _share, _encryptedContent);
    }

    /// @inheritdoc INotes
    function setOpened(uint216 _invoiceId, address _account, uint256 _noteId) external onlyAuthorized {
        Note memory note = notes[_invoiceId][_noteId];
        if (!note.exists) revert NoteNotFound();

        if (!note.share) revert Unauthorized();

        _setOpened(_invoiceId, _account, _noteId);
    }

    /**
     * @notice Updates the opened state for a note.
     * @param _invoiceId Invoice identifier.
     * @param _account Account whose opened state is updated.
     * @param _noteId Note identifier.
     */
    function _setOpened(uint216 _invoiceId, address _account, uint256 _noteId) internal {
        opened[_invoiceId][_noteId][_account] = true;

        emit NoteStateChanged(_invoiceId, _noteId, _account, true);
    }

    /// @inheritdoc INotes
    function getNoteCount(uint216 _invoiceId) external view returns (uint256 totalNotes) {
        return noteCount[_invoiceId];
    }

    /// @inheritdoc INotes
    function isOpened(uint216 _invoiceId, uint256 _noteId, address _user) external view returns (bool isOpen) {
        return opened[_invoiceId][_noteId][_user];
    }

    /// @inheritdoc INotes
    function getNote(uint216 _invoiceId, uint256 _noteId)
        external
        view
        returns (address author, bool share, bytes memory content, bool openedStatus, uint8 version)
    {
        Note memory note = notes[_invoiceId][_noteId];
        if (!note.exists) revert NoteNotFound();

        if (msg.sender != note.author && !note.share) revert Unauthorized();

        author = note.author;
        share = note.share;
        content = note.content;
        openedStatus = opened[_invoiceId][_noteId][msg.sender];
        version = note.version;
    }

    /// @inheritdoc INotes
    function setPublicKey(bytes calldata _publicKey) external {
        if (publicKeys[msg.sender].key.length != 0) revert PublicKeyAlreadySet();
        if (_publicKey.length != 64) revert InvalidPublicKey();

        uint8 version = CURRENT_VERSION;
        publicKeys[msg.sender] = PublicKey({ key: _publicKey, version: version });

        emit PublicKeySet(msg.sender, _publicKey, version);
    }

    /// @inheritdoc INotes
    function getPublicKey(address _account) external view returns (PublicKey memory publicKey) {
        return publicKeys[_account];
    }

    /**
     * @notice Returns the owner of the PaymentProcessorStorage contract.
     * @dev This helper reads the owner directly from the linked PaymentProcessorStorage instance.
     * @return ownerAddress The address that currently owns the PaymentProcessorStorage contract.
     */
    function _owner() internal view returns (address ownerAddress) {
        ownerAddress = PaymentProcessorStorage(address(PP_STORAGE)).owner();
    }

    /**
     * @notice Validates that the caller is authorized.
     * @dev Reverts with Unauthorized if the caller is not allowed.
     */
    function _isAuthorized() internal view {
        if (auth[msg.sender] == 0) revert Unauthorized();
    }
}
