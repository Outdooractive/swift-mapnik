import Foundation

/// Errors thrown by `MapnikPool`.
public enum MapnikPoolError: Error, Sendable, Equatable {

    /// The pool is at its maximum size and all objects are in use.
    ///
    /// Callers should either wait, reduce concurrency, or handle the error.
    /// `limit` is the pool's `maxPoolSize`, useful for logging.
    case exhausted(limit: Int)

}

/// A thread-safe object pool for `Mapnik` instances.
///
/// Mapnik map objects are expensive to create (a stylesheet with many layers
/// and datasources can take hundreds of milliseconds to load) and are not
/// thread-safe for rendering. A pool amortizes creation cost and lets a
/// bounded number of render operations run in parallel, e.g. one map object
/// per worker of a `WorkQueue`.
///
/// Objects are retired after `maxUsesPerObject` uses: they are dropped
/// instead of returned to the pool, which bounds memory growth from any
/// internal mapnik state accumulation. The next `acquire` then creates a
/// fresh object.
///
/// Usage pattern:
///
/// ```swift
/// let pool = try MapnikPool(factory: { try Mapnik(xml: xml) },
///                           initialSize: 4)
///
/// // In a worker:
/// let map = try pool.acquire()
/// defer { pool.release(map) }
/// let image = try map.renderTile(tile)
/// ```
///
/// - Note: `acquire` throws `MapnikPoolError.exhausted` once `maxPoolSize`
///   objects are in use; it never blocks. Wrap it in your own backpressure
///   mechanism if you need blocking semantics.
public final class MapnikPool: @unchecked Sendable {

    private let lock = NSLock()
    private var available: [Mapnik] = []
    private var useCounts: [ObjectIdentifier: Int] = [:]
    /// Objects currently lent out. A release of an object that is not in this
    /// set is ignored, so a double release cannot hand the same instance to
    /// two callers.
    private var lentOut: Set<ObjectIdentifier> = []
    /// Number of objects currently being created by `acquire`, so concurrent
    /// callers cannot overshoot `maxPoolSize` while a factory runs unlocked.
    private var creating = 0
    private var isClosed = false
    private let factory: @Sendable () throws -> Mapnik
    private let maxPoolSize: Int
    private let maxUsesPerObject: Int
    private let logger: (@Sendable (String) -> Void)?

