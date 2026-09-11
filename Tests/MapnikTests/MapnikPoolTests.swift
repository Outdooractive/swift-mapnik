import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Retries `operation` with a short sleep between attempts until it succeeds.
private func withRetry<T: Sendable>(
    maxAttempts: Int,
    operation: @Sendable () throws -> T,
) async throws -> T {
    for attempt in 0 ..< maxAttempts {
        do {
            return try operation()
        }
        catch MapnikPoolError.exhausted {
            if attempt == maxAttempts - 1 {
                throw MapnikPoolError.exhausted
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    fatalError("unreachable")
}

@Suite("MapnikPool")
struct MapnikPoolTests {

    @Test
    func `initial pool filled with initial size objects`() throws {
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

    @Test
    func `acquire and release rounds trips objects`() throws {
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

    @Test
    func `pool refuses to grow beyond max pool size`() throws {
        let pool = try MapnikPool(
            factory: { try Mapnik(xml: Fixtures.polygonStyle) },
            initialSize: 1,
            maxPoolSize: 2,
            maxUsesPerObject: 100)

        _ = try pool.acquire()
        _ = try pool.acquire()

        #expect(throws: MapnikPoolError.exhausted) {
            try pool.acquire()
        }
    }

    @Test
    func `released objects reusable`() throws {
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

    @Test
    func `objects retired after max uses per object uses`() throws {
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

    @Test
    func `concurrent acquire release never exceeds pool size`() async throws {
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

    @Test
    func `factory failures propagate from init`() {
        struct Boom: Error {}

        #expect(throws: Boom.self) {
            _ = try MapnikPool(factory: { throw Boom() }, initialSize: 1)
        }
    }

}
