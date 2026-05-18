import XCTest
@testable import CactusVoice

/// Runtime correctness tests for `BoundedSPSCBuffer<T>`.
///
/// Covers Story 2.1 ACs 4-8: write/read round-trip, partial reads,
/// overrun increments + drop-oldest, concurrent producer/consumer fuzz
/// (10 000 ops), zero-retain after removeAll, overrunStream delivery.
final class BoundedSPSCBufferTests: XCTestCase {

    // MARK: - AC: write-then-read round-trip

    func testWriteThenReadRoundTrip() {
        let buf = BoundedSPSCBuffer<Float>(capacity: 16)
        let input: [Float] = [1, 2, 3, 4, 5]
        buf.write(input)
        let out = Array(buf.read())
        XCTAssertEqual(out, input)
        XCTAssertEqual(buf.count, 0, "buffer must be empty after a full read")
        XCTAssertEqual(buf.overrunCount, 0)
    }

    // MARK: - AC: partial / repeated reads

    func testPartialReads() {
        let buf = BoundedSPSCBuffer<Float>(capacity: 8)
        buf.write([1, 2, 3] as [Float])
        XCTAssertEqual(Array(buf.read()), [1, 2, 3])
        XCTAssertEqual(buf.count, 0)

        buf.write([4, 5] as [Float])
        buf.write([6] as [Float])
        XCTAssertEqual(Array(buf.read()), [4, 5, 6])
        XCTAssertEqual(buf.overrunCount, 0)
    }

    // MARK: - AC: overrun increments + drops OLDEST

    func testOverrunDropsOldestAndCounts() {
        let buf = BoundedSPSCBuffer<Float>(capacity: 4)
        buf.write([1, 2, 3, 4] as [Float]) // full
        XCTAssertEqual(buf.overrunCount, 0)

        // Writing 3 more must drop the 3 oldest: [1,2,3] go, ring becomes [4,5,6,7].
        buf.write([5, 6, 7] as [Float])
        XCTAssertEqual(buf.overrunCount, 3)
        XCTAssertEqual(Array(buf.read()), [4, 5, 6, 7])
    }

    func testOverrunWithSingleHugeBatch() {
        let buf = BoundedSPSCBuffer<Float>(capacity: 4)
        // 6 samples into a capacity-4 buffer: 2 dropped from batch front,
        // then 4 survive and fit (no further ring drops).
        buf.write([1, 2, 3, 4, 5, 6] as [Float])
        XCTAssertEqual(buf.overrunCount, 2)
        XCTAssertEqual(Array(buf.read()), [3, 4, 5, 6])
    }

    // MARK: - AC: removeAll zero retain

    func testRemoveAllZeroRetain() {
        let buf = BoundedSPSCBuffer<Float>(capacity: 8)
        buf.write([1, 2, 3, 4, 5] as [Float])
        XCTAssertEqual(buf.count, 5)
        buf.removeAll()
        XCTAssertEqual(buf.count, 0, "removeAll must zero out live sample count")
        XCTAssertEqual(buf.overrunCount, 0, "removeAll must reset overrunCount")
        XCTAssertEqual(Array(buf.read()), [], "read after removeAll must be empty")

        // Buffer must still be usable post-reset.
        buf.write([9, 8] as [Float])
        XCTAssertEqual(Array(buf.read()), [9, 8])
    }

    // MARK: - AC: overrunStream delivers values

    func testOverrunStreamDeliversValues() async {
        let buf = BoundedSPSCBuffer<Float>(capacity: 4)
        let stream = buf.overrunStream

        // Trigger overruns from another task to ensure the stream is being read.
        let collector = Task<[Int], Never> {
            var received: [Int] = []
            for await value in stream {
                received.append(value)
                if received.count >= 1 { break }
            }
            return received
        }

        // Give the collector a tick to subscribe.
        try? await Task.sleep(nanoseconds: 50_000_000)

        buf.write([1, 2, 3, 4] as [Float])
        buf.write([5, 6] as [Float]) // drops 2

        let received = await collector.value
        XCTAssertFalse(received.isEmpty, "overrunStream must deliver at least one event")
        XCTAssertEqual(received.last, buf.overrunCount)
    }

    // MARK: - AC: concurrent producer/consumer fuzz, 10 000 ops

    func testConcurrentProducerConsumerFuzz10k() {
        let buf = BoundedSPSCBuffer<Int>(capacity: 256)
        let totalOps = 10_000

        let producerDone = expectation(description: "producer done")
        let consumerDone = expectation(description: "consumer done")

        // Track what the consumer pulled vs what producer pushed.
        let consumed = OSAllocatedUnfairLockedBox<[Int]>(value: [])

        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<totalOps {
                buf.write([i])
            }
            producerDone.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var localPulls = 0
            // Spin until producer is done and the buffer is drained.
            while localPulls < totalOps {
                let slice = buf.read()
                if slice.isEmpty {
                    // small backoff
                    Thread.sleep(forTimeInterval: 0.0005)
                    if localPulls + buf.count == 0,
                       XCTWaiter().wait(for: [producerDone], timeout: 0) == .completed,
                       buf.count == 0 {
                        break
                    }
                    continue
                }
                consumed.withValue { $0.append(contentsOf: slice) }
                localPulls += slice.count
            }
            consumerDone.fulfill()
        }

        wait(for: [producerDone, consumerDone], timeout: 30.0)

        let pulled = consumed.withValue { $0 }
        // Invariants:
        //   1. pulled.count + overrunCount == totalOps  (no double-counting,
        //      every produced sample either reached the consumer or was a
        //      documented overrun drop).
        //   2. pulled is strictly monotonic (consumer sees samples in produce
        //      order, no duplication or re-ordering).
        XCTAssertEqual(pulled.count + buf.overrunCount, totalOps,
                       "every produced sample must either reach the consumer or count as overrun")
        var prev = -1
        for v in pulled {
            XCTAssertGreaterThan(v, prev, "consumer must see strictly monotonic values (FIFO, no dup)")
            prev = v
        }
    }
}

/// Tiny lock-box helper for collecting consumer output from a background thread
/// without tripping Swift's concurrent-mutation diagnostics.
private final class OSAllocatedUnfairLockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = OSAllocatedUnfairLock()
    init(value: Value) { self.value = value }
    func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.withLock { body(&value) }
    }
}
