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
/// let generator = TileGenerator(TileSequence(bounds: bounds, zoomRange: 10 ... 12))
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
/// Errors: the first error thrown by `fetchWork`, `processWork` or
/// `onResult` cancels the remaining work, drains the in-flight tasks and is
/// rethrown. The queue is reusable afterwards — a subsequent `start()` runs
/// from a clean state.
///
/// - Note: `fetchWork` and `onResult` run on the actor; keep them cheap or
///   async. `processWork` runs detached on the cooperative thread pool and
///   must be `Sendable`-safe.
public actor WorkQueue<Work: Sendable, Result: Sendable> {

    private let fetchWork: @Sendable () async throws -> Work?
    private let processWork: @Sendable (Work) async throws -> Result?
    private let onResult: @Sendable (Work, Result?) async throws -> Void

    /// The range ``maxConcurrency`` is clamped to.
    ///
    /// Values outside this range are clamped rather than rejected, so callers
    /// that need to validate their own input can check against it first.
    public static var concurrencyRange: ClosedRange<Int> {
        1 ... 256
    }

    private var _maxConcurrency: Int
    private var inFlight = 0

    /// The maximum number of concurrently processed work items.
    ///
    /// The value is clamped to ``concurrencyRange``: assigning `1000` stores
    /// `256`, assigning `0` stores `1`. Check against ``concurrencyRange``
    /// before assigning if the exact value matters.
    ///
    /// Changing this while ``start()`` is running is supported. The queue
    /// re-reads it each time it refills, so a raised limit takes effect as
    /// soon as an in-flight item finishes. Lowering it does not interrupt
    /// running `processWork` calls, so the number of concurrent items can
    /// briefly exceed the new limit until they complete.
    public var maxConcurrency: Int {
        get { _maxConcurrency }
        set { _maxConcurrency = Self.clamp(newValue) }
    }

    /// Clamps `value` into ``concurrencyRange``.
    private static func clamp(_ value: Int) -> Int {
        min(max(value, concurrencyRange.lowerBound), concurrencyRange.upperBound)
    }

    /// Sets ``maxConcurrency`` from outside the actor.
    ///
    /// The property itself is readable from any context, but Swift only
    /// permits mutating actor state from inside the actor, so this method is
    /// the supported way to change the limit. It clamps to
    /// ``concurrencyRange`` exactly like the setter does.
    public func setMaxConcurrency(_ value: Int) {
        maxConcurrency = value
    }

    /// - Parameters:
    ///   - maxConcurrency: Upper bound for parallel `processWork` calls,
    ///     clamped to ``concurrencyRange``.
    ///   - fetchWork: Produces the next work item, or `nil` when the queue
    ///     should drain and finish. Called on the actor.
    ///   - processWork: Transforms a work item into a result. Runs detached
    ///     on the cooperative thread pool, in parallel.
    ///   - onResult: Consumes a finished work item and its result
    ///     (`nil` if `processWork` returned `nil` or the item was skipped).
    ///     Called on the actor, in completion order.
    public init(
        maxConcurrency: Int,
        fetchWork: @escaping @Sendable () async throws -> Work?,
        processWork: @escaping @Sendable (Work) async throws -> Result?,
        onResult: @escaping @Sendable (Work, Result?) async throws -> Void,
    ) {
        self._maxConcurrency = Self.clamp(maxConcurrency)
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
        inFlight = 0

        do {
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
        catch {
            // The task group cancels its children on scope exit, but
            // cancellation is cooperative: wait for the in-flight tasks so
            // `start` does not return while work is still running.
            inFlight = 0
            throw error
        }

        inFlight = 0
    }

    /// Cooperative cancellation: aborts once the surrounding task is
    /// cancelled.
    private func checkCancellation() throws {
        if Task.isCancelled {
            throw CancellationError()
        }
    }

}
