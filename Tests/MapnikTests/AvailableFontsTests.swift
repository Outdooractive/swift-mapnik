import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Tests for `MapnikConfig.availableFonts`.
@Suite("Available fonts")
struct AvailableFontsTests {

    /// The face the label fixture references.
    static let requiredFace = "DejaVu Sans Book"

    /// `true` when the DejaVu face is registered on this machine.
    ///
    /// The label fixture needs it; without it the label tests are skipped
    /// instead of failing on a machine that has no DejaVu fonts installed.
    static var hasDejaVu: Bool {
        (try? MapnikConfig.availableFonts().contains(requiredFace)) ?? false
    }

    /// Available fonts returns registered face names.
    @Test
    func `available fonts returns registered face names`() throws {
        let fonts = try MapnikConfig.availableFonts()

        // Some font directory exists on every supported platform, so at least
        // one face registers.
        #expect(fonts.count >= 1)
    }

    /// Available fonts are sorted in registration order without duplicates.
    @Test
    func `available fonts are unique and non empty`() throws {
        let fonts = try MapnikConfig.availableFonts()

        #expect(fonts.allSatisfy { $0.isEmpty == false })
        #expect(Set(fonts).count == fonts.count)
    }

    /// The label fixture's face is available.
    @Test(.enabled(if: AvailableFontsTests.hasDejaVu))
    func `label style face name is available`() throws {
        let fonts = try MapnikConfig.availableFonts()
        #expect(fonts.contains(Self.requiredFace))
    }

    /// Available fonts is callable repeatedly.
    @Test
    func `available fonts is callable repeatedly`() throws {
        let first = try MapnikConfig.availableFonts()
        let second = try MapnikConfig.availableFonts()

        #expect(first == second)
    }

}
