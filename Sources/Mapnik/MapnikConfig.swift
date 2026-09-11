import Foundation
import MapnikC

/// Global, one-time initialization of the mapnik library.
///
/// Before any `Mapnik` instance can render, mapnik needs to know where to find
/// its datasource input plugins (PostGIS, GeoJSON, Shapefile, ...) and its
/// fonts. This is a process-wide operation: call `initialize` once, or rely on
/// the platform defaults applied by the lazy `ensureInitialized` path used by
/// `Mapnik(xml:...)`.
public enum MapnikConfig {

    private final class State: @unchecked Sendable {

        let lock = NSLock()
        var result: Result<Void, MapnikError>?

    }

    private static let state = State()

    /// Registers datasource plugins and fonts from the given directories.
    ///
    /// Both paths are scanned recursively. Passing `nil` or an empty string
    /// skips registration for that resource, e.g. when no fonts are needed.
    ///
    /// It is safe (and cheap) to call this multiple times; only the first call
    /// has an effect. A failed attempt is cached and re-thrown on subsequent
    /// calls.
    ///
    /// - Throws: `MapnikError.initialization` if plugin or font registration failed.
    public static func initialize(
        plugins inputPluginsPath: String? = nil,
        fonts fontsPath: String? = nil,
    ) throws {
        state.lock.lock()
        defer { state.lock.unlock() }

        if let result = state.result {
            switch result {
            case .success:
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
        }
        catch let error as MapnikError {
            state.result = .failure(error)
            throw error
        }
        catch {
            let mapnikError = MapnikError.initialization("\(error)")
            state.result = .failure(mapnikError)
            throw mapnikError
        }
    }

    /// Ensures the library is initialized, using platform-specific default
    /// paths when the caller has not provided explicit ones.
    ///
    /// - macOS (Homebrew): `/opt/homebrew/lib/mapnik/input`,
    ///   `/opt/homebrew/share/mapnik/fonts`
    /// - Linux (Debian/Ubuntu): `/usr/lib/mapnik/3.1/input`,
    ///   `/usr/share/fonts`
    static func ensureInitialized() throws {
        try initialize(plugins: defaultPluginPath, fonts: defaultFontPath)
    }

    /// Default plugin directory for the current platform.
    public static var defaultPluginPath: String? {
        #if os(Linux)
        return "/usr/lib/mapnik/3.1/input"
        #else
        return "/opt/homebrew/lib/mapnik/input"
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
        return "/usr/share/fonts"
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
