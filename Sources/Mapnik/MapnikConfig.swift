import Foundation
import MapnikC

/// Global, one-time initialization of the mapnik library.
///
/// Before any `Mapnik` instance can render, mapnik needs to know where to find
/// its datasource input plugins (PostGIS, GeoJSON, Shapefile, ...) and its
/// fonts. This is a process-wide operation: call `initialize` once, or rely on
/// the platform defaults applied by the lazy `ensureInitialized` path used by
/// `Mapnik(xml:...)`.
///
/// Initialization happens exactly once per process. Calling `initialize` again
/// with the same paths is a no-op; calling it with *different* paths after
/// initialization already happened throws, because mapnik's registries cannot
/// be reset. This makes an accidental "too late" call visible instead of
/// silently ignoring the requested paths.
public enum MapnikConfig {

    private final class State: @unchecked Sendable {

        let lock = NSLock()
        var result: Result<Void, MapnikError>?
        /// The paths the successful initialization used, for diagnostics.
        var plugins: String?
        var fonts: String?
        /// Cached result of the Linux plugin-path discovery. `nil` means "not
        /// resolved yet"; `.some(nil)` means "resolved, nothing found".
        var cachedLinuxPluginPath: String??
        /// Overrides the discovery used by ``defaultPluginPath``. Internal so
        /// the test target can exercise the discovery order without a matching
        /// filesystem layout.
        var pluginPathProvider: (@Sendable () -> String?)?

    }

    private static let state = State()

    /// Registers datasource plugins and fonts from the given directories.
    ///
    /// Both paths are scanned recursively. Passing `nil` or an empty string
    /// skips registration for that resource, e.g. when no fonts are needed.
    ///
    /// It is safe (and cheap) to call this multiple times; only the first
    /// successful call has an effect. A failed attempt is **not** cached, so it
    /// can be retried (for example with corrected paths) and does not prevent
    /// the lazy default initialization from running later.
    ///
    /// - Parameters:
    ///   - inputPluginsPath: Directory containing mapnik `.input` plugins.
    ///   - fontsPath: Directory containing fonts to register.
    /// - Throws: `MapnikError.initialization` if plugin or font registration
    ///   failed, or if initialization already succeeded with different paths.
    public static func initialize(
        plugins inputPluginsPath: String? = nil,
        fonts fontsPath: String? = nil,
    ) throws {
        state.lock.lock()
        defer { state.lock.unlock() }

        if let result = state.result {
            switch result {
            case .success:
                // Re-initialization with different paths cannot take effect:
                // mapnik's registries are append-only and already populated.
                let samePlugins = state.plugins == inputPluginsPath
                let sameFonts = state.fonts == fontsPath
                if samePlugins == false || sameFonts == false {
                    throw MapnikError.initialization(
                        "mapnik was already initialized with plugins '\(state.plugins ?? "<default>")' "
                            + "and fonts '\(state.fonts ?? "<default>")'; "
                            + "initialization must happen before the first map is created")
                }
                return

            case let .failure(error):
                throw error
            }
        }
        do {
            try CErrors.withError(MapnikError.initialization) { errorOut in
                mapnik_init(inputPluginsPath, fontsPath, errorOut)
            }
            state.result = .success(())
            state.plugins = inputPluginsPath
            state.fonts = fontsPath
        }
        catch let error as MapnikError {
            // Failures are deliberately *not* cached: caching them would let a
            // single bad explicit path poison the process, because the lazy
            // `ensureInitialized` path could never retry with the defaults.
            throw error
        }
        catch {
            throw MapnikError.initialization("\(error)")
        }
    }

    /// Cached Linux plugin-path discovery (see ``defaultPluginPath``).
    /// `pkg-config` spawns a process, so the resolved value is computed once
    /// and reused.
    ///
    /// The cache lives in `State` (guarded by its lock) rather than in a lazy
    /// `static let`, so tests can override the provider and reset it.
    private static func linuxPluginPath() -> String? {
        state.lock.lock()
        defer { state.lock.unlock() }

        if let cached = state.cachedLinuxPluginPath {
            return cached
        }

        let resolved = state.pluginPathProvider?() ?? linuxPluginPathUncached()
        state.cachedLinuxPluginPath = resolved
        return resolved
    }

    /// Resets the cached Linux plugin path so the next lookup re-runs
    /// discovery. Intended for tests.
    static func resetPluginPathCache() {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.cachedLinuxPluginPath = nil
        state.pluginPathProvider = nil
    }

