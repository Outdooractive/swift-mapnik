import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Tests for the remaining API gaps: tilelist counting, vector page size.
@Suite("API gaps")
struct APIGapTests {

    /// tileCount counts unique tiles, matching the tilelist.
    @Test
    func `tile count counts unique tiles`() {
        let builder = TilelistBuilder()
        builder.add(MapTile(x: 1, y: 2, z: 3))
        builder.add(MapTile(x: 1, y: 2, z: 3))
        builder.add(MapTile(x: 2, y: 2, z: 3))

        #expect(builder.tileCount == 2)
        #expect(builder.tilelist.all["3"]?["2"] == [[1, 2]])
    }

    /// Vector renders honour a requested page size.
    @Test
    func `vector renders honour page size`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        let svg = try map.renderSVG(width: 400, height: 300)
        let text = String(decoding: svg, as: UTF8.self)
        #expect(text.contains("width=\"400\""))
        #expect(text.contains("height=\"300\""))

        // The map size is restored afterwards.
        #expect(map.size == (width: 256, height: 256))
    }

    /// Vector renders without an explicit size use the map's current size.
    @Test
    func `vector renders default to map size`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let svg = try map.renderSVG()
        let text = String(decoding: svg, as: UTF8.self)
        #expect(text.contains("width=\"256\""))
    }

    /// ImageFormat's mapnik type string is observable.
    @Test
    func `image format exposes type string`() {
        #expect(ImageFormat.png().typeString == "png")
        #expect(ImageFormat.png(colors: 64).typeString == "png:c=64")
        #expect(ImageFormat.png256.typeString == "png256")
        #expect(ImageFormat.jpeg(quality: 85).typeString == "jpeg:quality=85")
        #expect(ImageFormat.webp(quality: 80, alphaQuality: 90).typeString == "webp:quality=80:alpha_quality=90")
        #expect(ImageFormat.webp(lossless: true).typeString == "webp:lossless=1")
        #expect(ImageFormat.tiff.typeString == "tiff")
        #expect(ImageFormat.svg.typeString == "svg")
    }

}
