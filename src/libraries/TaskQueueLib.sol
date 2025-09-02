// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MinHeapLib } from "solady/utils/MinHeapLib.sol";

error TaskNotFound();
error DuplicateTask();

library TaskQueueLib {
    using MinHeapLib for MinHeapLib.Heap;

    function insert(MinHeapLib.Heap storage heap, uint256 id, uint40 dueTime, mapping(uint256 => uint256) storage index)
        internal
    {
        if (index[id] != 0) revert DuplicateTask();
        heap.push(encode(id, dueTime));

        uint256 i = heap.data.length - 1;
        index[id] = i + 1;
        _siftUp(heap, i, index);
    }

    function removeAt(MinHeapLib.Heap storage heap, uint256 i, mapping(uint256 => uint256) storage index) internal {
        uint256 last = heap.data.length - 1;
        uint256 removedKey = heap.data[i];
        uint192 removedId = uint192(removedKey);

        if (i != last) {
            uint256 movedKey = heap.data[last];
            heap.data[i] = movedKey;

            uint192 movedId = uint192(movedKey);
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
        uint256 id,
        uint40 newDueAt,
        mapping(uint256 => uint256) storage index
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

    function peek(MinHeapLib.Heap storage heap) internal view returns (uint256) {
        return heap.root()
    }

    function length(MinHeapLib.Heap storage heap) internal view returns (uint256) {
        return heap.length();
    }

    function _siftDown(MinHeapLib.Heap storage heap, uint256 i, mapping(uint256 => uint256) storage index) private {
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

    function _siftUp(MinHeapLib.Heap storage heap, uint256 i, mapping(uint256 => uint256) storage index) private {
        while (i != 0) {
            uint256 p = (i - 1) >> 1;
            if (heap.data[i] >= heap.data[p]) break;

            _swap(heap, index, i, p);
            i = p;
        }
    }

    function _swap(MinHeapLib.Heap storage heap, mapping(uint256 => uint256) storage index, uint256 i, uint256 j)
        private
    {
        uint256 a = heap.data[i];
        uint256 b = heap.data[j];
        heap.data[i] = b;
        heap.data[j] = a;

        index[uint256(a)] = j + 1;
        index[uint256(b)] = i + 1;
    }
}
