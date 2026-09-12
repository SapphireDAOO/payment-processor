// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { INotes } from "src/Notes.sol";
import { NotesSetUp } from "../utils/NotesSetUp.sol";
import { Vm } from "forge-std/Vm.sol";

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
        assertEq(version, notes.CURRENT_VERSION());

        noteId = notes.createNote(invoiceId, address(1), "how is it going?", true);

        vm.prank(address(1));
        (author, share, content, openedStatus, version) = notes.getNote(invoiceId, noteId);

        assertEq(notes.getNoteCount(invoiceId), 2);
        assertEq(author, address(1));
        assertEq(share, true);
        assertEq(content, bytes("how is it going?"));
        assertEq(openedStatus, true);
        assertEq(version, notes.CURRENT_VERSION());

        assertEq(notes.isOpened(invoiceId, noteId, address(this)), false);
    }

    function test_setOpened() public {
        uint216 invoiceId = 1;

        vm.expectRevert(INotes.NoteNotFound.selector);
        notes.setOpened(invoiceId, address(this), 0);

        uint256 noteId = notes.createNote(invoiceId, address(this), "hello everyone", true);

        notes.setOpened(invoiceId, address(this), noteId);

        (address author, bool share, bytes memory content, bool openedStatus, uint8 version) =
            notes.getNote(invoiceId, noteId);

        assertEq(notes.getNoteCount(invoiceId), 1);
        assertEq(notes.isOpened(invoiceId, noteId, address(this)), true);
        assertEq(author, address(this));
        assertEq(share, true);
        assertEq(content, bytes("hello everyone"));
        assertEq(openedStatus, true);
        assertEq(version, notes.CURRENT_VERSION());

        noteId = notes.createNote(invoiceId, address(this), "what is the result", false);

        vm.expectRevert(INotes.Unauthorized.selector);
        notes.setOpened(invoiceId, address(this), noteId);
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

    function test_notesCarryTheFixedVersion() public {
        // The encryption version is a compile-time constant now, so every note carries it.
        uint216 invoiceId = 1;

        uint256 noteId = notes.createNote(invoiceId, address(this), "hello everyone", false);
        (,,,, uint8 version) = notes.getNote(invoiceId, noteId);
        assertEq(version, notes.CURRENT_VERSION());
    }

    function test_unauthorizedAccountCannotCreateNotes() public {
        vm.prank(address(0xa0));
        vm.expectRevert(INotes.Unauthorized.selector);
        notes.createNote(1, address(0xa0), "hello", false);
    }

    // ── setPublicKey ──────────────────────────────────────────────────────────────

    function test_setPublicKeyRegistersTheCallersOwnKey() public {
        Vm.Wallet memory wallet = vm.createWallet("public-key-owner");
        bytes memory publicKey = _publicKey(wallet);
        uint8 version = notes.CURRENT_VERSION();

        assertEq(notes.getPublicKey(wallet.addr).key.length, 0, "should start unregistered");

        vm.prank(wallet.addr);
        vm.expectEmit(address(notes));
        emit INotes.PublicKeySet(wallet.addr, publicKey, version);
        notes.setPublicKey(publicKey);

        INotes.PublicKey memory registered = notes.getPublicKey(wallet.addr);
        assertEq(registered.key, publicKey);
        assertEq(registered.version, version);
    }

    function test_setPublicKeyRecordsTheVersionActiveAtRegistration() public {
        Vm.Wallet memory wallet = vm.createWallet("public-key-owner");

        vm.prank(wallet.addr);
        notes.setPublicKey(_publicKey(wallet));

        assertEq(notes.getPublicKey(wallet.addr).version, notes.CURRENT_VERSION());
    }

    function test_setPublicKeyOnlyEverWritesTheCallersOwnSlot() public {
        Vm.Wallet memory wallet = vm.createWallet("public-key-owner");
        Vm.Wallet memory other = vm.createWallet("public-key-other");

        // The key is not checked against the caller, but it still lands under the caller's slot
        // and leaves the account the key came from untouched.
        vm.prank(other.addr);
        notes.setPublicKey(_publicKey(wallet));

        assertEq(notes.getPublicKey(other.addr).key, _publicKey(wallet));
        assertEq(notes.getPublicKey(wallet.addr).key.length, 0);
    }

    function test_setPublicKeyRejectsAMalformedKey() public {
        Vm.Wallet memory wallet = vm.createWallet("public-key-owner");

        // 65-byte form, i.e. one byte too long.
        vm.prank(wallet.addr);
        vm.expectRevert(INotes.InvalidPublicKey.selector);
        notes.setPublicKey(abi.encodePacked(bytes1(0x04), _publicKey(wallet)));

        vm.prank(wallet.addr);
        vm.expectRevert(INotes.InvalidPublicKey.selector);
        notes.setPublicKey("");
    }

    function test_setPublicKeyIsWriteOnce() public {
        Vm.Wallet memory wallet = vm.createWallet("public-key-owner");
        bytes memory publicKey = _publicKey(wallet);

        vm.prank(wallet.addr);
        notes.setPublicKey(publicKey);

        // Even re-registering the same, valid key is refused.
        vm.prank(wallet.addr);
        vm.expectRevert(INotes.PublicKeyAlreadySet.selector);
        notes.setPublicKey(publicKey);

        assertEq(notes.getPublicKey(wallet.addr).key, publicKey);
    }

    function test_setPublicKeyKeepsAccountsIndependent() public {
        Vm.Wallet memory walletOne = vm.createWallet("public-key-one");
        Vm.Wallet memory walletTwo = vm.createWallet("public-key-two");

        vm.prank(walletOne.addr);
        notes.setPublicKey(_publicKey(walletOne));

        // One account being write-once does not block another from registering.
        vm.prank(walletTwo.addr);
        notes.setPublicKey(_publicKey(walletTwo));

        assertEq(notes.getPublicKey(walletOne.addr).key, _publicKey(walletOne));
        assertEq(notes.getPublicKey(walletTwo.addr).key, _publicKey(walletTwo));
    }

    /// @dev The wallet's 64-byte public key.
    function _publicKey(Vm.Wallet memory _wallet) private pure returns (bytes memory publicKey) {
        return abi.encodePacked(_wallet.publicKeyX, _wallet.publicKeyY);
    }
}
