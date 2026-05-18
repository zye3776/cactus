//
//  BoundedSPSCBuffer.swift
//  CactusVoice
//
//  Fixed-capacity ring buffer with drop-oldest overflow semantics.
//
//  Contract:
//    * Single-producer, single-consumer (SPSC). Concurrent writers or
//      concurrent readers are UNDEFINED BEHAVIOR. One thread calls write(),
//      one (possibly different) thread calls read(); they may run concurrently.
//    * Fixed capacity at init; never reallocates.
//    * Writes that would exceed remaining capacity drop the OLDEST samples
//      in the ring, increment overrunCount by the count dropped, and emit
//      the new overrunCount on overrunStream. write() never blocks.
//    * read() returns an ArraySlice<T> of all currently-buffered elements
//      and advances the read cursor by that count.
//    * removeAll() resets head/tail/overrunCount; storage capacity is retained
//      (no live samples remain — "zero retain" in the consumer sense).
//
//  Deviation from architecture §A "no locks; Atomic head/tail indices":
//    This implementation uses os.OSAllocatedUnfairLock (Foundation, macOS 13+)
//    to guard head/tail/overrunCount. Rationale:
//      - swift-atomics is not on this project's SPM graph; adding it for one
//        type isn't justified yet.
//      - stdlib Synchronization.UnsafeAtomic is Swift 6 only; project is on
//        Swift 5.10 (project.yml SWIFT_VERSION: "5.10").
//      - The lock guards O(1) integer operations; SPSC contention is minimal.
//    The public API is unchanged from the eventual lock-free implementation,
//    so this class can be re-implemented with atomics in a later story without
//    consumer changes.
//

import Foundation
import os

public final class BoundedSPSCBuffer<T>: @unchecked Sendable {

    /// Fixed capacity set at initialization.
    public let capacity: Int

    /// AsyncStream of cumulative overrun counts (emitted whenever a write drops samples).
    public var overrunStream: AsyncStream<Int> { _overrunStream }

    /// Total number of samples dropped due to overrun across the buffer's lifetime.
    public var overrunCount: Int {
        lock.withLock { _overrunCount }
    }

    /// Number of samples currently available to read.
    public var count: Int {
        lock.withLock { _head - _tail }
    }

    // MARK: - Internal state (guarded by `lock`)

    private var storage: [T?]
    private var _head: Int = 0   // write cursor (monotonically increasing)
    private var _tail: Int = 0   // read cursor (monotonically increasing)
    private var _overrunCount: Int = 0

    private let lock = OSAllocatedUnfairLock()

    // Overrun event stream + continuation.
    private let _overrunStream: AsyncStream<Int>
    private let overrunContinuation: AsyncStream<Int>.Continuation

    // MARK: - Init

    public init(capacity: Int) {
        precondition(capacity > 0, "BoundedSPSCBuffer capacity must be > 0")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)

        var cont: AsyncStream<Int>.Continuation!
        self._overrunStream = AsyncStream<Int>(bufferingPolicy: .bufferingNewest(1)) { c in
            cont = c
        }
        self.overrunContinuation = cont
    }

    deinit {
        overrunContinuation.finish()
    }

    // MARK: - Write (producer side)

    /// Append `samples` to the ring. If the incoming batch would exceed
    /// remaining capacity, the OLDEST currently-buffered samples are dropped
    /// (tail advances), `overrunCount` increases by the drop count, and the
    /// new overrunCount is emitted on `overrunStream`. Never blocks, never
    /// reallocates.
    public func write<S: Sequence>(_ samples: S) where S.Element == T {
        let incoming = Array(samples)
        guard !incoming.isEmpty else { return }

        let emittedOverrun: Int? = lock.withLock { () -> Int? in
            // If the incoming batch is larger than total capacity, only the
            // last `capacity` samples can possibly survive — drop the prefix.
            let effective: ArraySlice<T>
            var droppedFromBatch = 0
            if incoming.count > capacity {
                droppedFromBatch = incoming.count - capacity
                effective = incoming.suffix(capacity)
            } else {
                effective = incoming[...]
            }

            let available = capacity - (_head - _tail)
            var droppedFromRing = 0
            if effective.count > available {
                droppedFromRing = effective.count - available
                _tail += droppedFromRing
            }

            for value in effective {
                storage[_head % capacity] = value
                _head += 1
            }

            let totalDropped = droppedFromBatch + droppedFromRing
            if totalDropped > 0 {
                _overrunCount += totalDropped
                return _overrunCount
            }
            return nil
        }

        if let value = emittedOverrun {
            overrunContinuation.yield(value)
        }
    }

    // MARK: - Read (consumer side)

    /// Drain all currently-buffered samples and advance the read cursor.
    /// Returns an `ArraySlice<T>` view (may be empty).
    public func read() -> ArraySlice<T> {
        lock.withLock {
            let available = _head - _tail
            guard available > 0 else { return ArraySlice<T>() }

            var out: [T] = []
            out.reserveCapacity(available)
            for i in 0..<available {
                let slot = (_tail + i) % capacity
                if let value = storage[slot] {
                    out.append(value)
                }
            }
            _tail += available
            return out[...]
        }
    }

    // MARK: - Reset

    /// Reset cursors and overrun count. Storage capacity is preserved
    /// (no reallocation); no live samples remain after this call.
    public func removeAll() {
        lock.withLock {
            for i in 0..<capacity { storage[i] = nil }
            _head = 0
            _tail = 0
            _overrunCount = 0
        }
    }
}
