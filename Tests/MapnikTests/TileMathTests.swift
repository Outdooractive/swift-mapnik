import Foundation
import GISTools
@testable import Mapnik
import Testing

@Suite("Tile math")
struct TileMathTests {

    // These tests exercise GISTools' MapTile(coordinate:atZoom:) (fixed in
    // gis-tools 2.3.2 to wrap longitudes, floor instead of truncate, and
    // clamp at the poles) together with swift-mapnik's TileSequence, which
    // builds tile ranges on top of it.

    /// Well known tile coordinates.
    @Test
    func wellKnownTileCoordinates() {
        // Berlin, Brandenburger Tor (52.5163 N, 13.3777 E) at zoom 10 is
        // tile (550, 335) in the XYZ scheme.
        let berlin = Coordinate3D(latitude: 52.5163, longitude: 13.3777)
        let tile = MapTile(coordinate: berlin, atZoom: 10)
        #expect(tile.x == 550)
        #expect(tile.y == 335)
        #expect(tile.z == 10)
    }

    /// Zoom zero covers world in one tile.
    @Test
    func zoomZeroCoversWorldInOneTile() {
        let anywhere = Coordinate3D(latitude: 12.3, longitude: -45.6)
        let tile = MapTile(coordinate: anywhere, atZoom: 0)
        #expect(tile.x == 0)
        #expect(tile.y == 0)
    }

    /// Western longitudes produce correct tiles.
    @Test
    func westernLongitudesProduceCorrectTiles() {
        // New York (40.7128 N, -74.0060 E) at zoom 6 is tile (18, 24).
        let newYork = Coordinate3D(latitude: 40.7128, longitude: -74.0060)
        let tile = MapTile(coordinate: newYork, atZoom: 6)
        #expect(tile.x == 18)
        #expect(tile.y == 24)
    }

    /// Longitudes just west of prime meridian round down.
    @Test
    func longitudesJustWestOfPrimeMeridianRoundDown() {
        // -0.04 degrees at zoom 12 is inside tile 2047; truncation towards
        // zero would produce the same tile as +0.04 degrees (2048), which
        // is wrong.
        let justWest = Coordinate3D(latitude: 0.0, longitude: -0.04)
        let west = MapTile(coordinate: justWest, atZoom: 12)
        let east = MapTile(coordinate: Coordinate3D(latitude: 0.0, longitude: 0.04), atZoom: 12)
        #expect(west.x == 2047)
        #expect(east.x == 2048)
    }

    /// Longitudes beyond dateline wrap into range.
    @Test
    func longitudesBeyondDatelineWrapIntoRange() {
        // 185 degrees is east of the dateline and wraps to -175 degrees,
        // which is the first tile of the row.
        let overDateline = Coordinate3D(latitude: 0.0, longitude: 185.0)
        let tile = MapTile(coordinate: overDateline, atZoom: 4)
        #expect(tile.x == 0)
    }

    /// Poles clamped to mercator limit.
    @Test
    func polesClampedToMercatorLimit() {
        let northPole = MapTile(coordinate: Coordinate3D(latitude: 90.0, longitude: 0.0), atZoom: 4)
        #expect(northPole.y == 0)

        let southPole = MapTile(coordinate: Coordinate3D(latitude: -90.0, longitude: 0.0), atZoom: 4)
        #expect(southPole.y == 15)
    }

    /// Coordinates in other projections reprojected.
    @Test
    func coordinatesInOtherProjectionsReprojected() {
        // Berlin in Web Mercator.
        let berlinMercator = Coordinate3D(x: 1_489_196.0, y: 6_899_390.0, projection: .epsg3857)
        let tile = MapTile(coordinate: berlinMercator, atZoom: 10)
        #expect(tile.x == 550)
        #expect(tile.y == 335)
    }

    /// Bounding box string parsing accepts valid input.
    @Test
    func boundingBoxStringParsingAcceptsValidInput() {
        let box = BoundingBox(parsing: "5.9, 47.2, 15.0, 55.0")
        #expect(box != nil)
        #expect(box?.southWest.longitude == 5.9)
        #expect(box?.southWest.latitude == 47.2)
        #expect(box?.northEast.longitude == 15.0)
        #expect(box?.northEast.latitude == 55.0)
        #expect(box?.projection == .epsg4326)
    }

    /// Bounding box string parsing rejects invalid input.
    @Test
    func boundingBoxStringParsingRejectsInvalidInput() {
        #expect(BoundingBox(parsing: "") == nil)
        #expect(BoundingBox(parsing: "1,2,3") == nil)
        #expect(BoundingBox(parsing: "a,b,c,d") == nil)
        // min >= max is invalid.
        #expect(BoundingBox(parsing: "15,47,5,55") == nil)
        #expect(BoundingBox(parsing: "5,55,15,47") == nil)
    }

}

@Suite("TileSequence")
struct TileSequenceTests {

    let bounds = BoundingBox(
        southWest: Coordinate3D(latitude: 47.2, longitude: 10.2),
        northEast: Coordinate3D(latitude: 47.6, longitude: 10.6))

    /// Single zoom produces exactly B box tiles.
    @Test
    func singleZoomProducesExactlyBBoxTiles() {
        // A small bbox at low zoom: 10.2..10.6 E, 47.2..47.6 N spans 2 tiles
        // per axis at zoom 9.
        let sequence = TileSequence(bounds: bounds, zoomRange: 9 ... 9)
        let tiles = Array(sequence)

        #expect(sequence.count == 4)
        #expect(tiles.count == 4)
        #expect(tiles.allSatisfy({ $0.z == 9 }))

        // Row-major order: x increasing within a row, y constant per row.
        let ys = tiles.map(\.y)
        #expect(ys == [tiles[0].y, tiles[0].y, tiles[2].y, tiles[2].y])
        #expect(tiles[0].x < tiles[1].x)
        #expect(tiles[2].x < tiles[3].x)
    }

