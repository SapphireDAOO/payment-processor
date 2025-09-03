// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MinHeapLib } from "solady/utils/MinHeapLib.sol";
import { console } from "forge-std/console.sol";

error TaskNotFound();
error DuplicateTask();

library TaskQueueLib {
    using MinHeapLib for MinHeapLib.Heap;

    function insert(MinHeapLib.Heap storage heap, uint216 id, uint40 dueTime, mapping(uint216 => uint256) storage index)
        internal
    {
        if (index[id] != 0) revert DuplicateTask();
        uint256 key = encode(id, dueTime);
        heap.data.push(key);

        uint256 i = heap.data.length - 1;
        index[id] = i + 1;
        _siftUp(heap, i, index);
    }

    function removeAt(MinHeapLib.Heap storage heap, uint256 i, mapping(uint216 => uint256) storage index) internal {
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

    function reschedule(
        MinHeapLib.Heap storage heap,
        uint216 id,
        uint40 newDueAt,
        mapping(uint216 => uint256) storage index
    ) internal {
        uint256 p = index[id];
        if (p == 0) revert TaskNotFound();

        uint256 i = p - 1;
        uint256 oldKey = heap.data[i];
        (, uint64 oldDueAt) = decode(oldKey);

        uint256 newKey = encode(id, newDueAt);
        heap.data[i] = newKey;

        if (newDueAt < oldDueAt) {
            _siftUp(heap, i, index);
        } else if (newDueAt > oldDueAt) {
            _siftDown(heap, i, index);
        }
    }

    function due(MinHeapLib.Heap storage heap) internal view returns (bool) {
        if (heap.length() == 0) return false;
        (, uint40 dueAt) = peek(heap);
        return block.timestamp >= dueAt;
    }

    function peek(MinHeapLib.Heap storage heap) internal view returns (uint216, uint40) {
        return decode(heap.root());
    }

    function length(MinHeapLib.Heap storage heap) internal view returns (uint256) {
        return heap.length();
    }

    function encode(uint216 id, uint40 dueTime) internal pure returns (uint256) {
        return (uint256(dueTime) << 216) | uint256(id);
    }

    function decode(uint256 key) internal pure returns (uint216, uint40) {
        uint216 id = uint216(key & ((1 << 216) - 1));
        uint40 dueDate = uint40(key >> 216);

        return (id, dueDate);
    }

    function _siftDown(MinHeapLib.Heap storage heap, uint256 i, mapping(uint216 => uint256) storage index) private {
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

    function _siftUp(MinHeapLib.Heap storage heap, uint256 i, mapping(uint216 => uint256) storage index) private {
        while (i != 0) {
            uint256 p = (i - 1) >> 1;
            if (heap.data[i] >= heap.data[p]) break;

            _swap(heap, index, i, p);
            i = p;
        }
    }

    function _swap(MinHeapLib.Heap storage heap, mapping(uint216 => uint256) storage index, uint256 i, uint256 j)
        private
    {
        uint256 a = heap.data[i];
        uint256 b = heap.data[j];
        heap.data[i] = b;
        heap.data[j] = a;

        index[uint216(a)] = j + 1;
        index[uint216(b)] = i + 1;
    }

    function getItems(MinHeapLib.Heap storage heap) external view returns (uint256[] memory) {
        uint256 size = heap.data.length;
        if (size == 0) return new uint256[](0);
        uint256[] memory items = new uint256[](size);
        for (uint256 i = 0; i < size; i++) {
            (uint216 it,) = decode(heap.data[i]);
            items[i] = uint256(it);
        }

        return items;
    }
}
