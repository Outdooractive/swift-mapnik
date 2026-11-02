import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Tests for the platform plugin/font discovery helpers.
///
/// These are pure functions over paths, so they do not touch mapnik's global
/// state and can run in any order.
@Suite("Plugin discovery")
struct PluginDiscoveryTests {

    @Test
    func `version components split dotted versions`() {
        #expect(MapnikConfig.versionComponents("/usr/lib/mapnik/4.2/input") == [4, 2])
        #expect(MapnikConfig.versionComponents("/usr/lib/mapnik/3.1/input") == [3, 1])
        #expect(MapnikConfig.versionComponents("/usr/lib/mapnik/4.10/input") == [4, 10])
        #expect(MapnikConfig.versionComponents("/usr/lib/mapnik/10.0/input") == [10, 0])
        #expect(MapnikConfig.versionComponents(
            "/usr/lib/aarch64-linux-gnu/mapnik/4.2/input") == [4, 2])
    }

    @Test
    func `version components are empty without a version`() {
        #expect(MapnikConfig.versionComponents("/usr/lib/mapnik/input") == [])
        #expect(MapnikConfig.versionComponents("/usr/lib/mapnik/foo/input") == [])
        #expect(MapnikConfig.versionComponents("input") == [])
        #expect(MapnikConfig.versionComponents("") == [])
    }

    @Test
    func `versions compare numerically not lexicographically`() {
        // 4.10 is newer than 4.2, although "4.10" < "4.2" lexicographically.
        #expect(MapnikConfig.compareVersionedPaths(
            "/usr/lib/mapnik/4.10/input",
            "/usr/lib/mapnik/4.2/input") == .orderedDescending)

        // 10.0 is newer than 3.1, although "10.0" < "3.1" lexicographically.
        #expect(MapnikConfig.compareVersionedPaths(
            "/usr/lib/mapnik/10.0/input",
            "/usr/lib/mapnik/3.1/input") == .orderedDescending)
    }

    @Test
    func `versions compare across majors and minors`() {
        #expect(MapnikConfig.compareVersionedPaths(
            "/usr/lib/mapnik/4.2/input",
            "/usr/lib/mapnik/3.1/input") == .orderedDescending)
        #expect(MapnikConfig.compareVersionedPaths(
            "/usr/lib/mapnik/3.1/input",
            "/usr/lib/mapnik/4.2/input") == .orderedAscending)
        #expect(MapnikConfig.compareVersionedPaths(
            "/usr/lib/mapnik/4.2/input",
            "/usr/lib/mapnik/4.2/input") == .orderedSame)
    }

    @Test
    func `versioned paths beat unversioned ones`() {
        #expect(MapnikConfig.compareVersionedPaths(
            "/usr/lib/mapnik/4.2/input",
            "/usr/lib/mapnik/input") == .orderedDescending)
        #expect(MapnikConfig.compareVersionedPaths(
            "/usr/lib/mapnik/input",
            "/usr/lib/mapnik/4.2/input") == .orderedAscending)
    }

    @Test
    func `highest versioned directory picks the newest`() throws {
        let root = FileManager.default
            .temporaryDirectory
            .appending(path: "mapnik-plugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        for version in ["3.1", "4.2", "4.10"] {
            let directory = root.appending(path: version).appending(path: "input")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "".write(to: directory.appending(path: "geojson.input"), atomically: true, encoding: .utf8)
        }

        // An empty directory must not win just because it sorts high.
        let empty = root.appending(path: "9.9").appending(path: "input")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let pattern = root.path + "/*/input"
        let resolved = MapnikConfig.highestVersionedDirectory(globPattern: pattern)
        #expect(resolved?.hasSuffix("/4.10/input") == true)
    }

    @Test
    func `default plugin path is a directory containing plugins`() throws {
        let path = try #require(MapnikConfig.defaultPluginPath)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test
    func `default font path exists`() throws {
        let path = try #require(MapnikConfig.defaultFontPath)
        #expect(FileManager.default.fileExists(atPath: path))
    }

}
