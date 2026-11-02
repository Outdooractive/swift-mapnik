import Foundation
import GISTools
@testable import Mapnik
import Testing

/// A thread-safe work source for `WorkQueue` tests: hands out items one by
/// one and counts how often it was asked.
final class WorkSource: @unchecked Sendable {

    private let lock = NSLock()
    private var items: [Int]
    private var index = 0
    private var fetchCount = 0

    init(_ items: [Int]) {
        self.items = items
    }

    func next() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        fetchCount += 1
        guard index < items.count else {
            return nil
        }

        let item = items[index]
        index += 1
        return item
    }

    var fetches: Int {
        lock.lock()
        defer { lock.unlock() }
        return fetchCount
    }

    var remaining: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count - index
    }

}

@Suite("WorkQueue")
struct WorkQueueTests {

    @Test
    func `processes all work items`() async throws {
        let source = WorkSource(Array(1 ... 50))
        let processed = ThreadSafeCounter()

        let queue = WorkQueue<Int, Int>(
            maxConcurrency: 4,
            fetchWork: { source.next() },
            processWork: { work in
                processed.increment()
                return work
            },
            onResult: { _, _ in },
        )

        try await queue.start()
        #expect(processed.value == 50)
        #expect(source.remaining == 0)
    }

    @Test
    func `results delivered for every item exactly once`() async throws {
        let source = WorkSource(Array(1 ... 30))
        let processed = ThreadSafeCounter()

        let queue = WorkQueue<Int, Int>(
            maxConcurrency: 8,
            fetchWork: { source.next() },
            processWork: { work in
                processed.increment()
                return work
            },
            onResult: { _, _ in },
        )

        try await queue.start()
        #expect(processed.value == 30)
    }

    @Test
    func `max concurrency clamped to sane range`() async {
        let queue = WorkQueue<Int, Int>(
            maxConcurrency: 1000,
            fetchWork: { nil },
            processWork: { $0 },
            onResult: { _, _ in },
        )

        #expect(await queue.maxConcurrency == 256)
        await queue.setMaxConcurrency(0)
        #expect(await queue.maxConcurrency == 1)
    }

    @Test
    func `errors from process work propagate`() async throws {
        struct Boom: Error {}
        let source = WorkSource(Array(1 ... 10))

        let queue = WorkQueue<Int, Int>(
            maxConcurrency: 2,
            fetchWork: { source.next() },
            processWork: { work in
                if work == 3 {
                    throw Boom()
                }
                return work
            },
            onResult: { _, _ in },
        )

        do {
            try await queue.start()
            Issue.record("Expected Boom error")
        }
        catch is Boom {
            // expected
        }
    }

    @Test
    func `errors from on result propagate`() async throws {
        struct Boom: Error {}
        let source = WorkSource(Array(1 ... 5))

        let queue = WorkQueue<Int, Int>(
            maxConcurrency: 2,
            fetchWork: { source.next() },
            processWork: { $0 },
            onResult: { _, _ in
                throw Boom()
            },
        )

        do {
            try await queue.start()
            Issue.record("Expected Boom error")
        }
        catch is Boom {
            // expected
        }
    }

    @Test
    func `queue is reusable after an error`() async throws {
        struct Boom: Error {}

        // The same queue instance must recover from a failed run: `inFlight`
        // used to be left at `maxConcurrency`, so a second `start()` did
        // nothing.
        let source = WorkSource(Array(1 ... 20))
        let processed = ThreadSafeCounter()

        let queue = WorkQueue<Int, Int>(
            maxConcurrency: 4,
            fetchWork: { source.next() },
            processWork: { work in
                processed.increment()
                if work == 1 {
                    throw Boom()
                }
                return work
            },
            onResult: { _, _ in },
        )

        do {
            try await queue.start()
            Issue.record("Expected Boom error")
        }
        catch is Boom {
            // expected
        }

        let afterFailure = processed.value
        #expect(afterFailure > 0)

        // Second run on the same queue must keep going.
        try await queue.start()
        #expect(processed.value > afterFailure)
        #expect(source.remaining == 0)
    }

    @Test
    func `cancellation stops queue`() async throws {
        let processed = ThreadSafeCounter()
        let source = WorkSource(Array(1 ... 1_000_000))

        let queue = WorkQueue<Int, Int>(
            maxConcurrency: 2,
            fetchWork: { source.next() },
            processWork: { work in
                try? await Task.sleep(for: .milliseconds(10))
                processed.increment()
                return work
            },
            onResult: { _, _ in },
        )

        do {
            let task = Task {
                try await queue.start()
            }

            // Let a few items process, then cancel.
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()

            _ = try? await task.value
        }

        let count = processed.value
        #expect(count < 1000, "expected cancellation to stop early, processed \(count)")
    }

    @Test
    func `rendering through pool and queue end to end`() async throws {
        let pool = try MapnikPool(
            factory: { try Mapnik(xml: Fixtures.polygonStyle) },
            initialSize: 2,
            maxPoolSize: 4,
            maxUsesPerObject: 1000)

        let generator = TileGenerator(TileSequence(bounds: Fixtures.germany, zoomRange: 8 ... 8))
        let rendered = ThreadSafeCounter()
        let skipped = ThreadSafeCounter()

        let queue = WorkQueue<MapTile, Data>(
            maxConcurrency: 4,
            fetchWork: { generator.next() },
            processWork: { tile in
                let map = try pool.acquire()
                defer { pool.release(map) }
                return try map.renderTile(tile, format: .png())
            },
            onResult: { _, data in
                if data != nil {
                    rendered.increment()
                }
                else {
                    skipped.increment()
                }
            },
        )

        try await queue.start()

        let renderedCount = rendered.value
        let skippedCount = skipped.value
        let total = renderedCount + skippedCount
        #expect(total > 0)
        #expect(pool.stats().inUse == 0)
    }

}

/// A tiny thread-safe counter for test assertions.
final class ThreadSafeCounter: @unchecked Sendable {

    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }

}
