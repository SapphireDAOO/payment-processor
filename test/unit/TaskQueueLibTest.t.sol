// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { TaskQueueHarness } from "../harness/TaskQueueHarness.sol";

error DuplicateTask();
error TaskNotFound();

uint256 constant NOT_ELIGIBLE_FOR_RELEASE = 1;
uint256 constant ERROR = 2;
uint256 constant SUCCESSFUL = 3;

contract TaskQueueLibTest is Test {
    TaskQueueHarness internal h;

    function setUp() public {
        h = new TaskQueueHarness();
    }

    function test_insert(uint216 _id, uint40 _dueTime) public {
        h.insert(_id, _dueTime);

        assertEq(h.size(), 1);
        assertEq(h.idx(_id), 1);
    }

    function test_removeAt(uint216 _id, uint40 _dueTime) public {
        h.insert(_id, _dueTime);

        h.removeAt(h.idx(_id) - 1);

        assertEq(h.size(), 0);
        assertEq(h.idx(_id), 0);
    }

    function test_reschedule(uint216 _id, uint40 _dueTime, uint16 _size) public {
        _size = uint16(bound(_size, 500, 2000));
        _dueTime = uint40(bound(_dueTime, 1000, type(uint40).max / 2));
        _id = uint216(bound(_id, 1000, type(uint216).max / 2));
        uint16 i;
        for (; i < _size; i++) {
            h.insert(_id + i, _dueTime + i);
        }

        assertEq(h.idx(_id), 1);
        h.reschedule(_id, _dueTime + i);
        assertNotEq(h.idx(_id), 1);
    }

    function test_insertAndProcessAll(uint16 _size) public {
        _size = uint16(bound(_size, 500, 3000));
        for (uint216 i; i < _size; i++) {
            h.insert(i, 1);
        }

        uint256 gasThreshold = 100;
        h.processDueTasks(gasThreshold);
        assertEq(h.size(), 0);
    }

    function test_insertAndRemoveOne() public {
        uint256 size = 1000;
        for (uint216 i; i < size; i++) {
            h.insert(i, 1);
        }

        h.removeAt(0);

        assertEq(h.size(), size - 1);
    }

    function test_insertMaintainsMinHeap() public {
        h.insert(10, 300);
        h.insert(20, 100);
        h.insert(30, 200);

        uint216[] memory items = h.getItems();
        assertEq(items.length, 3);
        assertEq(items[0], 20);
    }

    function test_insert_revertsOnDuplicate() public {
        h.insert(1, 100);

        vm.expectRevert(DuplicateTask.selector);
        h.insert(1, 200);
    }

    function test_removeAtOnlyElement() public {
        h.insert(1, 100);
        h.removeAt(0);

        assertEq(h.size(), 0);
        assertEq(h.indexOf(1), 0);
    }

    function test_removeAtRootRebalances() public {
        h.insert(1, 100);
        h.insert(2, 200);
        h.insert(3, 300);

        h.removeAt(0);

        assertEq(h.size(), 2);
        assertEq(h.indexOf(1), 0);

        uint216[] memory items = h.getItems();
        assertEq(items[0], 2);
    }

    function test_removeAtMiddlePreservesHeapProperty() public {
        h.insert(1, 100);
        h.insert(2, 200);
        h.insert(3, 300);

        uint256 pos = h.indexOf(2) - 1;
        h.removeAt(pos);

        assertEq(h.size(), 2);
        assertEq(h.indexOf(2), 0);
    }

    function test_rescheduleEarlierBubblesUpToRoot() public {
        h.insert(1, 300);
        h.insert(2, 200);
        h.insert(3, 100);

        h.reschedule(1, 50);

        uint216[] memory items = h.getItems();
        assertEq(items[0], 1);
    }

    function test_rescheduleLaterSinksDown() public {
        h.insert(1, 100);
        h.insert(2, 200);
        h.insert(3, 300);

        h.reschedule(1, 500);

        uint216[] memory items = h.getItems();
        assertTrue(items[0] != 1, "rescheduled task should no longer be root");
    }

    function test_rescheduleSameTimeNoOp() public {
        h.insert(1, 100);
        h.reschedule(1, 100);

        assertEq(h.size(), 1);
        assertEq(h.indexOf(1), 1);
    }

    function test_rescheduleRevertsWhenNotFound() public {
        vm.expectRevert(TaskNotFound.selector);
        h.reschedule(99, 100);
    }

    function test_dueEmptyHeap() public view {
        assertFalse(h.due());
    }

    function test_dueBeforeDueTime() public {
        h.insert(1, uint40(block.timestamp + 1 days));
        assertFalse(h.due());
    }

    function test_dueAtDueTime() public {
        h.insert(1, uint40(block.timestamp));
        assertTrue(h.due());
    }

    function test_dueAfterDueTime() public {
        h.insert(1, uint40(block.timestamp + 1));
        vm.warp(block.timestamp + 2);
        assertTrue(h.due());
    }

    function test_processDueTasksRemovesStaleOnError() public {
        uint40 rn = uint40(block.timestamp);
        h.insert(1, rn);
        h.insert(2, rn);
        h.setCallbackOverride(1, ERROR);

        h.processDueTasks(0);

        // Stale entry (id=1) removed; id=2 processed successfully — heap empty.
        assertEq(h.size(), 0);
    }

    function test_processDueTasksSkipsFutureTasks() public {
        h.insert(1, uint40(block.timestamp + 1 days));

        h.processDueTasks(0);

        assertEq(h.size(), 1);
    }

    function test_processDueTasksPartialBatch() public {
        uint40 rn = uint40(block.timestamp);
        uint40 future = uint40(block.timestamp + 1 days);

        h.insert(1, rn);
        h.insert(2, future);

        h.processDueTasks(0);

        assertEq(h.size(), 1);
        assertEq(h.indexOf(2), 1);
    }

    function test_getItemsEmptyHeap() public view {
        assertEq(h.getItems().length, 0);
    }

    function test_getItemsReturnsAllIds() public {
        h.insert(1, 100);
        h.insert(2, 200);
        h.insert(3, 300);

        assertEq(h.getItems().length, 3);
    }
}
