import Foundation
@testable import Mapnik
import Testing

/// Tests for direct datasource creation + inspection (the editor UI path).
@Suite("MapnikDatasource")
struct MapnikDatasourceTests {

    @Test
    func `geojson datasource reports fields geometry and extent`() throws {
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

    @Test
    func `raster datasources report no features or geometry`() throws {
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

    @Test
    func `feature iteration errors do not discard fields`() throws {
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

    @Test
    func `missing plugin throws with mapnik message`() throws {
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

    @Test
    func `empty parameters rejected`() {
        #expect(throws: (any Error).self) {
            _ = try MapnikDatasource(parameters: [])
        }
    }

    // MARK: - Inspection improvements

    @Test
    func `field filter narrows the field list and samples`() throws {
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

    @Test
    func `typed attribute values survive inspection`() throws {
        let datasource = try MapnikDatasource(parameters: [
            ("type", "geojson"),
            ("inline", Fixtures.geojsonMultiAttribute),
        ])

        let info = try datasource.inspect(maxFeatures: 10, srs: "+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs")
        let feature = try #require(info.features.first)

        #expect(feature["name"]?.stringValue == "Europe")
        #expect(feature["population"]?.intValue == 742_000_000)
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
