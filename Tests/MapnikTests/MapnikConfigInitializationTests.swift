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
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
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

        return String(decoding: data, as: UTF8.self)
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
    func `scenario nonexistent`() throws {
        do {
            try MapnikConfig.initialize(plugins: "/nonexistent/input", fonts: "/nonexistent/fonts")
            print("scenario-nonexistent: unexpected-success")
        }
        catch {
            print("\(error)")
        }
    }

    @Test(.enabled(if: MapnikConfigInitializationTests.activeScenario == "retryAfterFailure"))
    func `scenario retry after failure`() throws {
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
    func `scenario different paths`() throws {
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
