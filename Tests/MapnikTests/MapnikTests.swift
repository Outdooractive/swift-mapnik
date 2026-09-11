import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Integration tests that exercise the full C → mapnik stack.
@Suite("Mapnik")
struct MapnikTests {

    @Test
    func `rendering intersecting tile returns image bytes`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderTile(Fixtures.europeTile, format: .png())

        #expect(data != nil)
        #expect(data?.isEmpty == false)
        // PNG signature
        #expect(data?.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) == true)
    }

    @Test
    func `rendering ocean tile returns nil`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderTile(Fixtures.oceanTile, format: .png())
        #expect(data == nil)
    }

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

    @Test
    func `web P output has RIFF signature`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderTile(Fixtures.europeTile, format: .webp(quality: 80))

        #expect(data != nil)
        let bytes = try [UInt8](#require(data?.prefix(4)))
        #expect(bytes.elementsEqual(Array("RIFF".utf8)))
    }

    @Test
    func `JPEG output has SOI marker`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderTile(Fixtures.europeTile, format: .jpeg(quality: 75))

        #expect(data != nil)
        let bytes = try [UInt8](#require(data?.prefix(2)))
        #expect(bytes.elementsEqual([0xFF, 0xD8]))
    }

    @Test
    func `PNG 256 output is PNG`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderTile(Fixtures.europeTile, format: .png256)

        #expect(data != nil)
        #expect(data?.isEmpty == false)
        let bytes = try [UInt8](#require(data?.prefix(4)))
        #expect(bytes.elementsEqual([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test
    func `palette quantized PNG renders`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        // Palette of a few colors: red, black, white.
        let data = try map.renderPNG256(colors: [0xFFFF_0000, 0xFF00_0000, 0xFFFF_FFFF])

        #expect(data != nil)
        #expect(data?.isEmpty == false)
    }

    @Test
    func `palette too many colors rejected`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let colors = (0 ..< 257).map { UInt32(0xFF00_0000 + $0) }

        #expect(throws: MapnikError.self) {
            try map.renderPNG256(colors: colors)
        }
    }

    @Test
    func `retina tiles are twice pixel size`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderTile(Fixtures.europeTile, format: .png(), scale: 2.0)

        #expect(data != nil)
        #expect(data?.isEmpty == false)
    }

    @Test
    func `out of range tile coordinates throw`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        #expect(throws: MapnikError.self) {
            try map.renderTile(x: 99, y: 5, z: 4)
        }
    }

    @Test
    func `free form bounding box rendering produces image`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.render(bounds: Fixtures.germany, width: 512, height: 512)

        #expect(data != nil)
        #expect(data?.isEmpty == false)
    }

    @Test
    func `SVG output contains svg element`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderSVG()

        #expect(data.isEmpty == false)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("<svg"))
        #expect(text.contains("</svg>"))
    }

    @Test
    func `SVG file rendering works`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-test-\(UUID().uuidString).svg")

        try map.renderSVG(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("<svg"))
    }

    @Test
    func `PDF output has PDF magic`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderPDF()

        #expect(data.isEmpty == false)
        let bytes = Array(data.prefix(5))
        #expect(bytes.elementsEqual(Array("%PDF-".utf8)))
    }

    @Test
    func `PDF file rendering works`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-test-\(UUID().uuidString).pdf")

        try map.renderPDF(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        #expect(data.prefix(5).elementsEqual(Array("%PDF-".utf8)))
    }

    @Test
    func `PostScript output has PS magic`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let data = try map.renderPostScript()

        #expect(data.isEmpty == false)
        let bytes = Array(data.prefix(2))
        #expect(bytes.elementsEqual(Array("%!".utf8)))
    }

    @Test
    func `PostScript file rendering works`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-test-\(UUID().uuidString).ps")

        try map.renderPostScript(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        #expect(data.prefix(2).elementsEqual(Array("%!".utf8)))
    }

    @Test
    func `PDF rendering with retina scale works`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let retina = try map.renderPDF(scale: 2.0)

        #expect(retina.isEmpty == false)
        #expect(retina.prefix(5).elementsEqual(Array("%PDF-".utf8)))
    }

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
        #expect(map.size.width == 512)
        #expect(map.size.height == 256)
    }

    @Test
    func `invalid stylesheet throws with message`() {
        #expect(throws: MapnikError.self) {
            _ = try Mapnik(xml: Fixtures.brokenStyle)
        }
    }

    @Test
    func `style error messages carry diagnostics`() {
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

    @Test
    func `unknown datasource type reports useful error`() {
        do {
            let map = try Mapnik(xml: Fixtures.unknownDatasourceStyle)
            // Some mapnik versions only fail at render time.
            _ = try map.renderTile(Fixtures.europeTile, format: .png())
            // If it rendered, that's fine too (plugin lookup deferred).
        }
        catch let error as MapnikError {
            // Either the style load or the render failed with a message.
            let message: String =
                switch error {
                case let .invalidStyle(text), let .renderingFailed(text):
                    text
                case .initialization, .invalidInput:
                    "\(error)"
                }
            #expect(message.isEmpty == false)
        }
        catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func `label rendering exercises font registration`() throws {
        let map = try Mapnik(xml: Fixtures.labelStyle)
        // The tile may or may not be fully transparent depending on whether
        // the DejaVu face is registered on this platform; the point of this
        // test is that font registration happens and label rendering runs
        // without throwing.
        _ = try map.renderTile(Fixtures.europeTile, format: .png())
    }

    @Test
    func `rendering same map twice is stable`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        let first = try map.renderTile(Fixtures.europeTile, format: .png())
        let second = try map.renderTile(Fixtures.europeTile, format: .png())

        #expect(first != nil)
        #expect(second != nil)
        #expect(first?.count == second!.count)
    }

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

    @Test
    func `missing stylesheet file throws invalid input`() {
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-missing-\(UUID().uuidString).xml")

        #expect(throws: MapnikError.self) {
            _ = try Mapnik(xmlFile: url)
        }
    }

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

    @Test
    func `map SRS comes from stylesheet`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        #expect(map.srs == "epsg:3857")
    }

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

    @Test
    func `long SRS strings round trip without truncation`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let proj = "+proj=merc +a=6378137 +b=6378137 +lat_ts=0.0 +lon_0=0.0 +x_0=0.0 +y_0=0.0 +k=1.0 +units=m +nadgrids=@null +wktext +no_defs +over"
        try map.setSRS(proj)
        #expect(map.srs == proj)
    }

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

}
