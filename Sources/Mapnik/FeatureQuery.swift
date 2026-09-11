import Foundation
import GISTools
import MapnikC

/// A feature returned by a feature query: identifier, geometry and
/// attributes.
///
/// Produced by ``Mapnik/queryPoint(layerIndex:at:maxFeatures:)`` and
/// ``MapnikDatasource/queryBox(_:maxFeatures:)``.
public struct QueriedFeature: Sendable {

    /// The feature's mapnik id.
    public let id: Int

    /// The feature's geometry, decoded from mapnik's WKB into a GISTools
    /// GeoJSON geometry. Coordinates stay in the queried coordinate space
    /// (the map SRS for point queries, the datasource SRS for box queries) —
    /// call `projected(to:)` on the geometry to reproject if needed.
    ///
    /// `nil` for features without a geometry (attributes-only hits).
    public let geometry: GeoJsonGeometry?

    /// The feature's attributes, as mapnik formatted them (all values are
    /// strings, matching the datasource inspection schema).
    public let properties: [String: String]

}

// MARK: - JSON parsing

enum FeatureQueryParser {

    /// Parses the shim's `{"features":[...]}` document into GISTools
    /// `Feature` values.
    ///
    /// Geometry-less features (attributes-only hits, e.g. raster datasources)
    /// are dropped: GISTools `Feature` requires a geometry.
    static func parseFeatures(json: Data) throws -> [Feature] {
        guard let document = try JSONSerialization.jsonObject(with: json, options: []) as? [String: Any],
              let rawFeatures = document["features"] as? [[String: Any]]
        else {
            throw MapnikError.renderingFailed("could not parse the feature query result")
        }

        var features: [Feature] = []
        features.reserveCapacity(rawFeatures.count)

        for raw in rawFeatures {
            guard let id = raw["id"] as? Int else {
                continue
            }

            let properties: [String: Sendable] = (raw["properties"] as? [String: Any])?
                .compactMapValues { value -> Sendable? in
                    switch value {
                    case is NSNull:
                        return nil

                    case let string as String:
                        return string

                    case let number as NSNumber:
                        // JSON booleans arrive as NSNumber (objCType "c");
                        // keep them bool, then integer when exact.
                        if number.objCType[0] == Int8(99) { // "c" = boolean
                            return number.boolValue
                        }
                        let doubleValue = number.doubleValue
                        if doubleValue.rounded() == doubleValue, doubleValue >= Double(Int.min), doubleValue <= Double(Int.max) {
                            return Int(doubleValue)
                        }
                        return doubleValue

                    default:
                        return nil
                    }
                }
                ?? [:]

            guard let wkbHex = raw["wkb"] as? String else {
                // Attributes-only hit: GISTools Feature requires a geometry.
                continue
            }

            do {
                let geometry = try WKBCoder.decode(
                    wkb: Data(hexEncoded: wkbHex) ?? Data(),
                    sourceProjection: .noSRID,
                    targetProjection: .noSRID)
                features.append(Feature(
                    geometry,
                    id: .int(id),
                    properties: properties,
                    calculateBoundingBox: true))
            }
            catch {
                // A broken geometry must not drop the feature; skip it with
                // a note (the attribute values are unavailable without a
                // geometry in GISTools' model).
                continue
            }
        }

        return features
    }

}

extension Data {

    /// Decodes a lowercase hex string (as produced by the C shim) into bytes.
    init?(hexEncoded hex: String) {
        let characters = Array(hex.utf8)
        guard characters.count % 2 == 0 else {
            return nil
        }

        self.init(capacity: characters.count / 2)
        var byte: UInt8 = 0
        for (index, character) in characters.enumerated() {
            let value: UInt8
            switch character {
            case 0x30 ... 0x39: value = character - 0x30
            case 0x61 ... 0x66: value = character - 0x61 + 10
            case 0x41 ... 0x46: value = character - 0x41 + 10
            default: return nil
            }

            if index % 2 == 0 {
                byte = value << 4
            }
            else {
                append(byte | value)
            }
        }
    }

}

// MARK: - Map point queries

extension Mapnik {

