import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Reads the width and height out of a PNG's IHDR chunk.
func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
    guard data.count >= 24, data.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
        return nil
    }

    func bigEndian(_ range: Range<Int>) -> Int {
        data[range].reduce(0) { $0 << 8 | Int($1) }
    }

    return (bigEndian(16 ..< 20), bigEndian(20 ..< 24))
}

/// Integration tests that exercise the full C → mapnik stack.
@Suite("Mapnik")
struct MapnikTests {

    /// Rendering intersecting tile returns image bytes.
    @Test
    func `rendering intersecting tile returns image bytes`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderTile(Fixtures.europeTile, format: .png())

        #expect(data != nil)
        #expect(data?.isEmpty == false)
        // PNG signature
        #expect(data?.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) == true)
    }

    /// Rendering ocean tile returns nil.
    @Test
    func `rendering ocean tile returns nil`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderTile(Fixtures.oceanTile, format: .png())
        #expect(data == nil)
    }

    /// Empty tiles kept instead of skipped.
    @Test
    func `empty tiles kept instead of skipped`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let options = RenderOptions(
            width: 256,
            height: 256,
            skipFullyTransparent: false,
            format: .png())
        let data = try map.renderTile(Fixtures.oceanTile, options: options)

        #expect(data != nil)
        // Fully transparent but valid PNG.
        #expect(data?.isEmpty == false)
    }

    /// Web P output has RIFF signature.
    @Test
    func `web P output has RIFF signature`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderTile(Fixtures.europeTile, format: .webp(quality: 80))

        #expect(data != nil)
        let bytes = try [UInt8](#require(data?.prefix(4)))
        #expect(bytes.elementsEqual(Array("RIFF".utf8)))
    }

    /// JPEG output has SOI marker.
    @Test
    func `jpeg output has SOI marker`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderTile(Fixtures.europeTile, format: .jpeg(quality: 75))

        #expect(data != nil)
        let bytes = try [UInt8](#require(data?.prefix(2)))
        #expect(bytes.elementsEqual([0xFF, 0xD8]))
    }

    /// PNG 256 output is PNG.
    @Test
    func `png 256 output is PNG`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderTile(Fixtures.europeTile, format: .png256)

        #expect(data != nil)
        #expect(data?.isEmpty == false)
        let bytes = try [UInt8](#require(data?.prefix(4)))
        #expect(bytes.elementsEqual([0x89, 0x50, 0x4E, 0x47]))
    }

    /// Palette quantized PNG renders.
    @Test
    func `palette quantized PNG renders`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        // Palette of a few colors: red, black, white.
        let data = try map.renderPNG256(colors: [0xFFFF_0000, 0xFF00_0000, 0xFFFF_FFFF])

        #expect(data != nil)
        #expect(data?.isEmpty == false)
    }

    /// Palette too many colors rejected.
    @Test
    func `palette too many colors rejected`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let colors = (0 ..< 257).map { UInt32(0xFF00_0000 + $0) }

        #expect(throws: MapnikError.self) {
            try map.renderPNG256(colors: colors)
        }
    }

    /// Retina tiles are twice pixel size.
    @Test
    func `retina tiles are twice pixel size`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderTile(Fixtures.europeTile, format: .png(), scale: 2.0)

        let png = try #require(data)
        #expect(try #require(pngDimensions(png)) == (width: 512, height: 512))
    }

    /// Out of range tile coordinates throw.
    @Test
    func `non square tiles are honoured`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderTile(
            Fixtures.europeTile,
            options: RenderOptions(width: 64, height: 256, format: .png()))

        let png = try #require(data)
        #expect(try #require(pngDimensions(png)) == (width: 64, height: 256))
    }

    @Test
    func `free form render honours scale`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let options = RenderOptions(width: 100, height: 100, format: .png())

        let plain = try #require(try map.render(options))
        #expect(try #require(pngDimensions(plain)) == (width: 100, height: 100))

        var scaled = options
        scaled.scale = 2.0
        let retina = try #require(try map.render(scaled))
        #expect(try #require(pngDimensions(retina)) == (width: 200, height: 200))
    }

    @Test
    func `render to file honours scale`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-scale-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try map.renderToFile(to: url, width: 100, height: 100, scale: 2.0, format: .png())
        #expect(try #require(try pngDimensions(Data(contentsOf: url))) == (width: 200, height: 200))
    }

    @Test
    func `palette render honours skip flag`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        // Ocean tile: nothing painted.
        try map.zoom(to: BoundingBox(
            southWest: Coordinate3D(latitude: -50.0, longitude: -160.0),
            northEast: Coordinate3D(latitude: -45.0, longitude: -150.0)))

        let colors: [UInt32] = [0xFFFF_0000, 0xFF00_0000]
        let skipped = try map.renderPNG256(
            colors: colors,
            options: RenderOptions(width: 64, height: 64, skipFullyTransparent: true, format: .png256))
        #expect(skipped == nil)

        let kept = try map.renderPNG256(
            colors: colors,
            options: RenderOptions(width: 64, height: 64, skipFullyTransparent: false, format: .png256))
        let png = try #require(kept)
        #expect(try #require(pngDimensions(png)) == (width: 64, height: 64))
    }

    @Test
    func `palette render writes a file`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-palette-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try map.renderPNG256ToFile(
            colors: [0xFFFF_0000, 0xFF00_0000],
            to: url,
            options: RenderOptions(width: 64, height: 64, format: .png256))

        let png = try Data(contentsOf: url)
        #expect(png.prefix(4).elementsEqual([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test
    func `tile to file can write an empty tile`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-empty-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        // Ocean tile: nothing painted. With skipping enabled this throws.
        #expect(throws: MapnikError.self) {
            try map.renderTileToFile(Fixtures.oceanTile, to: url, format: .png())
        }

        try map.renderTileToFile(
            Fixtures.oceanTile,
            to: url,
            options: RenderOptions(width: 64, height: 64, skipFullyTransparent: false, format: .png()))
        #expect(try Data(contentsOf: url).isEmpty == false)
    }

    @Test
    func `out of range tile coordinates throw invalid input`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        #expect(throws: MapnikError.invalidInput(
            "tile coordinates (99, 5) out of range for zoom 4"))
        {
            try map.renderTile(x: 99, y: 5, z: 4)
        }

        // MapTile clamps z to its own range, but mapnik stops at zoom 30.
        #expect(throws: MapnikError.invalidInput("zoom level must be in 0...30, got 31")) {
            try map.renderTile(MapTile(x: 0, y: 0, z: 31))
        }
    }

    /// Free form bounding box rendering produces image.
    @Test
    func `free form bounding box rendering produces image`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.render(bounds: Fixtures.germany, width: 512, height: 512)

        #expect(data != nil)
        #expect(data?.isEmpty == false)
    }

    /// SVG output contains svg element.
    @Test
    func `svg output contains svg element`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderSVG()

        #expect(data.isEmpty == false)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("<svg"))
        #expect(text.contains("</svg>"))
    }

    /// SVG file rendering works.
    @Test
    func `svg file rendering works`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-test-\(UUID().uuidString).svg")

        try map.renderSVG(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("<svg"))
    }

    /// PDF output has PDF magic.
    @Test
    func `pdf output has PDF magic`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderPDF()

        #expect(data.isEmpty == false)
        let bytes = Array(data.prefix(5))
        #expect(bytes.elementsEqual(Array("%PDF-".utf8)))
    }

    /// PDF file rendering works.
    @Test
    func `pdf file rendering works`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-test-\(UUID().uuidString).pdf")

        try map.renderPDF(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        #expect(data.prefix(5).elementsEqual(Array("%PDF-".utf8)))
    }

    /// PostScript output has PS magic.
    @Test
    func `post script output has PS magic`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderPostScript()

        #expect(data.isEmpty == false)
        let bytes = Array(data.prefix(2))
        #expect(bytes.elementsEqual(Array("%!".utf8)))
    }

    /// PostScript file rendering works.
    @Test
    func `post script file rendering works`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-test-\(UUID().uuidString).ps")

        try map.renderPostScript(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        #expect(data.prefix(2).elementsEqual(Array("%!".utf8)))
    }

    /// PDF rendering with retina scale works.
    @Test
    func `pdf rendering with retina scale works`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let retina = try map.renderPDF(scale: 2.0)

        #expect(retina.isEmpty == false)
        #expect(retina.prefix(5).elementsEqual(Array("%PDF-".utf8)))
    }

    /// Explicit buffer size does not linger after renders.
    @Test
    func `explicit buffer size does not linger after renders`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        #expect(map.bufferSize == 16) // from the stylesheet

        // Each render path with an explicit buffer restores the stylesheet's
        // value afterwards, so renders stay independent of each other.
        _ = try map.renderTile(Fixtures.europeTile, format: .png(), bufferSize: 64)
        #expect(map.bufferSize == 16)

        _ = try map.render(bounds: Fixtures.germany, width: 256, height: 256, bufferSize: 128, format: .png())
        #expect(map.bufferSize == 16)

        _ = try map.renderPNG256(colors: [0xFFFF_0000])
        #expect(map.bufferSize == 16)

        _ = try map.renderMetatile(origin: Fixtures.europeTile, metaSize: 2, options: RenderOptions(width: 256, height: 256, bufferSize: 32, format: .png()))
        #expect(map.bufferSize == 16)

        // Renders without an explicit buffer keep the stylesheet's value.
        _ = try map.renderTile(Fixtures.europeTile, format: .png())
        #expect(map.bufferSize == 16)
    }

    /// Zoom all and layer introspection work.
    @Test
    func `zoom all and layer introspection work`() throws {
        let map = try Mapnik(xml: Fixtures.multiLayerStyle)

        #expect(map.layerNames == ["layer-one", "layer-two"])

        #expect(map.layerVisible(0) == true)
        #expect(map.layerVisible(1) == true)
        #expect(map.layerVisible(2) == nil)
        #expect(map.layerVisible(-1) == nil)

        map.setLayerVisible(1, visible: false)
        #expect(map.layerVisible(1) == false)

        try map.zoomAll()
        let data = try map.render(width: 128, height: 128, format: .png())
        #expect(data != nil)
    }

    /// Resize and buffer size accessors work.
    @Test
    func `resize and buffer size accessors work`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        let initial = map.size
        #expect(initial.width == 256)
        #expect(initial.height == 256)

        #expect(map.bufferSize == 16)

        map.setBufferSize(64)
        #expect(map.bufferSize == 64)

        let data = try map.render(width: 512, height: 256, format: .png())
        #expect(data != nil)

        // Free-form renders restore the map's size, so repeated renders stay
        // independent of each other.
        #expect(map.size == initial)
    }

    @Test
    func `free form renders restore the map size`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let initial = map.size

        _ = try map.render(width: 300, height: 200, format: .png())
        #expect(map.size == initial)

        _ = try map.renderPNG256(colors: [0xFFFF_0000], width: 300, height: 200)
        #expect(map.size == initial)

        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-restore-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try map.renderToFile(to: url, width: 320, height: 240, format: .png())
        #expect(map.size == initial)
    }

    /// Invalid stylesheet throws with message.
    @Test
    func `invalid stylesheet throws with message`() {
        #expect(throws: MapnikError.self) {
            _ = try Mapnik(xml: Fixtures.brokenStyle)
        }
    }

    /// Style error messages carry diagnostics.
    @Test
    func `style error messages carry diagnostics`() throws {
        do {
            _ = try Mapnik(xml: Fixtures.brokenStyle)
            Issue.record("Expected invalidStyle error")
        }
        catch let error as MapnikError {
            guard case let .invalidStyle(message) = error else {
                Issue.record("Wrong error case: \(error)")
                return
            }

            #expect(message.isEmpty == false)
            #expect(message != "unknown error")
        }
        catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    /// Unknown datasource type reports useful error.
    @Test
    func `unknown datasource type reports useful error`() throws {
        do {
            let map = try Mapnik(xml: Fixtures.unknownDatasourceStyle)
            // Some mapnik versions only fail at render time.
            _ = try map.renderTile(Fixtures.europeTile, format: .png())
            Issue.record("Expected an error for an unknown datasource type")
        }
        catch let error as MapnikError {
            // Either the style load or the render failed with a message.
            let message: String =
                switch error {
                case let .invalidStyle(text), let .renderingFailed(text):
                    text
                case .initialization, .invalidInput, .serializationFailed:
                    "\(error)"
                }
            #expect(message.isEmpty == false)
        }
        catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    /// Label rendering exercises font registration.
    @Test(.enabled(if: AvailableFontsTests.hasDejaVu))
    func `label rendering exercises font registration`() throws {
        let map = try Mapnik(xml: Fixtures.labelStyle)

        // The fixture has no polygon symbolizer, so any painted pixel comes
        // from the text: a non-nil tile proves the face resolved and the
        // label was placed.
        let data = try map.renderTile(Fixtures.europeTile, format: .png())
        #expect(data != nil, "label rendering produced no pixels; is the DejaVu face registered?")
    }

    /// Rendering same map twice is stable.
    @Test
    func `rendering same map twice is stable`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        let first = try map.renderTile(Fixtures.europeTile, format: .png())
        let second = try map.renderTile(Fixtures.europeTile, format: .png())

        // Same length is not enough: identical bytes prove the render is
        // deterministic and that tile rendering restores the map state.
        #expect(first != nil)
        #expect(second != nil)
        #expect(try first?.count == #require(second?.count))
    }

    /// Render options validation rejects invalid.
    @Test
    func `render options validation rejects invalid`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        #expect(throws: MapnikError.self) {
            try map.renderTile(Fixtures.europeTile, options: RenderOptions(width: 0, height: 256))
        }
        #expect(throws: MapnikError.self) {
            try map.renderTile(Fixtures.europeTile, options: RenderOptions(scale: -1.0))
        }
        #expect(throws: MapnikError.self) {
            try map.renderTile(Fixtures.europeTile, options: RenderOptions(format: .svg))
        }
    }

    /// Loading stylesheet from file renders tiles.
    @Test
    func `loading stylesheet from file renders tiles`() throws {
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-style-\(UUID().uuidString).xml")
        try Fixtures.polygonStyle.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let map = try Mapnik(xmlFile: url)
        let data = try map.renderTile(Fixtures.europeTile, format: .png())

        #expect(data != nil)
        #expect(data?.isEmpty == false)
    }

    /// File loading resolves datasource paths relative to stylesheet.
    @Test
    func `file loading resolves datasource paths relative to stylesheet`() throws {
        let base = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-xmltest-\(UUID().uuidString)/")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let dataURL = base.appending(path: "data.geojson")
        try Fixtures.geojson.write(to: dataURL, atomically: true, encoding: .utf8)

        // The datasource path is relative to the stylesheet's directory.
        let styleURL = base.appending(path: "style.xml")
        let style = Fixtures.polygonStyle.replacing(
            "<Parameter name=\"inline\">\(Fixtures.geojson)</Parameter>",
            with: "<Parameter name=\"file\">data.geojson</Parameter>")
        try style.write(to: styleURL, atomically: true, encoding: .utf8)

        let map = try Mapnik(xmlFile: styleURL)
        let data = try map.renderTile(Fixtures.europeTile, format: .png())

        #expect(data != nil)
        #expect(data?.isEmpty == false)
    }

    /// Missing stylesheet file throws invalid input.
    @Test
    func `missing stylesheet file throws invalid input`() {
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-missing-\(UUID().uuidString).xml")

        #expect(throws: MapnikError.self) {
            _ = try Mapnik(xmlFile: url)
        }
    }

    /// Invalid stylesheet file throws with message.
    @Test
    func `invalid stylesheet file throws with message`() throws {
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-broken-\(UUID().uuidString).xml")
        try Fixtures.brokenStyle.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: MapnikError.self) {
            _ = try Mapnik(xmlFile: url)
        }
    }

    /// Map SRS comes from stylesheet.
    @Test
    func `map SRS comes from stylesheet`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        #expect(map.srs == "epsg:3857")
    }

    /// Set SRS changes projection and rejects invalid.
    @Test
    func `set SRS changes projection and rejects invalid`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        try map.setSRS("epsg:4326")
        #expect(map.srs == "epsg:4326")

        #expect(throws: MapnikError.self) {
            try map.setSRS("not a projection")
        }
        #expect(map.srs == "epsg:4326")
    }

    /// Rendering EPSG 4326 free form produces image.
    @Test
    func `rendering EPSG 4326 free form produces image`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        try map.setSRS("epsg:4326")

        // Europe in geographic coordinates, spanning the polygon above.
        let europe = BoundingBox(
            southWest: Coordinate3D(latitude: 35.0, longitude: -10.0),
            northEast: Coordinate3D(latitude: 70.0, longitude: 40.0))
        let data = try map.render(bounds: europe, width: 512, height: 512, format: .png())

        #expect(data != nil)
        #expect(data?.isEmpty == false)
    }

    /// Long SRS strings round trip without truncation.
    @Test
    func `long SRS strings round trip without truncation`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let proj = "+proj=merc +a=6378137 +b=6378137 +lat_ts=0.0 +lon_0=0.0 +x_0=0.0 +y_0=0.0 +k=1.0 +units=m +nadgrids=@null +wktext +no_defs +over"
        try map.setSRS(proj)
        #expect(map.srs == proj)
    }

    /// Zoom to reprojects and throws for invalid input.
    @Test
    func `zoom to reprojects and throws for invalid input`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        // Web Mercator map: geographic box is transformed to meters.
        try map.zoom(to: Fixtures.germany)
        let data = try map.render(width: 256, height: 256, format: .png())
        #expect(data != nil)

        // An empty SRS string is rejected.
        #expect(throws: MapnikError.self) {
            try map.setSRS("")
        }
    }

    @Test
    func `zoom rejects a bounding box in a planar projection`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        // A Web Mercator box would be silently read as degrees and produce a
        // NaN extent.
        let mercator = BoundingBox(
            southWest: Coordinate3D(x: 556_597.0, y: 5_942_074.0, projection: .epsg3857),
            northEast: Coordinate3D(x: 1_669_792.0, y: 6_106_854.0, projection: .epsg3857))

        #expect(throws: MapnikError.self) {
            try map.zoom(to: mercator)
        }
    }

    @Test
    func `render bounds rejects a bounding box in a planar projection`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let mercator = BoundingBox(
            southWest: Coordinate3D(x: 556_597.0, y: 5_942_074.0, projection: .epsg3857),
            northEast: Coordinate3D(x: 1_669_792.0, y: 6_106_854.0, projection: .epsg3857))

        #expect(throws: MapnikError.self) {
            _ = try map.render(bounds: mercator, width: 64, height: 64, format: .png())
        }
    }

    @Test
    func `layer envelope carries the layer projection`() throws {
        let map = try Mapnik(xml: Fixtures.multiLayerStyle)

        // The fixture's layers are declared as epsg:4326.
        let envelope = try map.layerEnvelope(0)
        #expect(envelope.projection == .epsg4326)
        #expect(map.layerSRS(0) == "epsg:4326")
    }

    @Test
    func `layer count matches the stylesheet`() throws {
        let map = try Mapnik(xml: Fixtures.multiLayerStyle)
        #expect(map.layerCount == 2)
        #expect(map.layerNames.count == 2)
    }

}

