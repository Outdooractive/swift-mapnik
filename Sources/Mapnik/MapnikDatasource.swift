import Foundation
import GISTools
import MapnikC

/// Field type reported by datasource inspection.
public enum DatasourceFieldType: String, Sendable, Codable, CaseIterable {

    case integer = "Integer"
    case float = "Float"
    case double = "Double"
    case string = "String"
    case boolean = "Boolean"
    case geometry = "Geometry"
    case object = "Object"
    case unknown = "Unknown"

}

/// Geometry type reported by datasource inspection.
public enum DatasourceGeometryType: String, Sendable, Codable {

    case point
    case lineString = "linestring"
    case polygon
    case collection
    case unknown

}

/// A datasource field: name plus its reported type.
public struct DatasourceField: Sendable, Equatable {

    public var name: String
    public var type: DatasourceFieldType

    public init(name: String, type: DatasourceFieldType) {
        self.name = name
        self.type = type
    }

}

/// The result of inspecting a mapnik datasource.
///
/// Produced by ``MapnikDatasource/inspect(maxFeatures:srs:)``; mirrors what
/// TileMill's datasource inspection returned to the layer editor: the
/// datasource type, geometry type, extents (native + geographic), the field
/// list and a small sample of features.
public struct DatasourceInfo: Sendable {

    /// "vector" or "raster".
    public var type: String

    /// The geometry type, `nil` for raster datasources.
    public var geometryType: DatasourceGeometryType?

    /// The datasource's native extent (in the layer SRS).
    public var extent: [Double]

    /// The geographic extent (lon/lat), clamped to ±180/±85.051. `nil` when
    /// the SRS could not be transformed.
    public var unprojExtent: [Double]?

    /// Field names and their types, in datasource order.
    public var fields: [DatasourceField]

    /// Feature samples with typed attribute values (null, bool, integer,
    /// double or string — as mapnik stored them). Up to the requested
    /// `maxFeatures`. Geometry samples are available through
    /// ``queryBox(_:maxFeatures:)``.
    public var features: [[String: JSONValue]]

    /// Mapnik's error message when feature iteration failed; the field list
    /// remains valid in that case.
    public var featureError: String?

}

extension DatasourceInfo: Decodable {

    enum CodingKeys: String, CodingKey {

        case type
        case geometryType = "geometry_type"
        case extent
        case unprojExtent = "unproj_extent"
        case fields
        case features
        case featureError = "feature_error"

    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.geometryType = try container.decodeIfPresent(DatasourceGeometryType.self, forKey: .geometryType)
        self.extent = try container.decode([Double].self, forKey: .extent)
        self.unprojExtent = try container.decodeIfPresent([Double].self, forKey: .unprojExtent)

        let rawFields = try container.decode([[String]].self, forKey: .fields)
        self.fields = rawFields.compactMap { pair in
            guard pair.count == 2, let type = DatasourceFieldType(rawValue: pair[1]) else {
                return nil
            }

            return DatasourceField(name: pair[0], type: type)
        }

        self.features = try container.decodeIfPresent([[String: JSONValue]].self, forKey: .features) ?? []
        self.featureError = try container.decodeIfPresent(String.self, forKey: .featureError)
    }

}

/// A mapnik datasource created directly from parameters — the same
/// name/value pairs a Mapnik XML `<Datasource>` block (or a CartoCSS
/// project's layer `Datasource` object) carries.
///
/// Used for datasource inspection in editor UIs: create from a layer's
/// parameters, then call ``inspect(maxFeatures:srs:)``. Nothing here renders.
public final class MapnikDatasource: @unchecked Sendable {

    let datasource: OpaquePointer

    /// Creates a datasource from name/value parameters.
    ///
    /// - Parameters:
    ///   - parameters: Ordered name/value pairs; `type` selects the input
    ///     plugin (postgis, shape, geojson, gdal, ...), which must have been
    ///     registered via `MapnikConfig.initialize` first.
    /// - Throws: `MapnikError.invalidInput` if the parameters are empty or
    ///   malformed, `MapnikError.renderingFailed` when mapnik cannot build
    ///   the datasource (missing plugin, bad connection, unreadable file...).
    public init(parameters: [(String, String)]) throws {
        try MapnikConfig.ensureInitialized()

        guard parameters.isEmpty == false else {
            throw MapnikError.invalidInput("datasource parameters are empty")
        }

        var keys: [UnsafePointer<CChar>?] = []
        var values: [UnsafePointer<CChar>?] = []
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        keys.reserveCapacity(parameters.count)
        values.reserveCapacity(parameters.count)
        cStrings.reserveCapacity(parameters.count * 2)
        for (key, value) in parameters {
            let keyPointer = strdup(key)
            let valuePointer = strdup(value)
            if let keyPointer, let valuePointer {
                cStrings.append(keyPointer)
                cStrings.append(valuePointer)
                keys.append(UnsafePointer(keyPointer))
                values.append(UnsafePointer(valuePointer))
            }
            else {
                free(keyPointer)
                free(valuePointer)
                cStrings.forEach { free($0) }
                throw MapnikError.invalidInput("out of memory while copying datasource parameters")
            }
        }
        defer { cStrings.forEach { free($0) } }

        var slot: UnsafeMutablePointer<CChar>? = nil
        var message: String? = nil
        let handle = withUnsafeMutablePointer(to: &slot) { slotPointer -> OpaquePointer? in
            defer {
                if let pointer = slotPointer.pointee {
                    message = String(cString: pointer)
                    mapnik_free_string(pointer)
                }
            }
            return keys.withUnsafeBufferPointer { keysBuffer in
                values.withUnsafeBufferPointer { valuesBuffer in
                    // The C API expects `const char* const*`; the Swift
                    // arrays are `[UnsafePointer<CChar>?]`, contiguous and
                    // NUL-free by construction.
                    let keysPointer = UnsafeRawPointer(keysBuffer.baseAddress!)
                        .assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                    let valuesPointer = UnsafeRawPointer(valuesBuffer.baseAddress!)
                        .assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                    return mapnik_datasource_create(
                        keysPointer,
                        valuesPointer,
                        Int32(clamping: parameters.count),
                        slotPointer)
                }
            }
        }

        guard let handle else {
            throw MapnikError.renderingFailed(message ?? "could not create datasource")
        }

        self.datasource = handle
    }