    /// Queries the features of the layer at `layerIndex` intersecting a
    /// geographic coordinate (WGS 84 degrees).
    ///
    /// The coordinate is reprojected to the map's SRS; the layer is queried
    /// the way a render at the current view would (visibility and scale
    /// rules apply). Returned geometry is in the map SRS.
    ///
    /// - Parameters:
    ///   - coordinate: The location to query (WGS 84 degrees).
    ///   - layerIndex: The layer to query, in render order, 0-based.
    ///   - maxFeatures: Maximum number of features to return.
    /// - Returns: The features intersecting the coordinate (attributes plus
    ///   geometry in the map SRS).
    /// - Throws: `MapnikError.invalidInput` for out-of-range input,
    ///   `MapnikError.renderingFailed` when the query fails.
    public func queryPoint(
        at coordinate: Coordinate3D,
        layerIndex: Int,
        maxFeatures: Int = 100,
    ) throws -> [Feature] {
        guard maxFeatures > 0 else {
            throw MapnikError.invalidInput("maxFeatures must be positive, got \(maxFeatures)")
        }
        guard layerIndex >= 0, layerIndex < layerNames.count else {
            throw MapnikError.invalidInput("layer index \(layerIndex) out of range for \(layerNames.count) layers")
        }

        var x: Double = 0
        var y: Double = 0
        try withMapPointer { pointer in
            try CErrors.withError(MapnikError.renderingFailed) { errorOut in
                mapnik_map_project_from_wgs84(
                    pointer,
                    coordinate.longitude,
                    coordinate.latitude,
                    &x,
                    &y,
                    errorOut)
            }
        }

        return try queryPoint(
            x: x,
            y: y,
            layerIndex: layerIndex,
            maxFeatures: maxFeatures)
    }

    /// Queries the features of the layer at `layerIndex` intersecting the
    /// point (`x`, `y`) in the map's SRS.
    ///
    /// - Parameters:
    ///   - x: The x coordinate in the map's SRS.
    ///   - y: The y coordinate in the map's SRS.
    ///   - layerIndex: The layer to query, in render order, 0-based.
    ///   - maxFeatures: Maximum number of features to return.
    /// - Returns: The features intersecting the point (attributes plus
    ///   geometry in the map SRS).
    public func queryPoint(
        x: Double,
        y: Double,
        layerIndex: Int,
        maxFeatures: Int = 100,
    ) throws -> [Feature] {
        guard maxFeatures > 0 else {
            throw MapnikError.invalidInput("maxFeatures must be positive, got \(maxFeatures)")
        }
        guard layerIndex >= 0, layerIndex < layerNames.count else {
            throw MapnikError.invalidInput("layer index \(layerIndex) out of range for \(layerNames.count) layers")
        }

        // A fresh map has no usable extent; mapnik's query_point requires one.
        zoomAllIfUnset()

        var jsonSlot: UnsafeMutablePointer<CChar>? = nil
        do {
            try withMapPointer { pointer in
                try CErrors.withError(MapnikError.renderingFailed) { errorOut in
                    mapnik_map_query_point(
                        pointer,
                        Int32(clamping: layerIndex),
                        x,
                        y,
                        Int32(clamping: maxFeatures),
                        &jsonSlot,
                        errorOut)
                }
            }
        }
        catch let error as MapnikError {
            // mapnik's query_point throws when the point is outside the
            // map's extent; an empty result is the friendlier answer.
            guard case let .renderingFailed(message) = error,
                  message.contains("do not intersect map extent")
            else {
                throw error
            }

            return []
        }
        defer {
            if let pointer = jsonSlot {
                mapnik_free_string(pointer)
            }
        }

        guard let jsonPointer = jsonSlot else {
            throw MapnikError.renderingFailed("feature query produced no output")
        }

        let json = Data(bytes: jsonPointer, count: strlen(jsonPointer))
        return try FeatureQueryParser.parseFeatures(json: json)
    }

}

// MARK: - Datasource box queries

extension MapnikDatasource {

    /// Queries the features of the datasource intersecting a bounding box in
    /// the datasource's native SRS (the same SRS `inspect(maxFeatures:srs:)`
    /// reports its `extent` in).
    ///
    /// - Parameters:
    ///   - box: The query box, in the datasource's native SRS. Pass the
    ///     `extent` values from `inspect` for a full scan.
    ///   - maxFeatures: Maximum number of features to return.
    /// - Returns: The features intersecting the box (attributes plus
    ///   geometry in the datasource SRS).
    public func queryBox(_ box: [Double], maxFeatures: Int = 100) throws -> [Feature] {
        guard box.count == 4 else {
            throw MapnikError.invalidInput("box must contain exactly 4 values [minx, miny, maxx, maxy], got \(box.count)")
        }
        guard box[0] <= box[2], box[1] <= box[3] else {
            throw MapnikError.invalidInput("query box must have min <= max, got [\(box[0]), \(box[1]), \(box[2]), \(box[3])]")
        }
        guard maxFeatures > 0 else {
            throw MapnikError.invalidInput("maxFeatures must be positive, got \(maxFeatures)")
        }

        var jsonSlot: UnsafeMutablePointer<CChar>? = nil
        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_datasource_query_box(
                datasource,
                box[0],
                box[1],
                box[2],
                box[3],
                Int32(clamping: maxFeatures),
                &jsonSlot,
                errorOut)
        }
        defer {
            if let pointer = jsonSlot {
                mapnik_free_string(pointer)
            }
        }

        guard let jsonPointer = jsonSlot else {
            throw MapnikError.renderingFailed("feature query produced no output")
        }

        let json = Data(bytes: jsonPointer, count: strlen(jsonPointer))
        return try FeatureQueryParser.parseFeatures(json: json)
    }

}