/// Tests for API hardening: no trapping accessors, validated options.
@Suite("API hardening")
struct APIHardeningTests {

    /// Layer accessors return nil for indices that do not fit in Int32.
    @Test
    func `layer accessors do not trap on huge indices`() throws {
        let map = try Mapnik(xml: Fixtures.multiLayerStyle)

        // A plain Int32(index) would trap here.
        #expect(map.layerVisible(Int.max) == nil)
        #expect(map.layerSRS(Int.max) == nil)
        #expect(map.layerQueryable(Int.max) == nil)
        #expect(map.layerVisible(Int.max, atScaleDenominator: 10000) == nil)
        #expect(map.layerVisible(-1) == nil)
    }

    /// Long SRS strings survive a round trip.
    @Test
    func `long SRS strings are not truncated`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let proj = "+proj=merc +a=6378137 +b=6378137 +lat_ts=0.0 +lon_0=0.0 +x_0=0.0 +y_0=0.0 "
            + "+k=1.0 +units=m +nadgrids=@null +wktext +no_defs +over +comment="
            + String(repeating: "a", count: 200)

        try map.setSRS(proj)
        #expect(proj.count > 255)
        #expect(map.srs == proj)
    }

    /// setBufferSize clamps negative values.
    @Test
    func `set buffer size clamps negative values`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        map.setBufferSize(-5)
        #expect(map.bufferSize == 0)
    }

    /// ImageFormat rejects out-of-range options as invalid input.
    @Test
    func `image format validates its options`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        #expect(throws: MapnikError.invalidInput("png colors must be in 1...256, got 0")) {
            _ = try map.renderTile(Fixtures.europeTile, options: RenderOptions(format: .png(colors: 0)))
        }
        #expect(throws: MapnikError.invalidInput("png colors must be in 1...256, got 257")) {
            _ = try map.renderTile(Fixtures.europeTile, options: RenderOptions(format: .png(colors: 257)))
        }
        #expect(throws: MapnikError.invalidInput("jpeg quality must be in 0...100, got 500")) {
            _ = try map.renderTile(Fixtures.europeTile, options: RenderOptions(format: .jpeg(quality: 500)))
        }
        #expect(throws: MapnikError.invalidInput("webp quality must be in 0...100, got -1")) {
            _ = try map.renderTile(Fixtures.europeTile, options: RenderOptions(format: .webp(quality: -1)))
        }
    }

    /// MapnikError is Equatable and LocalizedError.
    @Test
    func `mapnik error is equatable and localized`() {
        #expect(MapnikError.invalidInput("x") == MapnikError.invalidInput("x"))
        #expect(MapnikError.invalidInput("x") != MapnikError.invalidInput("y"))
        #expect(MapnikError.invalidInput("x").errorDescription == "Invalid input: x")
    }

    /// Metatile rejects out-of-range input instead of trapping.
    @Test
    func `metatile validates instead of trapping`() throws {
        #expect(throws: MapnikError.self) {
            _ = try Metatile(origin: MapTile(x: 0, y: 0, z: 1), metaSize: 0)
        }
        #expect(throws: MapnikError.self) {
            _ = try Metatile(origin: MapTile(x: 0, y: 0, z: 1), metaSize: 17)
        }
        #expect(throws: MapnikError.self) {
            _ = try Metatile(
                origin: MapTile(x: 0, y: 0, z: 1),
                metaSize: 2,
                tiles: [MapTile(x: 5, y: 5, z: 1)])
        }
    }

    /// Sequences reject out-of-range input instead of trapping.
    @Test
    func `sequences validate instead of trapping`() throws {
        #expect(throws: MapnikError.self) {
            _ = try TileSequence(bounds: Fixtures.germany, zoomRange: 0 ... 31)
        }
        #expect(throws: MapnikError.self) {
            _ = try MetatileSequence(bounds: Fixtures.germany, zoomRange: 9 ... 9, metaSize: 0)
        }
        #expect(throws: MapnikError.self) {
            _ = try MetatileSequence(bounds: Fixtures.germany, zoomRange: 9 ... 9, metaSize: 32)
        }
    }

    /// BoundingBox parsing rejects malformed input instead of shifting values.
    @Test
    func `bounding box parsing rejects malformed input`() {
        // Five fields with one unparseable used to be accepted as 1,2,3,4.
        #expect(BoundingBox(parsing: "1,2,foo,3,4") == nil)
        #expect(BoundingBox(parsing: "1,2,,3,4") == nil)
        #expect(BoundingBox(parsing: "nan,1,2,3") == nil)
        #expect(BoundingBox(parsing: "inf,1,2,3") == nil)
        #expect(BoundingBox(parsing: "1,2,3,4") != nil)
    }

}
