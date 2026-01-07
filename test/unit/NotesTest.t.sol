// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { INotes } from "src/Notes.sol";
import { NotesSetUp } from "../utils/NotesSetUp.sol";

contract NotesTest is NotesSetUp {
    // function setUp() public { }

    function test_createNote() public {
        uint216 invoiceId = 1;
        vm.expectRevert(INotes.EmptyContent.selector);
        notes.createNote(invoiceId, address(this), "", true);

        uint256 noteId = notes.createNote(invoiceId, address(this), "hello everyone", true);

        (address author, bool share, bytes memory content, bool openedStatus) = notes.getNote(invoiceId, noteId);

        assertEq(notes.getNoteCount(invoiceId), 1);
        assertEq(author, address(this));
        assertEq(share, true);
        assertEq(content, bytes("hello everyone"));
        assertEq(openedStatus, true);

        noteId = notes.createNote(invoiceId, address(this), "how is it going?", true);

        (author, share, content, openedStatus) = notes.getNote(invoiceId, noteId);

        assertEq(notes.getNoteCount(invoiceId), 2);
        assertEq(author, address(this));
        assertEq(share, true);
        assertEq(content, bytes("how is it going?"));
        assertEq(openedStatus, false);
    }

    function test_setOpened() public {
        uint216 invoiceId = 1;

        vm.expectRevert(INotes.NoteNotFound.selector);
        notes.setOpened(invoiceId, 0, true);

        uint256 noteId = notes.createNote(invoiceId, address(this), "hello everyone", true);

        notes.setOpened(invoiceId, noteId, true);

        (address author, bool share, bytes memory content, bool openedStatus) = notes.getNote(invoiceId, noteId);

        assertEq(notes.getNoteCount(invoiceId), 1);
        assertEq(notes.isOpened(invoiceId, noteId, address(this)), true);
        assertEq(author, address(this));
        assertEq(share, true);
        assertEq(content, bytes("hello everyone"));
        assertEq(openedStatus, true);
    }
}
