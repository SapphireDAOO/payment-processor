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

    /// @notice Min-heap struct holding the encoded task keys.
    struct Heap {
        uint256[] data;
    }

    /**
     * @notice Inserts a new task into the heap.
     * @dev Reverts if the task with the same ID already exists.
     * @param heap The heap storage struct.
     * @param id The unique identifier of the task.
     * @param dueTime The due timestamp (in seconds) of the task.
     * @param index Mapping from task ID to 1-based index in the heap.
     */
    function insert(Heap storage heap, uint216 id, uint40 dueTime, mapping(uint216 => uint256) storage index)
        internal
    {
        if (index[id] != 0) revert DuplicateTask();
        uint256 key = _encode(id, dueTime);
        heap.data.push(key);

        uint256 i = heap.data.length - 1;
        index[id] = i + 1;
        _siftUp(heap, i, index);
    }

    /**
     * @notice Removes a task from a specific index in the heap.
     * @param heap The heap storage struct.
     * @param i The zero-based index to remove from.
     * @param index Mapping from task ID to 1-based index in the heap.
     */
    function removeAt(Heap storage heap, uint256 i, mapping(uint216 => uint256) storage index) internal {
        uint256 last = heap.data.length - 1;
        uint256 removedKey = heap.data[i];
        uint216 removedId = uint216(removedKey);

        if (i != last) {
            uint256 movedKey = heap.data[last];
            heap.data[i] = movedKey;

            uint216 movedId = uint216(movedKey);
            index[movedId] = i + 1;

            heap.data.pop();
            _siftDown(heap, i, index);
            _siftUp(heap, i, index);
        } else {
            heap.data.pop();
        }

        delete index[removedId];
    }

    /**
     * @notice Updates the due time of an existing task and rebalances the heap.
     * @dev Reverts if task ID is not found.
     * @param heap The heap storage struct.
     * @param id The task ID to reschedule.
     * @param newDueAt The new due time (timestamp in seconds).
     * @param index Mapping from task ID to 1-based index in the heap.
     */
    function reschedule(Heap storage heap, uint216 id, uint40 newDueAt, mapping(uint216 => uint256) storage index)
        internal
    {
        uint256 p = index[id];
        if (p == 0) revert TaskNotFound();

        uint256 i = p - 1;
        uint256 oldKey = heap.data[i];
        (, uint64 oldDueAt) = _decode(oldKey);

        uint256 newKey = _encode(id, newDueAt);
        heap.data[i] = newKey;

        if (newDueAt < oldDueAt) {
            _siftUp(heap, i, index);
        } else if (newDueAt > oldDueAt) {
            _siftDown(heap, i, index);
        }
    }

    /**
     * @notice Returns true if the next task is due based on the current block timestamp.
     * @param heap The heap storage struct.
     * @return True if the heap has a task due now or earlier.
     */
    function due(Heap storage heap) internal view returns (bool) {
        if (heap.data.length == 0) return false;
        (, uint40 dueAt) = peek(heap);
        return block.timestamp >= dueAt;
    }

    /**
     * @notice Returns the ID and due time of the next task in the heap.
     * @dev Reverts if heap is empty.
     * @param heap The heap storage struct.
     * @return id The task ID.
     * @return dueAt The due timestamp in seconds.
     */
    function peek(Heap storage heap) internal view returns (uint216, uint40) {
        return _decode(heap.data[0]);
    }

    /**
     * @notice Encodes a task's ID and due time into a 256-bit key.
     * @param id The task ID.
     * @param dueTime The due time in seconds.
     * @return key Encoded key with dueTime in high bits and id in low bits.
     */
    function _encode(uint216 id, uint40 dueTime) private pure returns (uint256) {
        return (uint256(dueTime) << 216) | uint256(id);
    }

    /**
     * @notice Decodes a 256-bit key into task ID and due time.
     * @param key The encoded key.
     * @return id The task ID.
     * @return dueDate The due time in seconds.
     */
    function _decode(uint256 key) private pure returns (uint216, uint40) {
        uint216 id = uint216(key & ((1 << 216) - 1));
        uint40 dueDate = uint40(key >> 216);

        return (id, dueDate);
    }

    /**
     * @dev Maintains the heap property by moving an item down the tree.
     */
    function _siftDown(Heap storage heap, uint256 i, mapping(uint216 => uint256) storage index) private {
        uint256 len = heap.data.length;
        while (true) {
            uint256 l = (i << 1) + 1;
            if (l >= len) break;
            uint256 r = l + 1;
            uint256 m = (r < len && heap.data[r] < heap.data[l]) ? r : l;
            if (heap.data[m] >= heap.data[i]) break;

            _swap(heap, index, i, m);
            i = m;
        }
    }

    /**
     * @dev Maintains the heap property by moving an item up the tree.
     */
    function _siftUp(Heap storage heap, uint256 i, mapping(uint216 => uint256) storage index) private {
        while (i != 0) {
            uint256 p = (i - 1) >> 1;
            if (heap.data[i] >= heap.data[p]) break;

            _swap(heap, index, i, p);
            i = p;
        }
    }

    /**
     * @dev Swaps two elements in the heap and updates the index mapping.
     */
    function _swap(Heap storage heap, mapping(uint216 => uint256) storage index, uint256 i, uint256 j) private {
        uint256 a = heap.data[i];
        uint256 b = heap.data[j];
        heap.data[i] = b;
        heap.data[j] = a;

        index[uint216(a)] = j + 1;
        index[uint216(b)] = i + 1;
    }

    /**
     * @notice Returns the task IDs currently in the heap in raw order (not sorted).
     * @param heap The heap storage struct.
     * @return items Array of task IDs.
     */
    function getItems(Heap storage heap) external view returns (uint216[] memory) {
        uint256 size = heap.data.length;
        if (size == 0) return new uint216[](0);
        uint216[] memory items = new uint216[](size);
        for (uint256 i = 0; i < size; i++) {
            (uint216 it,) = _decode(heap.data[i]);
            items[i] = it;
        }

        return items;
    }
}
