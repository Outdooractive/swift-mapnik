import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Retries `operation` with a short sleep between attempts until it succeeds.
private func withRetry<T: Sendable>(
    maxAttempts: Int,
    operation: @Sendable () throws -> T,
) async throws -> T {
    guard maxAttempts > 0 else {
        throw MapnikPoolError.exhausted(limit: 0)
    }

    for attempt in 0 ..< maxAttempts {
        do {
            return try operation()
        }
        catch MapnikPoolError.exhausted {
            if attempt == maxAttempts - 1 {
                throw MapnikPoolError.exhausted(limit: 0)
            }

            try await Task.sleep(for: .milliseconds(5))
        }
    }

    throw MapnikPoolError.exhausted(limit: 0)
}

@Suite("MapnikPool")
struct MapnikPoolTests {

    /// Initial pool filled with initial size objects.
    @Test
    func initialPoolFilledWithInitialSizeObjects() throws {
        let pool = try MapnikPool(
            factory: { try Mapnik(xml: Fixtures.polygonStyle) },
            initialSize: 3,
            maxPoolSize: 10,
            maxUsesPerObject: 100)

        let stats = pool.stats()
        #expect(stats.available == 3)
        #expect(stats.inUse == 0)
        #expect(stats.live == 3)
    }

    /// Acquire and release rounds trips objects.
    @Test
    func acquireAndReleaseRoundsTripsObjects() throws {
        let pool = try MapnikPool(
            factory: { try Mapnik(xml: Fixtures.polygonStyle) },
            initialSize: 1,
            maxPoolSize: 2,
            maxUsesPerObject: 100)

        let first = try pool.acquire()
        #expect(pool.stats().inUse == 1)
        #expect(pool.stats().available == 0)

        // Second acquire has to create a new object (pool grew).
        let second = try pool.acquire()
        #expect(ObjectIdentifier(first) != ObjectIdentifier(second))
        #expect(pool.stats().live == 2)

        pool.release(first)
        pool.release(second)
        #expect(pool.stats().available == 2)
        #expect(pool.stats().inUse == 0)
    }

