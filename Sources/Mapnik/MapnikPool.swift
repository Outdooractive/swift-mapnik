import Foundation

/// Errors thrown by `MapnikPool`.
public enum MapnikPoolError: Error, Sendable {

    /// The pool is at its maximum size and all objects are in use.
    /// Callers should either wait, reduce concurrency, or handle the error.
    case exhausted

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
    private let factory: @Sendable () throws -> Mapnik
    private let maxPoolSize: Int
    private let maxUsesPerObject: Int
    private let logger: (@Sendable (String) -> Void)?

    /// The number of objects currently lent out.
    public private(set) var inUseCount = 0

    /// Creates a pool and eagerly fills it with `initialSize` map objects.
    ///
    /// - Parameters:
    ///   - factory: Creates a new map object. Called during `init` and from
    ///     `acquire` when the pool grows.
    ///   - initialSize: Number of objects created up front, in parallel
    ///     (stylesheet loading is CPU-bound; parallel creation is much faster
    ///     than a serial loop).
    ///   - maxPoolSize: Upper bound for the number of live objects. `acquire`
    ///     throws once this many objects are in use.
    ///   - maxUsesPerObject: Number of times an object may be lent out before
    ///     it is retired (dropped instead of returned to the pool).
    ///   - logger: Optional callback for pool lifecycle diagnostics.
    /// - Throws: `MapnikError` if an initial object cannot be created.
    public init(
        factory: @escaping @Sendable () throws -> Mapnik,
        initialSize: Int = 10,
        maxPoolSize: Int = 100,
        maxUsesPerObject: Int = 50000,
        logger: (@Sendable (String) -> Void)? = nil,
    ) throws {
        precondition(initialSize >= 0, "initialSize must not be negative")
        precondition(maxPoolSize > 0, "maxPoolSize must be positive")
        precondition(maxUsesPerObject > 0, "maxUsesPerObject must be positive")

        self.factory = factory
        self.maxPoolSize = maxPoolSize
        self.maxUsesPerObject = maxUsesPerObject
        self.logger = logger

        // Create the initial objects concurrently: loading a stylesheet is
        // CPU-bound and serial creation dominates startup time otherwise.
        let initialCount = min(max(0, initialSize), maxPoolSize)
        let collector = CreationCollector()
        let group = DispatchGroup()
        let creationQueue = DispatchQueue(label: "mapnik.pool.init", attributes: .concurrent)
        let creationLimiter = DispatchSemaphore(value: min(initialCount, 10))

        for _ in 0 ..< initialCount {
            group.enter()
            creationLimiter.wait()
            creationQueue.async {
                defer {
                    creationLimiter.signal()
                    group.leave()
                }

                do {
                    try collector.add(factory())
                }
                catch {
                    collector.fail(error)
                }
            }
        }
        group.wait()

        if let creationError = collector.error {
            throw creationError
        }

        let created = collector.maps
        self.available = created
        for map in created {
            useCounts[ObjectIdentifier(map)] = maxUsesPerObject
        }

        logger?("MapnikPool initialized with \(created.count) objects")
    }

    /// Thread-safe collector for the parallel pool initialization.
    private final class CreationCollector: @unchecked Sendable {

        private let lock = NSLock()
        private var collectedMaps: [Mapnik] = []
        private var failure: Error?

        func add(_ map: Mapnik) {
            lock.lock()
            defer { lock.unlock() }
            collectedMaps.append(map)
        }

        func fail(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            if failure == nil {
                failure = error
            }
        }

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }

        var maps: [Mapnik] {
            lock.lock()
            defer { lock.unlock() }
            return collectedMaps
        }

    }

    /// Borrows a map object from the pool, creating a new one if the pool is
    /// below its maximum size.
    ///
    /// - Throws: `MapnikPoolError.exhausted` if all objects are in use,
    ///   or the factory's error if creating a new object fails.
    public func acquire() throws -> Mapnik {
        lock.lock()
        defer { lock.unlock() }

        if let map = available.popLast() {
            inUseCount += 1
            return map
        }

        guard available.count + inUseCount < maxPoolSize else {
            throw MapnikPoolError.exhausted
        }

        let map = try factory()
        inUseCount += 1
        useCounts[ObjectIdentifier(map)] = maxUsesPerObject

        if let logger {
            logger("MapnikPool created object \(ObjectIdentifier(map)) (pool: \(available.count) available, \(inUseCount) in use)")
        }
        return map
    }

    /// Returns a previously acquired object to the pool.
    ///
    /// Objects that reached `maxUsesPerObject` are retired instead of being
    /// reused; they are released when the last reference goes away.
    public func release(_ map: Mapnik) {
        lock.lock()
        defer { lock.unlock() }

        let id = ObjectIdentifier(map)
        guard let remainingUses = useCounts[id] else {
            // Unknown object: not created by this pool. Accept it defensively
            // but do not track retirement for it.
            available.append(map)
            inUseCount = max(0, inUseCount - 1)
            return
        }

        inUseCount = max(0, inUseCount - 1)

        if remainingUses <= 1 {
            // Retire: drop instead of returning to the pool.
            useCounts.removeValue(forKey: id)
            if let logger {
                logger("MapnikPool retiring object \(id)")
            }
            return
        }

        useCounts[id] = remainingUses - 1
        available.append(map)
    }

    /// Pool statistics, useful for monitoring and tests.
    public func stats() -> (available: Int, inUse: Int, live: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (available.count, inUseCount, available.count + inUseCount)
    }

}
