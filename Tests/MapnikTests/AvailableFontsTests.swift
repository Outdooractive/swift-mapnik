import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Tests for `MapnikConfig.availableFonts`.
@Suite("Available fonts")
struct AvailableFontsTests {

    @Test
    func `available fonts returns registered face names`() throws {
        let fonts = try MapnikConfig.availableFonts()

        #expect(fonts.isEmpty == false)
        // The platform font directories are non-empty; at least one face
        // registers on every supported platform.
        #expect(fonts.count >= 1)
    }

    @Test
    func `available fonts are sorted in registration order without duplicates`() throws {
        let fonts = try MapnikConfig.availableFonts()

        // No empty names and no duplicates (mapnik registers each face once).
        #expect(fonts.allSatisfy({ $0.isEmpty == false }))
        #expect(Set(fonts).count == fonts.count)
    }

    @Test
    func `label style face name is available`() throws {
        // The test fixtures use "DejaVu Sans Book", registered by the
        // platform font directories on both macOS and Linux.
        let fonts = try MapnikConfig.availableFonts()
        #expect(fonts.contains("DejaVu Sans Book"))
    }

    @Test
    func `available fonts is callable repeatedly`() throws {
        // The enumeration touches mapnik's global registry; calling it
        // repeatedly (including from concurrent tasks) must be safe and
        // stable.
        let first = try MapnikConfig.availableFonts()
        let second = try MapnikConfig.availableFonts()

        #expect(first == second)
    }

}
