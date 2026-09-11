import Foundation

/// An actor that runs asynchronous work with bounded concurrency.
///
/// `WorkQueue` pulls work items from a `fetchWork` closure and processes them
/// with up to `maxConcurrency` concurrently running `processWork` calls.
/// Results are delivered one at a time (in completion order) to `onResult`.
///
/// This is the glue between a `TileGenerator` (work source) and a
/// `MapnikPool` (processing) for bulk tile rendering:
///
/// ```swift
/// var generator = TileGenerator(TileSequence(bounds: bounds, zoomRange: 10...12))
/// let queue = WorkQueue(
///     maxConcurrency: 8,
///     fetchWork: { generator.next() },
///     processWork: { tile in
///         let map = try pool.acquire()
///         defer { pool.release(map) }
///         return try map.renderTile(tile)
///     },
///     onResult: { tile, data in
///         try data?.write(to: url(for: tile))
///     })
/// try await queue.start()
/// ```
///
/// Cancellation: the queue cooperatively checks `Task.isCancelled` between
/// work items. When the surrounding task is cancelled, `start` stops fetching
/// new work and throws `CancellationError` once in-flight items drained.
///
/// - Note: `fetchWork` and `onResult` run on the actor; keep them cheap or
///   async. `processWork` runs detached on the cooperative thread pool and
///   must be `Sendable`-safe.
public actor WorkQueue<Work: Sendable, Result: Sendable> {

    private let fetchWork: () async throws -> Work?
    private let processWork: @Sendable (Work) async throws -> Result?
    private let onResult: (Work, Result?) async throws -> Void

    private var _maxConcurrency: Int
    private var inFlight = 0

    /// The maximum number of concurrently processed work items (1...256).
    public var maxConcurrency: Int {
        get { _maxConcurrency }
        set { _maxConcurrency = max(1, min(256, newValue)) }
    }

    /// Sets the maximum concurrency, clamped to 1...256.
    public func setMaxConcurrency(_ value: Int) {
        maxConcurrency = value
    }

    /// - Parameters:
    ///   - maxConcurrency: Upper bound for parallel `processWork` calls.
    ///   - fetchWork: Produces the next work item, or `nil` when the queue
    ///     should drain and finish. Called on the actor.
    ///   - processWork: Transforms a work item into a result. Runs detached
    ///     on the cooperative thread pool, in parallel.
    ///   - onResult: Consumes a finished work item and its result
    ///     (`nil` if `processWork` returned `nil` or the item was skipped).
    ///     Called on the actor, in completion order.
    public init(
        maxConcurrency: Int,
        fetchWork: @escaping () async throws -> Work?,
        processWork: @escaping @Sendable (Work) async throws -> Result?,
        onResult: @escaping (Work, Result?) async throws -> Void,
    ) {
        self._maxConcurrency = max(1, min(256, maxConcurrency))
        self.fetchWork = fetchWork
        self.processWork = processWork
        self.onResult = onResult
    }

    /// Runs the queue until the work source is exhausted.
    ///
    /// - Throws: The first error thrown by `fetchWork`, `processWork` or
    ///   `onResult`, or `CancellationError` if the surrounding task was
    ///   cancelled.
    public func start() async throws {
        try await withThrowingTaskGroup(of: (Work, Result?).self) { group in
            // Initial fill.
            while inFlight < maxConcurrency {
                try checkCancellation()
                guard let work = try await fetchWork() else {
                    break
                }

                inFlight += 1
                group.addTask {
                    try await (work, self.processWork(work))
                }
            }

            // Drain: process results and refill until everything is done.
            while let (work, result) = try await group.next() {
                inFlight -= 1

                try checkCancellation()
                try await onResult(work, result)

                while inFlight < maxConcurrency {
                    try checkCancellation()
                    guard let next = try await fetchWork() else {
                        break
                    }

                    inFlight += 1
                    group.addTask {
                        try await (next, self.processWork(next))
                    }
                }
            }
        }
    }

    /// Cooperative cancellation: aborts once the surrounding task is
    /// cancelled.
    private func checkCancellation() throws {
        if Task.isCancelled {
            throw CancellationError()
        }
    }

}
