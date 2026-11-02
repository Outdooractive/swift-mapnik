import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Tests for `TilelistBuilder`'s tilelist JSON schema.
@Suite("Tilelist builder")
struct TilelistBuilderTests {

    /// An empty builder produces an empty tilelist.
    @Test
    func emptyBuilderProducesEmptyTilelist() {
        let builder = TilelistBuilder()

        #expect(builder.tileCount == 0)
        #expect(builder.tilelist.all.isEmpty)
    }

    /// Contiguous tiles collapse into a single range.
    @Test
    func contiguousTilesCollapseIntoOneRange() {
        let builder = TilelistBuilder()
        builder.add((5722 ... 5730).map { MapTile(x: $0, y: 8656, z: 14) })

        let all = builder.tilelist.all
        #expect(all["14"]?["8656"] == [[5722, 5730]])
    }

    /// Gaps produce separate ranges.
    @Test
    func gapsProduceSeparateRanges() {
        let builder = TilelistBuilder()
        builder.add([MapTile(x: 1, y: 2, z: 3), MapTile(x: 2, y: 2, z: 3)])
        builder.add([MapTile(x: 5, y: 2, z: 3)])

        #expect(builder.tilelist.all["3"]?["2"] == [[1, 2], [5, 5]])
    }

    /// A single tile produces a one-element range.
    @Test
    func singleTileProducesSingleRange() {
        let builder = TilelistBuilder()
        builder.add(MapTile(x: 7, y: 9, z: 10))

        #expect(builder.tilelist.all == ["10": ["9": [[7, 7]]]])
    }

    /// Tiles are grouped by zoom level and row.
    @Test
    func tilesAreGroupedByZoomAndRow() {
        let builder = TilelistBuilder()
        builder.add(MapTile(x: 1, y: 1, z: 1))
        builder.add(MapTile(x: 1, y: 2, z: 1))
        builder.add(MapTile(x: 1, y: 1, z: 2))

        let all = builder.tilelist.all
        #expect(all.keys.sorted() == ["1", "2"])
        #expect(all["1"]?.keys.sorted() == ["1", "2"])
        #expect(all["2"]?["1"] == [[1, 1]])
    }

    /// Duplicate tiles collapse to one range.
    @Test
    func duplicateTilesCollapse() {
        let builder = TilelistBuilder()
        builder.add(MapTile(x: 1, y: 2, z: 3))
        builder.add(MapTile(x: 1, y: 2, z: 3))
        builder.add(MapTile(x: 2, y: 2, z: 3))

        #expect(builder.tilelist.all["3"]?["2"] == [[1, 2]])
    }

    /// The tilelist encodes to the documented JSON shape.
    @Test
    func tilelistEncodesToDocumentedShape() throws {
        let builder = TilelistBuilder()
        builder.add((5722 ... 5730).map { MapTile(x: $0, y: 8656, z: 14) })

        // `Tilelist` already carries the top-level "all" key.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(builder.tilelist)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json == #"{"all":{"14":{"8656":[[5722,5730]]}}}"#)
    }

    /// The tilelist round-trips through Codable.
    @Test
    func tilelistRoundTripsThroughCodable() throws {
        let builder = TilelistBuilder()
        builder.add([MapTile(x: 1, y: 2, z: 3), MapTile(x: 4, y: 5, z: 6)])

        let data = try JSONEncoder().encode(builder.tilelist)
        let decoded = try JSONDecoder().decode(TilelistBuilder.Tilelist.self, from: data)

        #expect(decoded == builder.tilelist)
    }

    /// Concurrent adds are safe and lossless.
    @Test
    func concurrentAddsAreSafe() async {
        let builder = TilelistBuilder()

        await withTaskGroup(of: Void.self) { group in
            for zoom in 0 ..< 8 {
                group.addTask {
                    for x in 0 ..< 32 {
                        builder.add(MapTile(x: x, y: zoom, z: zoom))
                    }
                }
            }
        }

        #expect(builder.tileCount == 8 * 32)
        #expect(builder.tilelist.all.count == 8)
    }

}
