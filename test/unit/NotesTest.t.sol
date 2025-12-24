// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { INotes } from "src/Notes.sol";
import { NotesSetUp } from "../utils/NotesSetUp.sol";

contract NotesTest is NotesSetUp {
    // function setUp() public { }

    function test_createNote() public {
        uint216 orderId = 1;
        vm.expectRevert(INotes.EmptyContent.selector);
        notes.createNote(orderId, address(this), "", true);

        uint256 noteId = notes.createNote(orderId, address(this), "hello everyone", true);

        (address author, bool share, bytes memory content, bool openedStatus) = notes.getNote(orderId, noteId);

        assertEq(notes.getNoteCount(orderId), 1);
        assertEq(author, address(this));
        assertEq(share, true);
        assertEq(content, bytes("hello everyone"));
        assertEq(openedStatus, true);

        noteId = notes.createNote(orderId, address(this), "how is it going?", true);

        (author, share, content, openedStatus) = notes.getNote(orderId, noteId);

        assertEq(notes.getNoteCount(orderId), 2);
        assertEq(author, address(this));
        assertEq(share, true);
        assertEq(content, bytes("how is it going?"));
        assertEq(openedStatus, false);
    }

    function test_setOpened() public {
        uint216 orderId = 1;

        vm.expectRevert(INotes.NoteNotFound.selector);
        notes.setOpened(orderId, 0, true);

        uint256 noteId = notes.createNote(orderId, address(this), "hello everyone", true);

        notes.setOpened(orderId, noteId, true);

        (address author, bool share, bytes memory content, bool openedStatus) = notes.getNote(orderId, noteId);

        assertEq(notes.getNoteCount(orderId), 1);
        assertEq(notes.isOpened(orderId, noteId, address(this)), true);
        assertEq(author, address(this));
        assertEq(share, true);
        assertEq(content, bytes("hello everyone"));
        assertEq(openedStatus, true);
    }
}