    /// The number of objects currently lent out.
    ///
    /// Reading this takes the pool lock, so it is safe to poll from another
    /// thread.
    public var inUseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _inUseCount
    }

    private var _inUseCount = 0

    /// Creates a pool and eagerly fills it with `initialSize` map objects.
    ///
    /// - Parameters:
    ///   - factory: Creates a new map object. Called during `init` and from
    ///     `acquire` when the pool grows.
    ///   - initialSize: Number of objects created up front. Must not exceed
    ///     `maxPoolSize`.
    ///   - maxPoolSize: Upper bound for the number of live objects. `acquire`
    ///     throws once this many objects are in use.
    ///   - maxUsesPerObject: Number of times an object may be lent out before
    ///     it is retired (dropped instead of returned to the pool).
    ///   - logger: Optional callback for pool lifecycle diagnostics. Called
    ///     without the pool lock held, so it may call back into the pool.
    /// - Throws: `MapnikError` if an initial object cannot be created, or
    ///   `MapnikError.invalidInput` for out-of-range sizes.
    public init(
        factory: @escaping @Sendable () throws -> Mapnik,
        initialSize: Int = 10,
        maxPoolSize: Int = 100,
        maxUsesPerObject: Int = 50000,
        logger: (@Sendable (String) -> Void)? = nil,
    ) throws {
        guard initialSize >= 0 else {
            throw MapnikError.invalidInput("initialSize must not be negative, got \(initialSize)")
        }
        guard maxPoolSize > 0 else {
            throw MapnikError.invalidInput("maxPoolSize must be positive, got \(maxPoolSize)")
        }
        guard maxUsesPerObject > 0 else {
            throw MapnikError.invalidInput("maxUsesPerObject must be positive, got \(maxUsesPerObject)")
        }
        guard initialSize <= maxPoolSize else {
            throw MapnikError.invalidInput(
                "initialSize (\(initialSize)) must not exceed maxPoolSize (\(maxPoolSize))")
        }

        self.factory = factory
        self.maxPoolSize = maxPoolSize
        self.maxUsesPerObject = maxUsesPerObject
        self.logger = logger

        // Mapnik serializes stylesheet loading internally, so creating the
        // initial objects concurrently would only queue them up on that lock.
        var created: [Mapnik] = []
        created.reserveCapacity(initialSize)
        for _ in 0 ..< initialSize {
            try created.append(factory())
        }

        self.available = created
        for map in created {
            useCounts[ObjectIdentifier(map)] = maxUsesPerObject
        }

        logger?("MapnikPool initialized with \(created.count) objects")
    }

    /// Borrows a map object from the pool, creating a new one if the pool is
    /// below its maximum size.
    ///
    /// The factory runs **without** the pool lock held, so a slow stylesheet
    /// load does not block other `acquire`/`release`/`stats` calls.
    ///
    /// - Throws: `MapnikPoolError.exhausted` if all objects are in use,
    ///   `MapnikError.invalidInput` if the pool was closed, or the factory's
    ///   error if creating a new object fails.
    public func acquire() throws -> Mapnik {
        lock.lock()
        if isClosed {
            lock.unlock()
            throw MapnikError.invalidInput("the pool has been closed")
        }
        if let map = available.popLast() {
            _inUseCount += 1
            lentOut.insert(ObjectIdentifier(map))
            lock.unlock()
            return map
        }

        guard available.count + inUseCount < maxPoolSize else {
            throw MapnikPoolError.exhausted(limit: maxPoolSize)
        }

        creating += 1
        lock.unlock()

        let map: Mapnik
        do {
            map = try factory()
        }
        catch {
            lock.lock()
            creating -= 1
            lock.unlock()
            throw error
        }

        lock.lock()
        creating -= 1
        if isClosed {
            lock.unlock()
            throw MapnikError.invalidInput("the pool has been closed")
        }
        _inUseCount += 1
        lentOut.insert(ObjectIdentifier(map))
        useCounts[ObjectIdentifier(map)] = maxUsesPerObject
        lock.unlock()

        logger?("MapnikPool created object \(ObjectIdentifier(map)) (pool: \(maxPoolSize) max, \(inUseCount) in use)")
        return map
    }

    /// Returns a previously acquired object to the pool.
    ///
    /// Objects that reached `maxUsesPerObject` are retired instead of being
    /// reused; they are released when the last reference goes away.
    ///
    /// Releasing an object that is not currently lent out by this pool is
    /// ignored (and logged), so an accidental double release cannot put the
    /// same instance into the pool twice.
    public func release(_ map: Mapnik) {
        lock.lock()

        let id = ObjectIdentifier(map)
        guard lentOut.remove(id) != nil else {
            lock.unlock()
            logger?("MapnikPool ignoring release of an object that is not lent out: \(id)")
            return
        }

        _inUseCount = max(0, _inUseCount - 1)

        guard let remainingUses = useCounts[id] else {
            // Not created by this pool: accept it, but do not track retirement.
            available.append(map)
            lock.unlock()
            return
        }

        if remainingUses <= 1 {
            // Retire: drop instead of returning to the pool.
            useCounts.removeValue(forKey: id)
            lock.unlock()
            logger?("MapnikPool retiring object \(id)")
            return
        }

        useCounts[id] = remainingUses - 1
        available.append(map)
        lock.unlock()
    }

    /// Drops every idle object and rejects further `acquire` calls.
    ///
    /// Objects that are currently lent out are retired when they are
    /// released. Call this when the stylesheet changes or the pool is no
    /// longer needed.
    public func close() {
        lock.lock()
        isClosed = true
        let dropped = available
        available.removeAll()
        for map in dropped {
            useCounts.removeValue(forKey: ObjectIdentifier(map))
        }
        lock.unlock()
        logger?("MapnikPool closed, dropped \(dropped.count) idle objects")
    }

    /// Pool statistics, useful for monitoring and tests.
    public func stats() -> (available: Int, inUse: Int, live: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (available.count, _inUseCount, available.count + _inUseCount)
    }

}