    /// The plugin-directory candidates for `linuxPluginPathUncached`, in
    /// discovery order.
    private static func linuxPluginPathUncached() -> String? {
        if let path = pkgConfigPluginsDir(), isPluginDirectory(path) {
            return path
        }

        // Debian mapnik 4.x: /usr/lib/<triplet>/mapnik/<version>/input —
        // multiarch triplets (aarch64-linux-gnu, x86_64-linux-gnu) sit in
        // the first level, the mapnik version in the second.
        if let path = highestVersionedDirectory(
            globPattern: "/usr/lib/*/mapnik/*/input")
        {
            return path
        }

        // Ubuntu LTS mapnik 3.1: /usr/lib/mapnik/<version>/input — no
        // multiarch level (the pre-4.x layout).
        if let path = highestVersionedDirectory(
            globPattern: "/usr/lib/mapnik/*/input")
        {
            return path
        }

        return nil
    }

    /// Reads the `plugins_dir` variable from `libmapnik.pc` via
    /// `pkg-config`. Returns `nil` when `pkg-config` is missing, the
    /// module is unknown (mapnik 3.1 ships no `.pc` file), or the variable
    /// is not set.
    ///
    /// stderr is discarded rather than piped, and stdout is drained before
    /// waiting, so a chatty `pkg-config` cannot fill a pipe and deadlock.
    private static func pkgConfigPluginsDir() -> String? {
        let process = Process()

        // `pkg-config` is usually /usr/bin/pkg-config; some distros place
        // it elsewhere — fall back to the PATH lookup.
        let pkgConfigURL = FileManager.default.fileExists(atPath: "/usr/bin/pkg-config")
            ? URL(fileURLWithPath: "/usr/bin/pkg-config")
            : URL(fileURLWithPath: "/usr/bin/env")
        if pkgConfigURL.path.hasSuffix("env") {
            process.executableURL = pkgConfigURL
            process.arguments = ["pkg-config", "libmapnik", "--variable=plugins_dir"]
        }
        else {
            process.executableURL = pkgConfigURL
            process.arguments = ["libmapnik", "--variable=plugins_dir"]
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        }
        catch {
            // pkg-config itself is not installed.
            return nil
        }

        defer { try? pipe.fileHandleForReading.close() }

        // Read before waiting so a large stdout cannot block the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    /// Expands `globPattern` (exactly one `*` per level) and returns the
    /// directory with the highest version number in the version component.
    /// Non-numeric versions sort last, preferring the lexicographically
    /// greater name as a deterministic tiebreak.
    static func highestVersionedDirectory(globPattern: String) -> String? {
        // The pattern is split at the `*` placeholders: prefix, then
        // literal suffixes between them. Matching the literal parts keeps
        // the implementation dependency-free (no glob library).
        let components = globPattern.split(separator: "*", omittingEmptySubsequences: false)
        guard components.count >= 2 else {
            return nil
        }

        let prefix = String(components[0])
        let suffixes = components.dropFirst().map(String.init)

        // Walk the first directory level from the prefix, expanding each
        // `*` with the directory entries at that position.
        var current: [String] = [prefix]
        for (index, suffix) in suffixes.enumerated() {
            var next: [String] = []
            for base in current {
                let entries = (try? FileManager.default.contentsOfDirectory(
                    atPath: base)) ?? []
                next.append(contentsOf: entries.map { base + $0 + suffix })
            }
            current = next
            if index == suffixes.count - 1 {
                break
            }
        }

        return current
            .filter { isPluginDirectory($0) }
            .max { compareVersionedPaths($0, $1) == .orderedAscending }
    }

    /// True when `path` exists as a directory containing at least one
    /// `.input` plugin file.
    private static func isPluginDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return entries.contains { $0.hasSuffix(".input") }
    }

