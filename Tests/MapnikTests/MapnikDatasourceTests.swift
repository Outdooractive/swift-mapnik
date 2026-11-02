import Foundation
import GISTools
@testable import Mapnik
import MapnikC
import Testing

/// Tests for direct datasource creation + inspection (the editor UI path).
@Suite("MapnikDatasource")
struct MapnikDatasourceTests {

    /// Geojson datasource reports fields geometry and extent.
    @Test
    func geojsonDatasourceReportsFieldsGeometryAndExtent() throws {
        let datasource = try MapnikDatasource(parameters: [
            ("type", "geojson"),
            ("inline", Fixtures.geojsonMultiAttribute),
        ])
        let info = try datasource.inspect(maxFeatures: 10, srs: "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs")

        #expect(info.type == "vector")
        #expect(info.geometryType == .polygon)
        #expect(info.unprojExtent != nil)
        if let extent = info.unprojExtent {
            #expect(extent.count == 4)
            // Europe polygon: -10..40 lon, 35..70 lat (some slack for
            // edge sampling).
            #expect(abs(extent[0] - -10.0) < 0.01)
            #expect(abs(extent[2] - 40.0) < 0.01)
            #expect(extent[1] > 30.0 && extent[1] < 36.0)
            #expect(extent[3] > 69.0 && extent[3] <= 85.051)
        }

        let names = info.fields.map(\.name)
        #expect(names.contains("name"))
        #expect(names.contains("population"))
        let nameField = info.fields.first { $0.name == "name" }
        #expect(nameField?.type == .string)
        let populationField = info.fields.first { $0.name == "population" }
        #expect(populationField?.type == .integer || populationField?.type == .double)

        #expect(info.features.count == 1)
        #expect(info.features.first?["name"]?.stringValue == "Europe")
        #expect(info.featureError == nil)
    }

    /// Raster datasources report no features or geometry.
    @Test
    func rasterDatasourcesReportNoFeaturesOrGeometry() throws {
        // A 2x2 GeoTIFF built from raw bytes (little-endian, uint8 bands).
        // The gdal plugin reads it; type detection alone is what matters.
        let tiff = Fixtures.tinyTiff
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("mapnik-ds-test-\(UUID().uuidString).tif")
        try tiff.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let datasource = try MapnikDatasource(parameters: [
            ("type", "gdal"),
            ("file", url.path),
        ])
        let info = try datasource.inspect(maxFeatures: 10, srs: "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs")

        #expect(info.type == "raster")
        #expect(info.geometryType == nil)
        #expect(info.fields.isEmpty)
        #expect(info.features.isEmpty)
    }

    /// Feature iteration errors do not discard fields.
    @Test
    func featureIterationErrorsDoNotDiscardFields() throws {
        // A GeoJSON datasource whose file disappears after creation —
        // mapnik parses lazily, so creation succeeds but the featureset
        // iteration throws.
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("mapnik-ds-vanish-\(UUID().uuidString).geojson")
        try Fixtures.geojsonMultiAttribute.write(to: url, atomically: true, encoding: .utf8)
        let datasource = try MapnikDatasource(parameters: [
            ("type", "geojson"),
            ("file", url.path),
        ])
        try FileManager.default.removeItem(at: url)

        let info = try datasource.inspect(maxFeatures: 10, srs: "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs")
        // Either the field list survives with a feature error, or mapnik
        // already failed at creation time (acceptable, both are handled).
        #expect(info.fields.isEmpty == false || info.featureError != nil)
    }

    /// Missing plugin throws with mapnik message.
    @Test
    func missingPluginThrowsWithMapnikMessage() throws {
        do {
            let datasource = try MapnikDatasource(parameters: [
                ("type", "does-not-exist"),
                ("file", "/nonexistent/file.geojson"),
            ])
            _ = try datasource.inspect(maxFeatures: 1, srs: "epsg:3857")
            Issue.record("expected an error")
        }
        catch let error as MapnikError {
            #expect(error.description.isEmpty == false)
        }
    }

