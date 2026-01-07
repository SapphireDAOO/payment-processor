// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title INotes
/// @notice Notes interface for encrypted, shareable order notes.
interface INotes {
    /// @notice Thrown when the caller is not authorized to access the note.
    error Unauthorized();
    /// @notice Thrown when creating a note with empty content.
    error EmptyContent();
    /// @notice Thrown when content exceeds the maximum allowed size.
    error ContentTooLarge();
    /// @notice Thrown when the requested note does not exist.
    error NoteNotFound();

    /// @notice Stored note data.
    /// @param author The note author.
    /// @param share Whether the note is shared with non-authors.
    /// @param content The encrypted note content.
    /// @param exists Whether the note exists.
    struct Note {
        address author;
        bool share;
        bytes content;
        bool exists;
    }

    /**
     * @notice Create a note under an order.
     * @param _invoiceId Order identifier.
     * @param _author Note author.
     * @param _encryptedContent Encrypted note payload.
     * @param _share Whether the note is shared with non-authors.
     * @return noteId Newly created note id.
     */
    function createNote(uint216 _invoiceId, address _author, bytes calldata _encryptedContent, bool _share)
        external
        returns (uint256 noteId);

    /**
     * @notice Mark a note as opened or unopened for the caller.
     * @param _invoiceId Order identifier.
     * @param _noteId Note identifier.
     * @param _open New opened state for the caller.
     */
    function setOpened(uint216 _invoiceId, uint256 _noteId, bool _open) external;

    /**
     * @notice Get the total number of notes for an order.
     * @param _invoiceId Order identifier.
     * @return totalNotes Total number of notes created for the order.
     */
    function getNoteCount(uint216 _invoiceId) external view returns (uint256 totalNotes);

    /**
     * @notice Check if a note is opened for a specific user.
     * @param _invoiceId Order identifier.
     * @param _noteId Note identifier.
     * @param _user Address to check.
     * @return isOpen True if the note is opened for the user.
     */
    function isOpened(uint216 _invoiceId, uint256 _noteId, address _user) external view returns (bool isOpen);

    /**
     * @notice Get a single note if visible to the caller.
     * @param _invoiceId Order identifier.
     * @param _noteId Note identifier.
     * @return author Note author.
     * @return share Whether the note is shared.
     * @return content Encrypted note content.
     * @return openedStatus Whether the caller has opened the note.
     */
    function getNote(uint216 _invoiceId, uint256 _noteId)
        external
        view
        returns (address author, bool share, bytes memory content, bool openedStatus);

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
     * @notice Emitted when a user changes their opened state for a note.
     * @param invoiceId The unique identifier of the invoice the note belongs to.
     * @param noteId The unique identifier of the note.
     * @param user The address of the user whose note state was updated.
     * @param opened Whether the note is marked as opened or not by the user.
     */
    event NoteStateChanged(uint216 indexed invoiceId, uint256 indexed noteId, address indexed user, bool opened);
}
