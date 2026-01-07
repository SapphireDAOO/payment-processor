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
    struct Note {
        address author;
        bool share;
        bytes content;
        bool exists;
    }

    /// @notice Emitted when a note is created.
    event NoteCreated(
        uint216 indexed invoiceId, uint256 indexed noteId, address indexed author, bool share, bytes encryptedContent
    );

    /// @notice Emitted when a user updates their opened state for a note.
    event NoteStateChanged(uint216 indexed invoiceId, uint256 indexed noteId, address indexed user, bool opened);

    /**
     * @notice Create a note under an order.
     * @param invoiceId Order identifier.
     * @param encryptedContent Encrypted note payload.
     * @param author Note author.
     * @param share Whether the note is shared with non-authors.
     * @return noteId Newly created note id.
     */
    function createNote(uint216 invoiceId, address author, bytes calldata encryptedContent, bool share)
        external
        returns (uint256 noteId);

    /**
     *  @notice Mark a note as opened or unopened for the caller.
     *  @param invoiceId Order identifier.
     *  @param noteId Note identifier.
     *  @param open New opened state for the caller.
     */
    function setOpened(uint216 invoiceId, uint256 noteId, bool open) external;

    /**
     * @notice Get the total number of notes for an order.
     * @param invoiceId Order identifier.
     * @return total Total number of notes created for the order.
     */
    function getNoteCount(uint216 invoiceId) external view returns (uint256 total);

    /**
     * @notice Check if a note is opened for a specific user.
     * @param invoiceId Order identifier.
     * @param noteId Note identifier.
     * @param user Address to check.
     * @return isOpen True if the note is opened for the user.
     */
    function isOpened(uint216 invoiceId, uint256 noteId, address user) external view returns (bool isOpen);

    /**
     * @notice Get a single note if visible to the caller.
     * @param invoiceId Order identifier.
     * @param noteId Note identifier.
     * @return author Note author.
     * @return share Whether the note is shared.
     * @return content Encrypted note content.
     * @return openedStatus Whether the caller has opened the note.
     */
    function getNote(uint216 invoiceId, uint256 noteId)
        external
        view
        returns (address author, bool share, bytes memory content, bool openedStatus);
}
