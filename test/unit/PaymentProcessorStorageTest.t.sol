// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IPaymentProcessorStorage } from "../../src/interface/IPaymentProcessorStorage.sol";
import { BaseSetUp } from "../utils/BaseSetUp.sol";
import { Ownable } from "solady/auth/Ownable.sol";

contract PaymentProcessorStorageTest is BaseSetUp {
    address constant PAUSER = address(0x9a);
    address constant STRANGER = address(0x9b);

    function setUp() public {
        initialize();
        vm.prank(admin);
        ppStorage.setEmergencyPauser(PAUSER);
    }

    function test_startsUnpaused() public view {
        assertFalse(ppStorage.isPaused());
        assertEq(ppStorage.getEmergencyPauseExpiry(), 0);
        assertEq(ppStorage.getEmergencyPauser(), PAUSER);
    }

    function test_pauseAndUnpause() public {
        vm.prank(admin);
        vm.expectEmit(address(ppStorage));
        emit IPaymentProcessorStorage.Paused(admin);
        ppStorage.pause();

        assertTrue(ppStorage.isPaused());

        vm.prank(admin);
        vm.expectEmit(address(ppStorage));
        emit IPaymentProcessorStorage.Unpaused(admin);
        ppStorage.unpause();

        assertFalse(ppStorage.isPaused());
    }

    function test_ownerPauseNeverExpires() public {
        vm.prank(admin);
        ppStorage.pause();

        vm.warp(block.timestamp + 3650 days);
        assertTrue(ppStorage.isPaused());
    }

    function test_pauseRevertsForNonOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ppStorage.pause();

        vm.prank(STRANGER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ppStorage.unpause();
    }

    function test_pauseRevertsWhenAlreadyPaused() public {
        vm.startPrank(admin);
        ppStorage.pause();

        vm.expectRevert(IPaymentProcessorStorage.AlreadyPaused.selector);
        ppStorage.pause();
        vm.stopPrank();
    }

    function test_unpauseRevertsWhenNotPaused() public {
        vm.prank(admin);
        vm.expectRevert(IPaymentProcessorStorage.NotPaused.selector);
        ppStorage.unpause();
    }

    function test_setEmergencyPauserRevertsForNonOwner() public {
        vm.prank(STRANGER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ppStorage.setEmergencyPauser(STRANGER);
    }

    function test_setEmergencyPauserToZeroRevokes() public {
        vm.prank(admin);
        address(ppStorage);
        emit IPaymentProcessorStorage.EmergencyPauserUpdated(address(0));
        ppStorage.setEmergencyPauser(address(0));

        vm.prank(PAUSER);
        vm.expectRevert(IPaymentProcessorStorage.NotAuthorized.selector);
        ppStorage.emergencyPause();

        assertEq(ppStorage.getEmergencyPauser(), address(0));
    }

    function test_emergencyPauseRevertsForNonPauser() public {
        vm.prank(admin);
        vm.expectRevert(IPaymentProcessorStorage.NotAuthorized.selector);
        ppStorage.emergencyPause();

        vm.prank(STRANGER);
        vm.expectRevert(IPaymentProcessorStorage.NotAuthorized.selector);
        ppStorage.emergencyPause();
    }

    function test_emergencyPausePauses() public {
        uint256 expiry = block.timestamp + ppStorage.EMERGENCY_PAUSE_DURATION();

        vm.prank(PAUSER);
        vm.expectEmit(address(ppStorage));
        emit IPaymentProcessorStorage.EmergencyPaused(PAUSER, expiry);
        ppStorage.emergencyPause();

        assertTrue(ppStorage.isPaused());
        assertEq(ppStorage.getEmergencyPauseExpiry(), expiry);
    }

    function test_emergencyPauseLapsesAfterTheWindow() public {
        vm.prank(PAUSER);
        ppStorage.emergencyPause();

        vm.warp(block.timestamp + ppStorage.EMERGENCY_PAUSE_DURATION() - 1);
        assertTrue(ppStorage.isPaused());

        vm.warp(block.timestamp + 1);
        assertFalse(ppStorage.isPaused());
    }

    function test_lapsedEmergencyPauseUntilUnpaused() public {
        vm.prank(PAUSER);
        ppStorage.emergencyPause();

        vm.warp(block.timestamp + ppStorage.EMERGENCY_PAUSE_DURATION());
        assertFalse(ppStorage.isPaused());

        vm.prank(PAUSER);
        ppStorage.emergencyPause();
        assertTrue(ppStorage.isPaused());

        vm.prank(admin);
        ppStorage.unpause();

        vm.prank(PAUSER);
        ppStorage.emergencyPause();
        assertTrue(ppStorage.isPaused());
    }

    function test_emergencyPauseRevertsWhileOwnerPaused() public {
        vm.prank(admin);
        ppStorage.pause();

        vm.prank(PAUSER);
        vm.expectRevert(IPaymentProcessorStorage.AlreadyPaused.selector);
        ppStorage.emergencyPause();
    }

    function test_approveEmergencyPauseMakesItIndefinite() public {
        vm.prank(PAUSER);
        ppStorage.emergencyPause();

        vm.prank(admin);
        address(ppStorage);
        emit IPaymentProcessorStorage.EmergencyPauseApproved(admin);
        ppStorage.approveEmergencyPause();

        assertEq(ppStorage.getEmergencyPauseExpiry(), 0);

        vm.warp(block.timestamp + 365 days);
        assertTrue(ppStorage.isPaused());
    }

    function test_approveEmergencyPauseRevertsAfterItLapses() public {
        vm.prank(PAUSER);
        ppStorage.emergencyPause();

        vm.warp(block.timestamp + ppStorage.EMERGENCY_PAUSE_DURATION());

        vm.prank(admin);
        vm.expectRevert(IPaymentProcessorStorage.NoActiveEmergencyPause.selector);
        ppStorage.approveEmergencyPause();
    }

    function test_approveEmergencyPauseRevertsWithoutOne() public {
        vm.prank(admin);
        vm.expectRevert(IPaymentProcessorStorage.NoActiveEmergencyPause.selector);
        ppStorage.approveEmergencyPause();
    }

    function test_approveEmergencyPauseRevertsForNonOwner() public {
        vm.prank(PAUSER);
        ppStorage.emergencyPause();

        vm.prank(PAUSER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ppStorage.approveEmergencyPause();
    }

    function test_ownerCanUnpauseAnEmergencyPauseEarly() public {
        vm.prank(PAUSER);
        ppStorage.emergencyPause();

        vm.prank(admin);
        ppStorage.unpause();

        assertFalse(ppStorage.isPaused());
        assertEq(ppStorage.getEmergencyPauseExpiry(), 0);
    }
}