    /// Compares two candidate plugin paths by their trailing version
    /// components (e.g. `.../mapnik/4.2/input` vs `.../mapnik/3.1/input`).
    ///
    /// Numeric segments compare numerically, so `4.10` sorts above `4.2` and
    /// `10.0` above `3.1`. Paths without a numeric version sort below paths
    /// with one, and the full path breaks ties deterministically.
    static func compareVersionedPaths(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = versionComponents(lhs)
        let r = versionComponents(rhs)

        // Paths without a version lose against paths with one.
        if l.isEmpty != r.isEmpty {
            return l.isEmpty ? .orderedAscending : .orderedDescending
        }

        for (a, b) in zip(l, r) where a != b {
            return a < b ? .orderedAscending : .orderedDescending
        }

        if l.count != r.count {
            return l.count < r.count ? .orderedAscending : .orderedDescending
        }

        if lhs == rhs {
            return .orderedSame
        }

        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    /// The numeric version segments of a plugin path, e.g.
    /// `.../mapnik/4.2/input` → `[4, 2]`.
    ///
    /// The version component sits directly before the trailing `input` and is
    /// dot-separated (`4.2`), so it must be split on `.` — `Int("4.2")` is
    /// `nil`.
    static func versionComponents(_ path: String) -> [Int] {
        let parts = path.split(separator: "/")
        guard let inputIndex = parts.lastIndex(of: "input"), inputIndex > 0 else {
            return []
        }

        return parts[inputIndex - 1]
            .split(separator: ".")
            .compactMap { Int($0) }
    }

    /// Ensures the library is initialized, using platform-specific default
    /// paths when the caller has not provided explicit ones.
    ///
    /// - macOS (Homebrew): `/opt/homebrew/lib/mapnik/input`,
    ///   `/opt/homebrew/share/mapnik/fonts`
    /// - Linux: the discovered plugin directory (see ``defaultPluginPath``),
    ///   `/usr/share/fonts`
    static func ensureInitialized() throws {
        try initialize(plugins: defaultPluginPath, fonts: defaultFontPath)
    }

    /// Default plugin directory for the current platform.
    ///
    /// - macOS: `/opt/homebrew/lib/mapnik/input` (Homebrew installs all
    ///   mapnik versions there).
    /// - Linux: the input plugins' location differs per distribution and
    ///   mapnik generation (Debian/Ubuntu mapnik 3.1: `/usr/lib/mapnik/3.1/input`,
    ///   no multiarch; mapnik 4.x: `/usr/lib/<triplet>/mapnik/<version>/input`).
    ///   The path is discovered once, in this order:
    ///
    ///   1. `pkg-config libmapnik --variable=plugins_dir` — mapnik 4.x
    ///      packages ship `libmapnik.pc` exposing the plugin directory
    ///      (mapnik 3.1 packages do not, so this probe fails and the next
    ///      step applies).
    ///   2. The multiarch glob `/usr/lib/*/mapnik/*/input` — Debian's
    ///      mapnik 4.x layout; the highest version directory wins.
    ///   3. The legacy glob `/usr/lib/mapnik/*/input` — the mapnik 3.1
    ///      layout on Ubuntu LTS releases; the highest version wins.
    ///
    ///   Returns `nil` when no candidate exists (the callers already log
    ///   or surface initialization failures).
    public static var defaultPluginPath: String? {
        #if os(Linux)
        linuxPluginPath()
        #else
        "/opt/homebrew/lib/mapnik/input"
        #endif
    }

    /// Default font directory for the current platform.
    ///
    /// On Linux this is the system-wide font directory. On macOS the
    /// Homebrew font directory is preferred, but the Homebrew mapnik
    /// formula does not ship fonts, so the standard macOS font directories
    /// are used as fallbacks (first existing path wins):
    ///
    /// 1. `/opt/homebrew/share/mapnik/fonts`
    /// 2. `~/Library/Fonts`
    /// 3. `/Library/Fonts`
    /// 4. `/System/Library/Fonts`
    public static var defaultFontPath: String? {
        #if os(Linux)
        "/usr/share/fonts"
        #else
        let candidates = [
            "/opt/homebrew/share/mapnik/fonts",
            ("~" as NSString).expandingTildeInPath + "/Library/Fonts",
            "/Library/Fonts",
            "/System/Library/Fonts",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
        #endif
    }

    /// The font-face names mapnik has registered, in registration order.
    ///
    /// Font faces are registered by `initialize` (recursively scanning the
    /// font directory). Stylesheets reference them by these names, e.g.
    /// `face-name="DejaVu Sans Book"`; use this list to validate a
    /// stylesheet against the installed fonts, or to populate a face
    /// selector UI.
    ///
    /// Returns an empty list before `initialize` was called (or if no fonts
    /// were registered).
    public static func availableFonts() throws -> [String] {
        try ensureInitialized()

        var pointer: UnsafeMutablePointer<CChar>? = nil

        try CErrors.withError(MapnikError.initialization) { errorOut in
            if let fonts = mapnik_available_fonts(errorOut) {
                pointer = fonts
                return true
            }
            return false
        }

        guard let pointer else {
            throw MapnikError.initialization("font enumeration failed")
        }

        defer { mapnik_free_string(pointer) }

        return Self.parseNames(pointer)
    }

    /// Splits a NUL-separated name buffer into strings.
    private static func parseNames(_ pointer: UnsafeMutablePointer<CChar>) -> [String] {
        var names: [String] = []
        var offset = 0

        while true {
            let current = pointer + offset
            let length = strlen(current)
            if length == 0 {
                break
            }
            names.append(String(cString: current))
            offset += length + 1
        }

        return names
    }

}
