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

    @Test
    func `well known tile coordinates`() {
        // Berlin, Brandenburger Tor (52.5163 N, 13.3777 E) at zoom 10 is
        // tile (550, 335) in the XYZ scheme.
        let berlin = Coordinate3D(latitude: 52.5163, longitude: 13.3777)
        let tile = MapTile(coordinate: berlin, atZoom: 10)
        #expect(tile.x == 550)
        #expect(tile.y == 335)
        #expect(tile.z == 10)
    }

    @Test
    func `zoom zero covers world in one tile`() {
        let anywhere = Coordinate3D(latitude: 12.3, longitude: -45.6)
        let tile = MapTile(coordinate: anywhere, atZoom: 0)
        #expect(tile.x == 0)
        #expect(tile.y == 0)
    }

    @Test
    func `western longitudes produce correct tiles`() {
        // New York (40.7128 N, -74.0060 E) at zoom 6 is tile (18, 24).
        let newYork = Coordinate3D(latitude: 40.7128, longitude: -74.0060)
        let tile = MapTile(coordinate: newYork, atZoom: 6)
        #expect(tile.x == 18)
        #expect(tile.y == 24)
    }

    @Test
    func `longitudes just west of prime meridian round down`() {
        // -0.04 degrees at zoom 12 is inside tile 2047; truncation towards
        // zero would produce the same tile as +0.04 degrees (2048), which
        // is wrong.
        let justWest = Coordinate3D(latitude: 0.0, longitude: -0.04)
        let west = MapTile(coordinate: justWest, atZoom: 12)
        let east = MapTile(coordinate: Coordinate3D(latitude: 0.0, longitude: 0.04), atZoom: 12)
        #expect(west.x == 2047)
        #expect(east.x == 2048)
    }

    @Test
    func `longitudes beyond dateline wrap into range`() {
        // 185 degrees is east of the dateline and wraps to -175 degrees,
        // which is the first tile of the row.
        let overDateline = Coordinate3D(latitude: 0.0, longitude: 185.0)
        let tile = MapTile(coordinate: overDateline, atZoom: 4)
        #expect(tile.x == 0)
    }

    @Test
    func `poles clamped to mercator limit`() {
        let northPole = MapTile(coordinate: Coordinate3D(latitude: 90.0, longitude: 0.0), atZoom: 4)
        #expect(northPole.y == 0)

        let southPole = MapTile(coordinate: Coordinate3D(latitude: -90.0, longitude: 0.0), atZoom: 4)
        #expect(southPole.y == 15)
    }

    @Test
    func `coordinates in other projections reprojected`() {
        // Berlin in Web Mercator.
        let berlinMercator = Coordinate3D(x: 1_489_196.0, y: 6_899_390.0, projection: .epsg3857)
        let tile = MapTile(coordinate: berlinMercator, atZoom: 10)
        #expect(tile.x == 550)
        #expect(tile.y == 335)
    }

    @Test
    func `bounding box string parsing accepts valid input`() {
        let box = BoundingBox(parsing: "5.9, 47.2, 15.0, 55.0")
        #expect(box != nil)
        #expect(box?.southWest.longitude == 5.9)
        #expect(box?.southWest.latitude == 47.2)
        #expect(box?.northEast.longitude == 15.0)
        #expect(box?.northEast.latitude == 55.0)
        #expect(box?.projection == .epsg4326)
    }

    @Test
    func `bounding box string parsing rejects invalid input`() {
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

    @Test
    func `single zoom produces exactly B box tiles`() {
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

    @Test
    func `multiple zoom levels descend by default`() {
        let sequence = TileSequence(bounds: bounds, zoomRange: 12 ... 13)
        let tiles = Array(sequence)

        #expect(tiles.count == sequence.count)
        // First tiles come from zoom 13 (descending).
        #expect(tiles.first?.z == 13)
        // Last tiles come from zoom 12.
        #expect(tiles.last?.z == 12)
    }

    @Test
    func `ascending order visits zoom levels reverse`() {
        let sequence = TileSequence(bounds: bounds, zoomRange: 12 ... 13, zoomOrder: .ascending)
        let tiles = Array(sequence)

        #expect(tiles.first?.z == 12)
        #expect(tiles.last?.z == 13)
    }

    @Test
    func `count matches iterated tile count across zooms`() {
        for zoomRange in [10 ... 10, 10 ... 12, 0 ... 4, 14 ... 16] {
            let sequence = TileSequence(bounds: bounds, zoomRange: zoomRange)
            #expect(sequence.count == Array(sequence).count)
        }
    }

    @Test
    func `worldwide zoom iterates tiles`() {
        let sequence = TileSequence(bounds: .world, zoomRange: 0 ... 2)
        #expect(sequence.count == 21)
    }

    @Test
    func `tile generator hands out same tiles exactly once`() {
        let sequence = TileSequence(bounds: bounds, zoomRange: 13 ... 14)
        let generator = TileGenerator(sequence)

        var fromGenerator: Set<MapTile> = []
        while let tile = generator.next() {
            #expect(fromGenerator.insert(tile).inserted, "duplicate tile \(tile)")
        }
        #expect(fromGenerator.count == sequence.count)
    }

    @Test
    func `iterator returns nil after exhaustion`() {
        var iterator = TileSequence(bounds: bounds, zoomRange: 9 ... 9).makeIterator()
        for _ in 0 ..< 4 {
            #expect(iterator.next() != nil)
        }
        #expect(iterator.next() == nil)
        #expect(iterator.next() == nil)
    }

    @Test
    func `tiles at any zoom within valid bounds`() {
        let sequence = TileSequence(bounds: bounds, zoomRange: 0 ... 8)
        for tile in sequence {
            #expect(tile.x >= 0)
            #expect(tile.y >= 0)
            #expect(tile.x < (1 << tile.z))
            #expect(tile.y < (1 << tile.z))
        }
    }

}