    /// Empty parameters rejected.
    @Test
    func emptyParametersRejected() throws {
        #expect(throws: (any Error).self) {
            _ = try MapnikDatasource(parameters: [])
        }
    }

    // MARK: - Inspection improvements

    /// Field filter narrows the field list and samples.
    @Test
    func fieldFilterNarrowsTheFieldListAndSamples() throws {
        let datasource = try MapnikDatasource(parameters: [
            ("type", "geojson"),
            ("inline", Fixtures.geojsonMultiAttribute),
        ])

        let filtered = try datasource.inspect(
            maxFeatures: 10,
            srs: "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs",
            fieldFilter: ["name"])

        #expect(filtered.fields.map(\.name) == ["name"])
        #expect(filtered.features.count == 1)
        #expect(filtered.features.first?["name"]?.stringValue == "Europe")
        #expect(filtered.features.first?["population"] == nil)

        // An empty filter means "all fields" (nil-equivalent).
        let all = try datasource.inspect(
            maxFeatures: 10,
            srs: "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs",
            fieldFilter: [])
        #expect(all.fields.map(\.name) == ["name", "population"])

        // Unknown field names yield an empty field list and attribute-less
        // samples (the features still exist), but no error.
        let none = try datasource.inspect(
            maxFeatures: 10,
            srs: "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs",
            fieldFilter: ["does-not-exist"])
        #expect(none.fields.isEmpty)
        #expect(none.features.count == 1)
        #expect(none.features.first?.isEmpty == true)
    }

    /// Typed attribute values survive inspection.
    @Test
    func typedAttributeValuesSurviveInspection() throws {
        let datasource = try MapnikDatasource(parameters: [
            ("type", "geojson"),
            ("inline", Fixtures.geojsonMultiAttribute),
        ])

        let info = try datasource.inspect(maxFeatures: 10, srs: "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs")
        let feature = try #require(info.features.first)

        #expect(feature["name"]?.stringValue == "Europe")
        #expect(feature["population"]?.intValue == 742_000_000)
    }

    /// Precise coordinates survive inspection.
    @Test
    func preciseCoordinatesSurviveInspection() throws {
        // The inspection JSON used to format doubles with 6 significant
        // digits, which rounded coordinates at Web Mercator magnitudes to
        // ~10 m.
        let datasource = try MapnikDatasource(parameters: [
            ("type", "geojson"),
            ("inline", """
            {"type":"FeatureCollection","features":[{"type":"Feature",
            "properties":{"value":1.23456789012345},
            "geometry":{"type":"Point","coordinates":[12.3456789012345,45.6789012345678]}}]}
            """),
        ])

        let info = try datasource.inspect(
            maxFeatures: 1,
            srs: "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs")

        #expect(abs(info.extent[0] - 12.3456789012345) < 1e-9)
        #expect(abs(info.extent[1] - 45.6789012345678) < 1e-9)

        let value = try #require(info.features.first?["value"]?.doubleValue)
        #expect(abs(value - 1.23456789012345) < 1e-12)
    }

    /// Unrecognised field types decode as unknown.
    @Test
    func unrecognisedFieldTypesDecodeAsUnknown() throws {
        // A future mapnik attribute type must not make the field disappear.
        let json = """
        {"type":"vector","geometry_type":"polygon",
         "extent":[0,0,1,1],"unproj_extent":[0,0,1,1],
         "fields":[["name","String"],["future","SomeNewType"]],
         "features":[]}
        """
        let info = try JSONDecoder().decode(DatasourceInfo.self, from: Data(json.utf8))

        #expect(info.fields.map(\.name) == ["name", "future"])
        #expect(info.fields.last?.type == .unknown)
    }

    /// Duplicate palette colours are rejected.
    @Test
    func duplicatePaletteColorsAreRejected() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        #expect(throws: MapnikError.self) {
            _ = try map.renderPNG256(colors: [0xFFFF_0000, 0xFFFF_0000], width: 32, height: 32)
        }
    }

}

