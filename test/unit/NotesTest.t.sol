// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { INotes } from "src/Notes.sol";
import { NotesSetUp } from "../utils/NotesSetUp.sol";

contract NotesTest is NotesSetUp {
    function test_createNote() public {
        uint216 invoiceId = 1;
        vm.expectRevert(INotes.EmptyContent.selector);
        notes.createNote(invoiceId, address(this), "", true);

        uint256 noteId = notes.createNote(invoiceId, address(this), "hello everyone", true);

        (address author, bool share, bytes memory content, bool openedStatus, uint8 version) =
            notes.getNote(invoiceId, noteId);

        assertEq(notes.getNoteCount(invoiceId), 1);
        assertEq(author, address(this));
        assertEq(share, true);
        assertEq(content, bytes("hello everyone"));
        assertEq(openedStatus, true);
        assertEq(version, notes.getCurrentVersion());

        noteId = notes.createNote(invoiceId, address(this), "how is it going?", true);

        (author, share, content, openedStatus, version) = notes.getNote(invoiceId, noteId);

        assertEq(notes.getNoteCount(invoiceId), 2);
        assertEq(author, address(this));
        assertEq(share, true);
        assertEq(content, bytes("how is it going?"));
        assertEq(openedStatus, false);
        assertEq(version, notes.getCurrentVersion());
    }

    function test_setOpened() public {
        uint216 invoiceId = 1;

        vm.expectRevert(INotes.NoteNotFound.selector);
        notes.setOpened(invoiceId, address(this), 0, true);

        uint256 noteId = notes.createNote(invoiceId, address(this), "hello everyone", true);

        notes.setOpened(invoiceId, address(this), noteId, true);

        (address author, bool share, bytes memory content, bool openedStatus, uint8 version) =
            notes.getNote(invoiceId, noteId);

        assertEq(notes.getNoteCount(invoiceId), 1);
        assertEq(notes.isOpened(invoiceId, noteId, address(this)), true);
        assertEq(author, address(this));
        assertEq(share, true);
        assertEq(content, bytes("hello everyone"));
        assertEq(openedStatus, true);
        assertEq(version, notes.getCurrentVersion());

        noteId = notes.createNote(invoiceId, address(this), "what is the result", false);

        vm.expectRevert(INotes.Unauthorized.selector);
        notes.setOpened(invoiceId, address(this), noteId, true);
    }

    function test_getNotes() public {
        uint216 invoiceId = 1;
        vm.expectRevert(INotes.NoteNotFound.selector);
        notes.getNote(invoiceId, 1);

        uint256 noteId = notes.createNote(invoiceId, address(this), "hello everyone", false);

        vm.prank(address(0xa0));
        vm.expectRevert(INotes.Unauthorized.selector);
        notes.getNote(invoiceId, noteId);
    }

    function test_newVersion() public {
        vm.expectRevert(INotes.Unauthorized.selector);
        notes.updateVersion(2);

        vm.prank(admin);
        notes.updateVersion(2);

        uint216 invoiceId = 1;

        uint256 noteId = notes.createNote(invoiceId, address(this), "hello everyone", false);
        (,,,, uint8 version) = notes.getNote(invoiceId, noteId);
        assertEq(version, notes.getCurrentVersion());
    }
}
