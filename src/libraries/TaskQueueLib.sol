// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TaskQueueLib
 * @notice A binary min-heap based task scheduler library for managing tasks keyed by `(id, dueTime)`.
 * @dev Keys are encoded into `uint256` with `dueTime` in the high 40 bits and `id` in the low 216 bits.
 */
library TaskQueueLib {
    /// @notice Thrown when a task with a given ID is not found in the queue.
    error TaskNotFound();

    /// @notice Thrown when trying to insert a task that already exists in the queue.
    error DuplicateTask();

    /// @notice Returned when a task is not yet eligible for release (e.g. wrong status or too early).
    uint256 constant NOT_ELIGIBLE_FOR_RELEASE = 1;
    /// @notice Returned when an error occurs during task processing (e.g. invalid index or heap inconsistency).
    uint256 constant ERROR = 2;
    /// @notice Returned when a task has been successfully released and removed from the heap.
    uint256 constant SUCCESSFUL = 3;

    /// @notice Min-heap struct holding the encoded task keys.
    /// @param data The heap data array of encoded task keys.
    struct Heap {
        uint256[] data;
    }

    /**
     * @notice Inserts a new task into the heap.
     * @dev Reverts if the task with the same ID already exists.
     * @param _heap The heap storage struct.
     * @param _id The unique identifier of the task.
     * @param _dueTime The due timestamp (in seconds) of the task.
     * @param _index Mapping from task ID to 1-based index in the heap.
     */
    function insert(Heap storage _heap, uint216 _id, uint40 _dueTime, mapping(uint216 => uint256) storage _index)
        internal
    {
        if (_index[_id] != 0) revert DuplicateTask();
        uint256 key = _encode(_id, _dueTime);
        _heap.data.push(key);

        uint256 i = _heap.data.length - 1;
        _index[_id] = i + 1;
        _siftUp(_heap, i, _index);
    }

    /**
     * @notice Removes a task from a specific index in the heap.
     * @param _heap The heap storage struct.
     * @param _i The zero-based index to remove from.
     * @param _index Mapping from task ID to 1-based index in the heap.
     */
    function removeAt(Heap storage _heap, uint256 _i, mapping(uint216 => uint256) storage _index) internal {
        uint256 last = _heap.data.length - 1;
        uint256 removedKey = _heap.data[_i];
        uint216 removedId = uint216(removedKey);

        if (_i != last) {
            uint256 movedKey = _heap.data[last];
            _heap.data[_i] = movedKey;

            uint216 movedId = uint216(movedKey);
            _index[movedId] = _i + 1;

            _heap.data.pop();
            _siftDown(_heap, _i, _index);
            _siftUp(_heap, _i, _index);
        } else {
            _heap.data.pop();
        }

        delete _index[removedId];
    }

    /**
     * @notice Updates the due time of an existing task and rebalances the heap.
     * @dev Reverts if task ID is not found.
     * @param _heap The heap storage struct.
     * @param _id The task ID to reschedule.
     * @param _newDueAt The new due time (timestamp in seconds).
     * @param _index Mapping from task ID to 1-based index in the heap.
     */
    function reschedule(Heap storage _heap, uint216 _id, uint40 _newDueAt, mapping(uint216 => uint256) storage _index)
        internal
    {
        uint256 p = _index[_id];

        if (p == 0) revert TaskNotFound();

        uint256 i = p - 1;
        uint256 oldKey = _heap.data[i];
        (, uint40 oldDueAt) = _decode(oldKey);

        uint256 newKey = _encode(_id, _newDueAt);
        _heap.data[i] = newKey;

        if (_newDueAt < oldDueAt) {
            _siftUp(_heap, i, _index);
        } else if (_newDueAt > oldDueAt) {
            _siftDown(_heap, i, _index);
        }
    }

    /**
     * @notice Iterates through the heap and attempts to release due tasks based on available gas.
     * @dev Peeks at the heap root on each iteration. If the top task is not yet due
     *      (`block.timestamp < dueAt`), the loop exits immediately — the min-heap ordering
     *      guarantees all remaining tasks are also not yet due. Otherwise, `_callback` is
     *      invoked with the task ID and the result determines control flow:
     *      - `SUCCESSFUL`: Task released and removed from heap; continues to next task.
     *      - `NOT_ELIGIBLE_FOR_RELEASE`: Stale entry — removed and loop continues.
     *      - `ERROR`: Stale entry — removed and loop continues.
     * @param _heap The heap data structure storing encoded tasks.
     * @param _index Mapping from task ID to 1-based heap position, used to remove stale entries.
     * @param _callback A function that attempts to release or refund a task by ID, returning a status code.
     * @param _gasThreshold The minimum remaining gas required to continue processing.
     */
    function processDueTask(
        Heap storage _heap,
        mapping(uint216 => uint256) storage _index,
        function(uint216) internal returns (uint256) _callback,
        uint256 _gasThreshold
    ) internal {
        while (_heap.data.length > 0 && gasleft() > _gasThreshold) {
            (uint216 id, uint40 dueAt) = peek(_heap);

            if (block.timestamp < dueAt) break;

            uint256 result = _callback(id);

            if (result == SUCCESSFUL) continue;
            if (result == NOT_ELIGIBLE_FOR_RELEASE || result == ERROR) {
                // Stale heap entry: remove it so subsequent tasks can be processed.
                removeAt(_heap, 0, _index);
                continue;
            }
        }
    }

    /**
     * @notice Returns true if the next task is due based on the current block timestamp.
     * @param _heap The heap storage struct.
     * @return isDue True if the heap has a task due now or earlier.
     */
    function due(Heap storage _heap) internal view returns (bool isDue) {
        if (_heap.data.length == 0) return false;
        (, uint40 dueAt) = peek(_heap);
        isDue = block.timestamp >= dueAt;
    }

    /**
     * @notice Returns the ID and due time of the next task in the heap.
     * @dev Reverts if heap is empty.
     * @param _heap The heap storage struct.
     * @return id The task ID.
     * @return dueAt The due timestamp in seconds.
     */
    function peek(Heap storage _heap) private view returns (uint216 id, uint40 dueAt) {
        (id, dueAt) = _decode(_heap.data[0]);
    }

    /**
     * @notice Encodes a task's ID and due time into a 256-bit key.
     * @param _id The task ID.
     * @param _dueTime The due time in seconds.
     * @return key Encoded key with dueTime in high bits and id in low bits.
     */
    function _encode(uint216 _id, uint40 _dueTime) private pure returns (uint256 key) {
        key = (uint256(_dueTime) << 216) | uint256(_id);
    }

    /**
     * @notice Decodes a 256-bit key into task ID and due time.
     * @param _key The encoded key.
     * @return id The task ID.
     * @return dueAt The due time in seconds.
     */
    function _decode(uint256 _key) private pure returns (uint216 id, uint40 dueAt) {
        id = uint216((_key & ((1 << 216) - 1)));
        dueAt = uint40((_key >> 216));

        return (id, dueAt);
    }

    /**
     * @notice Restores the min-heap property by bubbling an element down toward the leaves.
     * @dev Swaps the element at `_i` with its smallest child until the heap invariant is satisfied.
     * @param _heap The heap storage struct.
     * @param _i The zero-based index of the element to sift down.
     * @param _index Mapping from task ID to 1-based index in the heap.
     */
    function _siftDown(Heap storage _heap, uint256 _i, mapping(uint216 => uint256) storage _index) private {
        uint256 len = _heap.data.length;
        while (true) {
            uint256 l = (_i << 1) + 1;
            if (l >= len) break;
            uint256 r = l + 1;
            uint256 m = (r < len && _heap.data[r] < _heap.data[l]) ? r : l;
            if (_heap.data[m] >= _heap.data[_i]) break;

            _swap(_heap, _index, _i, m);
            _i = m;
        }
    }

    /**
     * @notice Restores the min-heap property by bubbling an element up toward the root.
     * @dev Swaps the element at `_i` with its parent until the heap invariant is satisfied.
     * @param _heap The heap storage struct.
     * @param _i The zero-based index of the element to sift up.
     * @param _index Mapping from task ID to 1-based index in the heap.
     */
    function _siftUp(Heap storage _heap, uint256 _i, mapping(uint216 => uint256) storage _index) private {
        while (_i != 0) {
            uint256 p = (_i - 1) >> 1;
            if (_heap.data[_i] >= _heap.data[p]) break;

            _swap(_heap, _index, _i, p);
            _i = p;
        }
    }

    /**
     * @notice Swaps two elements in the heap array and updates both entries in the index mapping.
     * @dev Both `_i` and `_j` are zero-based positions in `_heap.data`.
     * @param _heap The heap storage struct.
     * @param _index Mapping from task ID to 1-based index in the heap.
     * @param _i The zero-based index of the first element.
     * @param _j The zero-based index of the second element.
     */
    function _swap(Heap storage _heap, mapping(uint216 => uint256) storage _index, uint256 _i, uint256 _j) private {
        uint256 a = _heap.data[_i];
        uint256 b = _heap.data[_j];
        _heap.data[_i] = b;
        _heap.data[_j] = a;

        _index[uint216(a)] = _j + 1;
        _index[uint216(b)] = _i + 1;
    }

    /**
     * @notice Returns the task IDs in heap storage order.
     * @dev Linear pass over the heap array. Intended for off-chain use only.
     *      Items are not sorted; callers should sort by due time off-chain if needed.
     * @param _heap The heap storage struct.
     * @return items Array of task IDs in heap order.
     */
    function getItems(Heap storage _heap) internal view returns (uint216[] memory items) {
        uint256 size = _heap.data.length;
        if (size == 0) return new uint216[](0);
        items = new uint216[](size);
        for (uint256 i = 0; i < size; i++) {
            items[i] = uint216(_heap.data[i]);
        }
    }
}