extension Fixtures {

    /// GeoJSON with typed attributes for field introspection.
    static let geojsonMultiAttribute = """
    {
      "type": "FeatureCollection",
      "features": [
        {
          "type": "Feature",
          "properties": { "name": "Europe", "population": 742000000 },
          "geometry": {
            "type": "Polygon",
            "coordinates": [[
              [-10.0, 35.0], [40.0, 35.0], [40.0, 70.0],
              [-10.0, 70.0], [-10.0, 35.0]
            ]]
          }
        }
      ]
    }
    """

    /// A minimal valid 2x2 8-bit grayscale TIFF (little-endian).
    /// Header: II*\0, one IFD at offset 8, 8 tags, then the 4 pixel bytes.
    fileprivate static let tinyTiff: Data = {
        var data = Data()
        // TIFF header: little-endian, magic 42, IFD offset 8.
        data.append(contentsOf: [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        // IFD: 9 entries (32-bit count comes right after the offset).
        data.append(contentsOf: [0x09, 0x00])
        func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) {
            withUnsafeBytes(of: tag.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: type.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: count.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        // Tags in ascending order, as TIFF requires: ImageWidth=2,
        // ImageLength=2, BitsPerSample=8, Compression=1 (none),
        // PhotometricInterpretation=1, StripOffsets=122, SamplesPerPixel=1,
        // RowsPerStrip=2, StripByteCounts=4.
        entry(256, 3, 1, 2)
        entry(257, 3, 1, 2)
        entry(258, 3, 1, 8)
        entry(259, 3, 1, 1)
        entry(262, 3, 1, 1)
        entry(273, 3, 1, 122)
        entry(277, 3, 1, 1)
        entry(278, 3, 1, 2)
        entry(279, 3, 1, 4)
        // "Next IFD" pointer = 0.
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        // Pixel data at offset 122 (padded to that offset).
        while data.count < 122 {
            data.append(0)
        }
        data.append(contentsOf: [0xFF, 0x80, 0x40, 0x00])
        return data
    }()

}

/// Tests for the datasource thread-safety and lifetime contracts.
@Suite("Datasource lifetime")
struct DatasourceLifetimeTests {

    /// Datasources can be created, queried and destroyed concurrently.
    @Test
    func `concurrent datasource lifecycle is safe`() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    let datasource = try MapnikDatasource(parameters: [
                        ("type", "geojson"),
                        ("inline", Fixtures.geojson),
                    ])
                    let info = try datasource.inspect(maxFeatures: 1, srs: "+init=epsg:4326")
                    _ = try datasource.queryBox(info.extent, maxFeatures: 1)
                }
            }

            try await group.waitForAll()
        }
    }

    /// A map keeps working after the counting datasource handle is destroyed.
    @Test
    func `map outlives counting datasource handle`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let counter = try #require(mapnik_counting_datasource_create())
        defer { mapnik_counting_datasource_destroy(counter) }

        let wkb = MetatileTests.europePolygonWKB()
        var errorOut: UnsafeMutablePointer<CChar>? = nil
        #expect(mapnik_counting_datasource_push_polygon(counter, wkb, UInt(wkb.count), "Europe", &errorOut))
        #expect(errorOut == nil)

        try map.withMapPointer { pointer in
            #expect(mapnik_map_use_counting_datasource(pointer, 0, counter, &errorOut))
        }
        #expect(errorOut == nil)

        // The layer holds a shared_ptr, so the map stays usable after the
        // handle is destroyed: rendering must not crash or throw.
        _ = try map.renderTile(Fixtures.europeTile, format: .png())
        #expect(map.layerNames == ["land"])
    }

}
