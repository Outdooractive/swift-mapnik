import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Tests for Mapnik XML serialization (`saveXML`).
@Suite("Save XML")
struct SaveXMLTests {

    @Test
    func `saveXML produces a loadable Mapnik document`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let xml = try map.saveXML()

        #expect(xml.contains("<Map"))
        #expect(xml.contains("</Map>"))
        #expect(xml.contains("DTK") == false) // sanity: this is the polygon style

        // The output loads again and renders identically.
        let reloaded = try Mapnik(xml: xml)
        let original = try map.renderTile(Fixtures.europeTile, options: RenderOptions(width: 256, height: 256, format: .png()))
        let roundTrip = try reloaded.renderTile(Fixtures.europeTile, options: RenderOptions(width: 256, height: 256, format: .png()))

        #expect(original != nil)
        #expect(roundTrip != nil)
        #expect(original?.count == roundTrip?.count)
    }

    @Test
    func `saveXML round trips runtime modifications`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        // Runtime modifications: SRS and buffer. (Layer visibility does not
        // round-trip: mapnik's serializer omits inactive layers entirely.)
        try map.setSRS("epsg:4326")
        map.setBufferSize(64)

        let xml = try map.saveXML(explicitDefaults: true)

        let reloaded = try Mapnik(xml: xml)
        #expect(reloaded.srs == "epsg:4326")
        #expect(reloaded.bufferSize == 64)
        #expect(reloaded.layerVisible(0) == true)
    }

    @Test
    func `saveXML omits hidden layers like mapnik`() throws {
        let map = try Mapnik(xml: Fixtures.multiLayerStyle)
        map.setLayerVisible(0, visible: false)

        let xml = try map.saveXML()

        let reloaded = try Mapnik(xml: xml)
        #expect(reloaded.layerNames == ["layer-two"])
    }

    @Test
    func `saveXML writes to a file`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let url = FileManager.default
            .temporaryDirectory
            .appending(path: "swift-mapnik-savexml-\(UUID().uuidString).xml")

        try map.saveXML(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("<Map"))

        // The file loads and renders.
        let reloaded = try Mapnik(xmlFile: url)
        let data = try reloaded.renderTile(Fixtures.europeTile, format: .png())
        #expect(data != nil)
    }

    @Test
    func `saveXML explicit defaults carries more attributes`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        let plain = try map.saveXML()
        let explicit = try map.saveXML(explicitDefaults: true)

        // The explicit form is at least as long, and both are loadable.
        #expect(explicit.count >= plain.count)
        let reloaded = try Mapnik(xml: explicit)
        let data = try reloaded.renderTile(Fixtures.europeTile, format: .png())
        #expect(data != nil)
    }

}