    /// Pool refuses to grow beyond max pool size.
    @Test
    func poolRefusesToGrowBeyondMaxPoolSize() throws {
        let pool = try MapnikPool(
            factory: { try Mapnik(xml: Fixtures.polygonStyle) },
            initialSize: 1,
            maxPoolSize: 2,
            maxUsesPerObject: 100)

        _ = try pool.acquire()
        _ = try pool.acquire()

        #expect(throws: MapnikPoolError.exhausted(limit: 2)) {
            try pool.acquire()
        }
    }

    /// Released objects reusable.
    @Test
    func releasedObjectsReusable() throws {
        let pool = try MapnikPool(
            factory: { try Mapnik(xml: Fixtures.polygonStyle) },
            initialSize: 1,
            maxPoolSize: 1,
            maxUsesPerObject: 100)

        let first = try pool.acquire()
        pool.release(first)
        let second = try pool.acquire()
        #expect(ObjectIdentifier(first) == ObjectIdentifier(second))
    }

    /// Double release does not hand the same object to two callers.
    @Test
    func doubleReleaseDoesNotHandTheSameObjectToTwoCallers() throws {
        let pool = try MapnikPool(
            factory: { try Mapnik(xml: Fixtures.polygonStyle) },
            initialSize: 1,
            maxPoolSize: 2,
            maxUsesPerObject: 100)

        let map = try pool.acquire()
        pool.release(map)
        pool.release(map) // ignored: the object is not lent out

        let first = try pool.acquire()
        #expect(ObjectIdentifier(first) == ObjectIdentifier(map))

        // The second acquire must create a fresh object, not hand out `map`
        // again while `first` is still in use.
        let second = try pool.acquire()
        #expect(ObjectIdentifier(second) != ObjectIdentifier(first))
    }

    /// Objects retired after max uses per object uses.
    @Test
    func objectsRetiredAfterMaxUsesPerObjectUses() throws {
        let pool = try MapnikPool(
            factory: { try Mapnik(xml: Fixtures.polygonStyle) },
            initialSize: 1,
            maxPoolSize: 1,
            maxUsesPerObject: 2)

        let first = try pool.acquire()
        pool.release(first) // uses left: 1
        let second = try pool.acquire()
        #expect(ObjectIdentifier(first) == ObjectIdentifier(second))
        pool.release(second) // uses left: 0 → retire

        let third = try pool.acquire()
        #expect(ObjectIdentifier(third) != ObjectIdentifier(first))
    }

    /// Concurrent acquire release never exceeds pool size.
    @Test
    func concurrentAcquireReleaseNeverExceedsPoolSize() async throws {
        let pool = try MapnikPool(
            factory: { try Mapnik(xml: Fixtures.polygonStyle) },
            initialSize: 2,
            maxPoolSize: 4,
            maxUsesPerObject: 10000)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    // The pool is non-blocking: keep trying until an object
                    // becomes available.
                    let map: Mapnik = try await withRetry(maxAttempts: 1000) {
                        try pool.acquire()
                    }
                    defer { pool.release(map) }
                    _ = try map.renderTile(Fixtures.europeTile, format: .png())
                }
            }
            try await group.waitForAll()
        }

        let stats = pool.stats()
        #expect(stats.inUse == 0)
        #expect(stats.available == stats.live)
        #expect(stats.live <= 4)
    }

    /// Factory failures propagate from init.
    @Test
    func factoryFailuresPropagateFromInit() {
        struct Boom: Error {}

        #expect(throws: Boom.self) {
            _ = try MapnikPool(factory: { throw Boom() }, initialSize: 1)
        }
    }

    /// Init rejects out of range sizes.
    @Test
    func initRejectsOutOfRangeSizes() {
        #expect(throws: MapnikError.self) {
            _ = try MapnikPool(factory: { try Mapnik(xml: Fixtures.polygonStyle) }, initialSize: -1)
        }
        #expect(throws: MapnikError.self) {
            _ = try MapnikPool(factory: { try Mapnik(xml: Fixtures.polygonStyle) }, maxPoolSize: 0)
        }
        #expect(throws: MapnikError.self) {
            _ = try MapnikPool(factory: { try Mapnik(xml: Fixtures.polygonStyle) }, maxUsesPerObject: 0)
        }
        // initialSize above maxPoolSize is rejected instead of clamped.
        #expect(throws: MapnikError.self) {
            _ = try MapnikPool(
                factory: { try Mapnik(xml: Fixtures.polygonStyle) },
                initialSize: 20,
                maxPoolSize: 10)
        }
    }

    /// Logger may call back into the pool.
    @Test
    func loggerMayCallBackIntoThePool() throws {
        // The logger used to be invoked while the pool lock was held, so a
        // logger calling stats() deadlocked. It now runs after unlocking.
        final class Box: @unchecked Sendable {

            let lock = NSLock()
            var pool: MapnikPool?

        }

        let box = Box()
        let pool = try MapnikPool(
            factory: { try Mapnik(xml: Fixtures.polygonStyle) },
            initialSize: 1,
            maxPoolSize: 2,
            maxUsesPerObject: 100,
            logger: { _ in
                box.lock.lock()
                let current = box.pool
                box.lock.unlock()
                _ = current?.stats()
            })
        box.lock.lock()
        box.pool = pool
        box.lock.unlock()

        let map = try pool.acquire()
        pool.release(map)
        #expect(pool.stats().inUse == 0)
    }

    /// Close drops idle objects and rejects further acquires.
    @Test
    func closeDropsIdleObjectsAndRejectsFurtherAcquires() throws {
        let pool = try MapnikPool(
            factory: { try Mapnik(xml: Fixtures.polygonStyle) },
            initialSize: 2,
            maxPoolSize: 4,
            maxUsesPerObject: 100)

        #expect(pool.stats().available == 2)
        pool.close()
        #expect(pool.stats().available == 0)

        #expect(throws: MapnikError.self) {
            try pool.acquire()
        }
    }

    /// InUseCount is readable while objects are lent out.
    @Test
    func inUseCountIsReadableWhileObjectsAreLentOut() throws {
        let pool = try MapnikPool(
            factory: { try Mapnik(xml: Fixtures.polygonStyle) },
            initialSize: 2,
            maxPoolSize: 4,
            maxUsesPerObject: 100)

        let map = try pool.acquire()
        #expect(pool.inUseCount == 1)
        #expect(pool.stats().inUse == 1)
        pool.release(map)
        #expect(pool.inUseCount == 0)
    }

}
