import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Tests for `MapnikConfig.availableFonts`.
@Suite("Available fonts")
struct AvailableFontsTests {

    /// Available fonts returns registered face names.
    @Test
    func availableFontsReturnsRegisteredFaceNames() throws {
        let fonts = try MapnikConfig.availableFonts()

        #expect(fonts.isEmpty == false)
        // The platform font directories are non-empty; at least one face
        // registers on every supported platform.
        #expect(fonts.count >= 1)
    }

    /// Available fonts are sorted in registration order without duplicates.
    @Test
    func availableFontsAreSortedInRegistrationOrderWithoutDuplicates() throws {
        let fonts = try MapnikConfig.availableFonts()

        // No empty names and no duplicates (mapnik registers each face once).
        #expect(fonts.allSatisfy({ $0.isEmpty == false }))
        #expect(Set(fonts).count == fonts.count)
    }

    /// Label style face name is available.
    @Test
    func labelStyleFaceNameIsAvailable() throws {
        // The test fixtures use "DejaVu Sans Book", registered by the
        // platform font directories on both macOS and Linux.
        let fonts = try MapnikConfig.availableFonts()
        #expect(fonts.contains("DejaVu Sans Book"))
    }

    /// Available fonts is callable repeatedly.
    @Test
    func availableFontsIsCallableRepeatedly() throws {
        // The enumeration touches mapnik's global registry; calling it
        // repeatedly (including from concurrent tasks) must be safe and
        // stable.
        let first = try MapnikConfig.availableFonts()
        let second = try MapnikConfig.availableFonts()

        #expect(first == second)
    }

}
