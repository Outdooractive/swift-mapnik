import MapnikC

/// Errors thrown by Mapnik operations.
///
/// Every case carries a human-readable message with diagnostics from the
/// underlying mapnik library, so failures are actionable without a debugger.
public enum MapnikError: Error, Sendable {

    /// Global library initialization failed (registering plugins or fonts).
    case initialization(String)

    /// A Mapnik XML stylesheet could not be loaded or parsed.
    case invalidStyle(String)

    /// Rendering failed, e.g. because a datasource is missing or an image
    /// type string is invalid.
    case renderingFailed(String)

    /// A parameter was out of range or otherwise invalid.
    case invalidInput(String)

}

extension MapnikError: CustomStringConvertible {

    public var description: String {
        switch self {
        case let .initialization(message):
            "Mapnik initialization failed: \(message)"
        case let .invalidStyle(message):
            "Loading style failed: \(message)"
        case let .renderingFailed(message):
            "Rendering failed: \(message)"
        case let .invalidInput(message):
            "Invalid input: \(message)"
        }
    }

}

/// Helpers for moving error strings across the C boundary.
enum CErrors {

    /// Calls `body` with a pointer to an initialized `char**` slot and turns
    /// a `false` return value into the given `MapnikError` case, carrying the
    /// message mapnik wrote into the slot.
    ///
    /// The closure may throw, e.g. to report a different `MapnikError` case
    /// after inspecting the message; a thrown error propagates unchanged and
    /// the slot is still freed.
    static func withError(
        _ error: (String) -> MapnikError,
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Bool,
    ) throws {
        var slot: UnsafeMutablePointer<CChar>? = nil
        var capturedMessage: String? = nil

        let ok = try withUnsafeMutablePointer(to: &slot) { slotPointer -> Bool in
            defer {
                // Capture and free whatever the C layer wrote, in any outcome.
                if let pointer = slotPointer.pointee {
                    capturedMessage = String(cString: pointer)
                    mapnik_free_string(pointer)
                    slotPointer.pointee = nil
                }
            }
            return try body(slotPointer)
        }

        guard ok else {
            throw error(capturedMessage ?? "unknown error")
        }
    }

}
