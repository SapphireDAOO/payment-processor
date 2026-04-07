// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TaskQueueLib } from "src/libraries/TaskQueueLib.sol";

contract TaskQueueHarness {
    TaskQueueLib.Heap internal heap;
    mapping(uint216 => uint256) public idx;

    mapping(uint216 => uint256) public callbackOverrides;

    function insert(uint216 id, uint40 dueTime) external {
        TaskQueueLib.insert(heap, id, dueTime, idx);
    }

    function removeAt(uint256 i) external {
        TaskQueueLib.removeAt(heap, i, idx);
    }

    function reschedule(uint216 id, uint40 newDueAt) external {
        TaskQueueLib.reschedule(heap, id, newDueAt, idx);
    }

    function processDueTasks(uint256 gasThreshold) external {
        TaskQueueLib.processDueTask(heap, idx, _callback, gasThreshold);
    }

    function due() external view returns (bool) {
        return TaskQueueLib.due(heap);
    }

    function getItems() external view returns (uint216[] memory) {
        return TaskQueueLib.getItems(heap);
    }

    function indexOf(uint216 id) external view returns (uint256) {
        return idx[id];
    }

    function size() external view returns (uint256) {
        return heap.data.length;
    }

    function setCallbackOverride(uint216 id, uint256 result) external {
        callbackOverrides[id] = result;
    }

    function _callback(uint216 id) internal returns (uint256) {
        uint256 override_ = callbackOverrides[id];

        if (override_ == TaskQueueLib.NOT_ELIGIBLE_FOR_RELEASE) {
            return TaskQueueLib.NOT_ELIGIBLE_FOR_RELEASE;
        }
        if (override_ == TaskQueueLib.ERROR) {
            return TaskQueueLib.ERROR;
        }

        // Default path: remove from heap and report success.
        uint256 p = idx[id];
        if (p != 0) TaskQueueLib.removeAt(heap, p - 1, idx);
        return TaskQueueLib.SUCCESSFUL;
    }
}