    /// Multiple zoom levels descend by default.
    @Test
    func multipleZoomLevelsDescendByDefault() {
        let sequence = TileSequence(bounds: bounds, zoomRange: 12 ... 13)
        let tiles = Array(sequence)

        #expect(tiles.count == sequence.count)
        // First tiles come from zoom 13 (descending).
        #expect(tiles.first?.z == 13)
        // Last tiles come from zoom 12.
        #expect(tiles.last?.z == 12)
    }

    /// Ascending order visits zoom levels reverse.
    @Test
    func ascendingOrderVisitsZoomLevelsReverse() {
        let sequence = TileSequence(bounds: bounds, zoomRange: 12 ... 13, zoomOrder: .ascending)
        let tiles = Array(sequence)

        #expect(tiles.first?.z == 12)
        #expect(tiles.last?.z == 13)
    }

    /// Count matches iterated tile count across zooms.
    @Test
    func countMatchesIteratedTileCountAcrossZooms() {
        for zoomRange in [10 ... 10, 10 ... 12, 0 ... 4, 14 ... 16] {
            let sequence = TileSequence(bounds: bounds, zoomRange: zoomRange)
            #expect(sequence.count == Array(sequence).count)
        }
    }

    /// Worldwide zoom iterates tiles.
    @Test
    func worldwideZoomIteratesTiles() {
        let sequence = TileSequence(bounds: .world, zoomRange: 0 ... 2)
        #expect(sequence.count == 21)
    }

    /// Tile generator hands out same tiles exactly once.
    @Test
    func tileGeneratorHandsOutSameTilesExactlyOnce() {
        let sequence = TileSequence(bounds: bounds, zoomRange: 13 ... 14)
        let generator = TileGenerator(sequence)

        var fromGenerator: Set<MapTile> = []
        while let tile = generator.next() {
            #expect(fromGenerator.insert(tile).inserted, "duplicate tile \(tile)")
        }
        #expect(fromGenerator.count == sequence.count)
    }

    /// Iterator returns nil after exhaustion.
    @Test
    func iteratorReturnsNilAfterExhaustion() {
        var iterator = TileSequence(bounds: bounds, zoomRange: 9 ... 9).makeIterator()
        for _ in 0 ..< 4 {
            #expect(iterator.next() != nil)
        }
        #expect(iterator.next() == nil)
        #expect(iterator.next() == nil)
    }

    /// Tiles at any zoom within valid bounds.
    @Test
    func tilesAtAnyZoomWithinValidBounds() {
        let sequence = TileSequence(bounds: bounds, zoomRange: 0 ... 8)
        for tile in sequence {
            #expect(tile.x >= 0)
            #expect(tile.y >= 0)
            #expect(tile.x < (1 << tile.z))
            #expect(tile.y < (1 << tile.z))
        }
    }

    /// Antimeridian crossing bounds produce two ranges.
    @Test
    func antimeridianCrossingBoundsProduceTwoRanges() {
        // 170E ... 170W is a 20 degree strip across the dateline, not the
        // whole world.
        let anti = BoundingBox(
            southWest: Coordinate3D(latitude: -10.0, longitude: 170.0),
            northEast: Coordinate3D(latitude: 10.0, longitude: -170.0))
        let sequence = TileSequence(bounds: anti, zoomRange: 4 ... 4)

        let ranges = sequence.tileRanges(atZoom: 4)
        #expect(ranges.count == 2)

        // The two strips are 1 tile wide each (170E is tile 15, 170W is tile 0
        // at zoom 4), so 2 tiles per row instead of 16.
        let tiles = Array(sequence)
        #expect(tiles.count == 4) // 2 columns x 2 rows
        #expect(sequence.count == tiles.count)
        #expect(tiles.allSatisfy { $0.x == 0 || $0.x == 15 })
    }

    /// Antimeridian crossing bounds are not expanded to the world.
    @Test
    func antimeridianCrossingBoundsAreNotExpandedToTheWorld() {
        let anti = BoundingBox(
            southWest: Coordinate3D(latitude: -10.0, longitude: 170.0),
            northEast: Coordinate3D(latitude: 10.0, longitude: -170.0))
        let sequence = TileSequence(bounds: anti, zoomRange: 4 ... 4)

        // The whole world at zoom 4 would be 256 tiles.
        #expect(sequence.count < 256)
        #expect(sequence.count == 4)
    }

    /// Antimeridian crossing metatile sequence stays narrow.
    @Test
    func antimeridianCrossingMetatileSequenceStaysNarrow() {
        let anti = BoundingBox(
            southWest: Coordinate3D(latitude: -10.0, longitude: 170.0),
            northEast: Coordinate3D(latitude: 10.0, longitude: -170.0))
        let sequence = MetatileSequence(bounds: anti, zoomRange: 4 ... 4, metaSize: 2)

        let tiles = Set(Array(sequence).flatMap(\.tiles))
        #expect(tiles.count == 4)
        #expect(tiles.allSatisfy { $0.x == 0 || $0.x == 15 })
        #expect(sequence.count == Array(sequence).count)
    }

    /// Metatile origin carries the zoom.
    @Test
    func metatileOriginCarriesTheZoom() {
        let sequence = MetatileSequence(bounds: bounds, zoomRange: 12 ... 12, metaSize: 4)
        let origin = sequence.metatileOrigin(forX: 265, forY: 162, atZoom: 12)

        #expect(origin.x == 264)
        #expect(origin.y == 160)
        #expect(origin.z == 12)
    }

}
