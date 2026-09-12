// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title INotes
/// @notice Notes interface for encrypted, shareable invoice notes.
interface INotes {
    /// @notice Thrown when the caller is not authorized to access the note.
    error Unauthorized();
    /// @notice Thrown when creating a note with empty content.
    error EmptyContent();
    /// @notice Thrown when the requested note does not exist.
    error NoteNotFound();
    /// @notice Thrown when the supplied public key is not 64 bytes.
    error InvalidPublicKey();
    /// @notice Thrown when an account that already registered a public key tries to register another.
    error PublicKeyAlreadySet();

    /// @notice Stored note data.
    /// @param author The note author.
    /// @param share Whether the note is shared with the other party.
    /// @param exists Whether the note exists.
    /// @param version The note schema version.
    /// @param content The encrypted note content.
    struct Note {
        address author;
        bool share;
        bool exists;
        uint8 version;
        bytes content;
    }

    /// @notice A public key registered by an account, so others can encrypt notes to it.
    /// @param key The registered public key.
    /// @param version The note encryption version that was active when the key was registered.
    struct PublicKey {
        bytes key;
        uint8 version;
    }

    /**
     * @notice Create a note under an invoice.
     * @dev Only authorized callers can create notes. The first note created for an invoice
     *      (noteId 0) automatically marks the author as having opened it.
     * @param _invoiceId Invoice identifier.
     * @param _author Note author.
     * @param _encryptedContent Encrypted note payload.
     * @param _share Whether the note is shared with non-authors.
     * @return noteId Newly created note id.
     */
    function createNote(uint216 _invoiceId, address _author, bytes calldata _encryptedContent, bool _share)
        external
        returns (uint256 noteId);

    /**
     * @notice Mark a note as opened or unopened for an account.
     * @dev Only authorized callers can update opened state. Reverts with Unauthorized if
     *      the note is not shared — opened state can only be tracked for shared notes.
     * @param _invoiceId Invoice identifier.
     * @param _account Account whose opened state is updated.
     * @param _noteId Note identifier.
     */
    function setOpened(uint216 _invoiceId, address _account, uint256 _noteId) external;

    /**
     * @notice Get the total number of notes for an invoice.
     * @param _invoiceId Invoice identifier.
     * @return totalNotes Total number of notes created for the invoice.
     */
    function getNoteCount(uint216 _invoiceId) external view returns (uint256 totalNotes);

    /**
     * @notice Check if a note is opened for a specific user.
     * @param _invoiceId Invoice identifier.
     * @param _noteId Note identifier.
     * @param _user Address to check.
     * @return isOpen True if the note is opened for the user.
     */
    function isOpened(uint216 _invoiceId, uint256 _noteId, address _user) external view returns (bool isOpen);

    /**
     * @notice Get a single note if visible to the caller.
     * @dev Reverts with Unauthorized if the caller is not the note author and the note is
     *      not shared. Only the author can read a private note; shared notes are readable
     *      by anyone.
     * @param _invoiceId Invoice identifier.
     * @param _noteId Note identifier.
     * @return author Note author.
     * @return share Whether the note is shared.
     * @return content Encrypted note content.
     * @return openedStatus Whether the caller has opened the note.
     * @return version Note schema version.
     */
    function getNote(uint216 _invoiceId, uint256 _noteId)
        external
        view
        returns (address author, bool share, bytes memory content, bool openedStatus, uint8 version);

    /**
     * @notice Registers the caller's wallet public key, so others can encrypt notes to it.
     * @dev An account registers under its own slot, so a caller can only ever set its own key.
     *      The key is not verified against the caller beyond a 64-byte length check.
     *
     *      The key is stored alongside the note encryption version active at registration, so a
     *      reader knows which scheme the key was published for. Write-once: an account that already
     *      registered a key cannot replace or clear it.
     * @param _publicKey The caller's 64-byte public key.
     */
    function setPublicKey(bytes calldata _publicKey) external;

    /**
     * @notice Returns the public key an account registered.
     * @param _account The account to look up.
     * @return publicKey The registered key and the note version it was registered under. The `key`
     *         is empty when the account has not registered one.
     */
    function getPublicKey(address _account) external view returns (PublicKey memory publicKey);

    /**
     * @notice Returns the active note encryption version.
     * @return v The current note version.
     */
    function getCurrentVersion() external view returns (uint8 v);

    /**
     * @notice Emitted when a new note is created for an invoice.
     * @param invoiceId The unique identifier of the invoice the note is associated with.
     * @param noteId The unique identifier of the created note.
     * @param author The address of the account that created the note.
     * @param share Indicates whether the note is shared with other parties.
     * @param encryptedContent The encrypted contents of the note.
     */
    event NoteCreated(
        uint216 indexed invoiceId, uint256 indexed noteId, address indexed author, bool share, bytes encryptedContent
    );

    /**
     * @notice Emitted once when an account registers its public key.
     * @dev Never emitted twice for the same account: registration is write-once.
     * @param account The account that registered the key.
     * @param publicKey The public key that was registered.
     * @param version The note encryption version active at registration.
     */
    event PublicKeySet(address indexed account, bytes publicKey, uint8 version);

    /// @notice The note encryption version applied to new notes. Compile-time constant.
    function CURRENT_VERSION() external view returns (uint8 version);

    /**
     * @notice Emitted when a user changes their opened state for a note.
     * @param invoiceId The unique identifier of the invoice the note belongs to.
     * @param noteId The unique identifier of the note.
     * @param user The address of the user whose note state was updated.
     * @param opened Whether the note is marked as opened or not by the user.
     */
    event NoteStateChanged(uint216 indexed invoiceId, uint256 indexed noteId, address indexed user, bool opened);
}
