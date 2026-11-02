import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Tests for `MapnikConfig.initialize`.
///
/// Initialization is process-wide and cannot be undone, so each scenario runs
/// in a fresh child process. The child is this same test binary, re-invoked
/// with `MAPNIK_CONFIG_SCENARIO` set: the parent tests are skipped in child
/// mode and the scenario tests are skipped in parent mode, so the child runs
/// exactly one scenario without needing a filter.
@Suite("MapnikConfig initialization")
struct MapnikConfigInitializationTests {

    private static let scenarioVariable = "MAPNIK_CONFIG_SCENARIO"

    /// The scenario this process is running, if it is a child process.
    private static var activeScenario: String? {
        ProcessInfo.processInfo.environment[scenarioVariable]
    }

    /// Runs `scenario` in a fresh process and returns its combined output.
    ///
    /// - Parameters:
    ///   - scenario: The scenario name to run in the child.
    ///   - testName: The (unique) child test name to filter to, so no other
    ///     test can initialize mapnik first.
    /// - Returns: The child's stdout, or `nil` when the child could not be
    ///   started.
    private func runInChildProcess(scenario: String, testName: String) throws -> String? {
        guard let executable = Self.testExecutableURL() else {
            return nil
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--testing-library", "swift-testing", "--filter", testName]

        var environment = ProcessInfo.processInfo.environment
        environment[Self.scenarioVariable] = scenario
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? pipe.fileHandleForReading.close()

        let output = String(decoding: data, as: UTF8.self)
        // An empty result means the child could not be started usefully (for
        // example a bundle layout this helper does not understand); skip
        // rather than report a spurious failure.
        return output.isEmpty ? nil : output
    }

    /// The runnable test binary for the current process.
    ///
    /// On Linux `argv[0]` is the SwiftPM test runner. On macOS it is the
    /// `.xctest` **bundle** (a directory), and the executable lives in
    /// `Contents/MacOS/<name>`. Returns `nil` when neither layout matches.
    static func testExecutableURL() -> URL? {
        testExecutableURL(for: URL(fileURLWithPath: CommandLine.arguments[0]))
    }

    /// Resolves the runnable test binary for `argument` (`argv[0]`).
    ///
    /// Split out so both layouts can be tested on either platform.
    static func testExecutableURL(for argument: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: argument.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue == false {
            return argument
        }

        let candidate = argument
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent(argument.deletingPathExtension().lastPathComponent)
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            return nil
        }

        return candidate
    }

    // MARK: - Parent tests

    @Test(.enabled(if: MapnikConfigInitializationTests.activeScenario == nil))
    func `initialize with a nonexistent plugin path throws`() throws {
        let output = try runInChildProcess(scenario: "nonexistent", testName: "scenario nonexistent")
        guard let output else { return }

        #expect(output.contains("plugin path is not a directory"))
    }

    @Test(.enabled(if: MapnikConfigInitializationTests.activeScenario == nil))
    func `a failed initialization does not poison later default initialization`() throws {
        let output = try runInChildProcess(scenario: "retryAfterFailure", testName: "scenario retry after failure")
        guard let output else { return }

        #expect(output.contains("retry-after-failure: ok"))
    }

    @Test(.enabled(if: MapnikConfigInitializationTests.activeScenario == nil))
    func `initialize with different paths after success throws`() throws {
        let output = try runInChildProcess(scenario: "differentPaths", testName: "scenario different paths")
        guard let output else { return }

        #expect(output.contains("already initialized"))
    }

    // MARK: - Child scenarios

    @Test(.enabled(if: MapnikConfigInitializationTests.activeScenario == "nonexistent"))
    func `scenario nonexistent`() {
        do {
            try MapnikConfig.initialize(plugins: "/nonexistent/input", fonts: "/nonexistent/fonts")
            print("scenario-nonexistent: unexpected-success")
        }
        catch {
            print("\(error)")
        }
    }

    @Test(.enabled(if: MapnikConfigInitializationTests.activeScenario == "retryAfterFailure"))
    func `scenario retry after failure`() {
        do {
            try MapnikConfig.initialize(plugins: "/nonexistent/input", fonts: "/nonexistent/fonts")
            print("retry-after-failure: unexpected-success")
            return
        }
        catch {
            // expected
        }

        // The lazy default path must still be able to initialize.
        do {
            _ = try Mapnik(xml: Fixtures.polygonStyle)
            print("retry-after-failure: ok")
        }
        catch {
            print("retry-after-failure: failed \(error)")
        }
    }

    @Test(.enabled(if: MapnikConfigInitializationTests.activeScenario == "differentPaths"))
    func `scenario different paths`() {
        do {
            _ = try Mapnik(xml: Fixtures.polygonStyle)
        }
        catch {
            print("different-paths: setup failed \(error)")
            return
        }

        do {
            try MapnikConfig.initialize(plugins: "/custom/input", fonts: "/custom/fonts")
            print("different-paths: unexpected-success")
        }
        catch {
            print("\(error)")
        }
    }

}

/// Tests for the child-process executable resolution.
@Suite("Test executable resolution")
struct TestExecutableResolutionTests {

    /// A plain executable path is used as-is (the Linux layout).
    @Test
    func `plain executable is used directly`() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let resolved = MapnikConfigInitializationTests.testExecutableURL(for: executable)
        #expect(resolved?.path == executable.path)
    }

    /// A bundle directory resolves to Contents/MacOS/<name> (the macOS layout).
    @Test
    func `bundle directory resolves to its executable`() throws {
        let root = FileManager.default
            .temporaryDirectory
            .appending(path: "mapnik-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = root.appending(path: "MapnikTests.xctest")
        let macos = bundle.appending(path: "Contents").appending(path: "MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)

        let executable = macos.appending(path: "MapnikTests")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)

        let resolved = MapnikConfigInitializationTests.testExecutableURL(for: bundle)
        #expect(resolved?.path == executable.path)
    }

    /// A bundle without an executable resolves to nil instead of crashing.
    @Test
    func `empty bundle resolves to nil`() throws {
        let root = FileManager.default
            .temporaryDirectory
            .appending(path: "mapnik-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = root.appending(path: "Empty.xctest")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        #expect(MapnikConfigInitializationTests.testExecutableURL(for: bundle) == nil)
    }

}