    deinit {
        mapnik_datasource_destroy(datasource)
    }

    // MARK: - Inspection

    /// Inspects the datasource: type, geometry type, extents, field list and
    /// feature samples.
    ///
    /// - Parameters:
    ///   - maxFeatures: Number of feature samples to collect (0 to skip).
    ///   - srs: The layer SRS the datasource's data is expressed in; the
    ///     geographic extent is computed by transforming the native extent
    ///     from this SRS to WGS84. Pass the layer's `srs` field.
    ///   - fieldFilter: Optional set of attribute names to report and
    ///     sample; `nil` reports every field. Useful to trim wide tables
    ///     down to the attributes the editor shows. Geometry samples are
    ///     available through ``queryBox(_:maxFeatures:)``.
    /// - Returns: The parsed ``DatasourceInfo``.
    /// - Throws: `MapnikError.renderingFailed` when mapnik fails to open or
    ///   describe the datasource.
    public func inspect(
        maxFeatures: Int = 50,
        srs: String,
        fieldFilter: Set<String>? = nil,
    ) throws -> DatasourceInfo {
        guard maxFeatures >= 0 else {
            throw MapnikError.invalidInput("maxFeatures must not be negative")
        }

        var slot: UnsafeMutablePointer<CChar>? = nil
        var message: String? = nil

        // The field filter crosses as a parallel NUL-terminated array, the
        // same shape mapnik_datasource_create uses.
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        var fieldNames: [UnsafePointer<CChar>?] = []
        if let fieldFilter, fieldFilter.isEmpty == false {
            for name in fieldFilter.sorted() {
                if let pointer = strdup(name) {
                    cStrings.append(pointer)
                    fieldNames.append(UnsafePointer(pointer))
                }
            }
        }
        defer { cStrings.forEach { free($0) } }

        let json: Data? = withUnsafeMutablePointer(to: &slot) { slotPointer -> Data? in
            defer {
                if let pointer = slotPointer.pointee {
                    message = String(cString: pointer)
                    mapnik_free_string(pointer)
                }
            }
            let pointer: UnsafeMutablePointer<CChar>? = fieldNames.withUnsafeBufferPointer { buffer in
                mapnik_datasource_inspect(
                    datasource,
                    srs,
                    Int32(clamping: maxFeatures),
                    buffer.baseAddress,
                    Int32(clamping: fieldNames.count),
                    slotPointer)
            }
            guard let pointer else {
                return nil
            }

            // The C string is owned by this call; copy before freeing.
            defer { mapnik_free_string(pointer) }
            let length = strlen(pointer)
            return Data(bytes: pointer, count: length)
        }

        guard let json else {
            throw MapnikError.renderingFailed(message ?? "could not inspect datasource")
        }

        do {
            return try JSONDecoder().decode(DatasourceInfo.self, from: json)
        }
        catch {
            throw MapnikError.renderingFailed("could not parse the inspection result: \(error)")
        }
    }

    /// Lists the sub-layers of an OGR datasource.
    ///
    /// OGR datasources that bundle several layers fail to open without an
    /// explicit `layer` parameter; mapnik's error message carries the list of
    /// available layer names. This call parses them out.
    ///
    /// - Returns: The layer names, or `nil` when the datasource has no
    ///   sub-layers (or is not an OGR source at all).
    /// - Throws: `MapnikError.renderingFailed` when mapnik fails for a
    ///   different reason (e.g. an unreadable file).
    public func ogrLayerNames() throws -> [String]? {
        var slots = [UnsafePointer<CChar>?](repeating: nil, count: 64)
        var slot: UnsafeMutablePointer<CChar>? = nil
        var message: String? = nil
        var count: Int32 = 0

        let ok = withUnsafeMutablePointer(to: &slot) { slotPointer -> Bool in
            defer {
                if let pointer = slotPointer.pointee {
                    message = String(cString: pointer)
                    mapnik_free_string(pointer)
                }
            }
            let result = slots.withUnsafeMutableBufferPointer { buffer -> Int32 in
                mapnik_datasource_ogr_layers(
                    datasource,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    slotPointer)
            }
            if result >= 0 {
                count = result
                return true
            }
            return false
        }

        if ok {
            return slots.prefix(Int(count)).compactMap { $0.map { String(cString: $0) } }
        }

        // "No sub-layers" is the normal negative outcome; anything else is
        // a real failure.
        if message == "datasource has no sub-layers" {
            return nil
        }
        throw MapnikError.renderingFailed(message ?? "could not enumerate the datasource layers")
    }

}
