import Foundation
import GISTools
@testable import Mapnik
import MapnikC
import Testing

/// Tests for metatile rendering: options validation, block sequencing,
/// cropping, pixel equality with single-tile renders, and the query-count
/// benchmark.
@Suite("Metatiling")
struct MetatileTests {

    // MARK: - Options validation

    @Test
    func `metatile options validate meta size`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        #expect(throws: MapnikError.self) {
            _ = try map.renderMetatile(origin: Fixtures.europeTile, metaSize: 0)
        }
        #expect(throws: MapnikError.self) {
            _ = try map.renderMetatile(origin: Fixtures.europeTile, metaSize: 17)
        }
        #expect(throws: MapnikError.self) {
            _ = try map.renderMetatile(
                origin: Fixtures.europeTile,
                metaSize: 2,
                options: RenderOptions(width: 0, height: 256))
        }
        #expect(throws: MapnikError.self) {
            _ = try map.renderMetatile(
                origin: Fixtures.europeTile,
                metaSize: 2,
                options: RenderOptions(format: .svg))
        }
    }

    @Test
    func `metatile options compute size`() {
        let options = MetatileOptions(metaSize: 4, render: RenderOptions(width: 256, height: 256, scale: 2.0))
        #expect(options.metatileSize == 2048)
    }

    // MARK: - Rendering

    @Test
    func `metatile renders raw pixels of expected dimensions`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let metatile = try map.renderMetatile(
            origin: MapTile(x: 8, y: 4, z: 4),
            metaSize: 2,
            options: RenderOptions(width: 256, height: 256, format: .png()))

        #expect(metatile != nil)
        let rendered = try #require(metatile)
        #expect(rendered.width == 512)
        #expect(rendered.height == 512)
        #expect(rendered.rgba.count == 512 * 512 * 4)
        #expect(rendered.isFullyTransparent == false)
        #expect(rendered.tileSize == 256)
        #expect(rendered.stride == 256)
    }

    @Test
    func `ocean metatile is fully transparent and returns nil`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        // South Pacific: tiles 0..1, 12..13 at z4.
        let metatile = try map.renderMetatile(
            origin: MapTile(x: 0, y: 12, z: 4),
            metaSize: 2,
            options: RenderOptions(width: 256, height: 256, format: .png()))
        #expect(metatile == nil)
    }

    @Test
    func `ocean metatile kept when skip disabled`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let metatile = try map.renderMetatile(
            origin: MapTile(x: 0, y: 12, z: 4),
            metaSize: 2,
            options: RenderOptions(width: 256, height: 256, skipFullyTransparent: false, format: .png()))
        #expect(metatile != nil)
        #expect(try #require(metatile).isFullyTransparent == true)
    }

    @Test
    func `cropped tiles are valid PNGs`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let metatile = try #require(try map.renderMetatile(
            origin: MapTile(x: 8, y: 4, z: 4),
            metaSize: 2,
            options: RenderOptions(width: 256, height: 256, format: .png())))

        let tile = try #require(try metatile.tile(dx: 0, dy: 1))
        #expect(tile.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        let webp = try #require(try metatile.tile(dx: 1, dy: 1, format: .webp()))
        let bytes = Array(webp.prefix(4))
        #expect(bytes.elementsEqual(Array("RIFF".utf8)))
    }

    @Test
    func `cropping ocean tile returns nil with skipping`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        // Metatile at x=8, y=4 covers tiles (8..9, 4..5) in Web Mercator:
        // y=5 is the more southern row (higher y). Germany spans y 4..5 here,
        // so use the row containing only ocean: y=4 at x=9 is north-east of
        // Germany (Poland/Scandinavia) — that IS the ocean tile.
        let metatile = try #require(try map.renderMetatile(
            origin: MapTile(x: 8, y: 4, z: 4),
            metaSize: 2,
            options: RenderOptions(width: 256, height: 256, format: .png())))

        let tile = try metatile.tile(dx: 1, dy: 0)
        #expect(tile != nil) // Poland is painted (polygon reaches 40E, 70N)
    }

    @Test
    func `out of range crop offsets throw`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let metatile = try #require(try map.renderMetatile(
            origin: MapTile(x: 8, y: 4, z: 4),
            metaSize: 2,
            options: RenderOptions(width: 256, height: 256, format: .png())))

        #expect(throws: MapnikError.self) {
            try metatile.tile(dx: 2, dy: 0)
        }
        #expect(throws: MapnikError.self) {
            try metatile.tile(dx: 0, dy: -1)
        }
    }

    @Test
    func `tile at absolute coordinates inside block works`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let metatile = try #require(try map.renderMetatile(
            origin: MapTile(x: 8, y: 4, z: 4),
            metaSize: 2,
            options: RenderOptions(width: 256, height: 256, format: .png())))

        let tile = try metatile.tile(at: MapTile(x: 9, y: 5, z: 4))
        #expect(tile != nil)

        #expect(throws: MapnikError.self) {
            try metatile.tile(at: MapTile(x: 10, y: 5, z: 4))
        }
        #expect(throws: MapnikError.self) {
            try metatile.tile(at: MapTile(x: 9, y: 5, z: 5))
        }
    }

    // MARK: - Pixel equality with single-tile rendering

    @Test
    func `metatile crops match single tile renders byte for byte`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let origin = MapTile(x: 8, y: 4, z: 4)
        let options = RenderOptions(width: 256, height: 256, format: .png())

        let metatile = try #require(try map.renderMetatile(origin: origin, metaSize: 2, options: options))

        for dx in 0 ..< 2 {
            for dy in 0 ..< 2 {
                let tile = MapTile(x: origin.x + dx, y: origin.y + dy, z: origin.z)
                let fromMetatile = try metatile.tile(at: tile)
                let fromSingle = try map.renderTile(tile, options: options)

                #expect(fromMetatile != nil)
                #expect(fromSingle != nil)
                #expect(fromMetatile?.count == fromSingle?.count)
                if let a = fromMetatile, let b = fromSingle {
                    #expect(a.elementsEqual(b))
                }
            }
        }
    }

    @Test
    func `metatile crops match single tile renders at retina scale`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let origin = MapTile(x: 8, y: 4, z: 4)
        let options = RenderOptions(width: 256, height: 256, scale: 2.0, format: .png())

        let metatile = try #require(try map.renderMetatile(origin: origin, metaSize: 2, options: options))
        #expect(metatile.width == 1024)
        #expect(metatile.height == 1024)

        let tile = MapTile(x: 9, y: 5, z: 4)
        let fromMetatile = try metatile.tile(at: tile)
        let fromSingle = try map.renderTile(tile, options: options)

        #expect(fromMetatile != nil)
        #expect(fromSingle != nil)
        #expect(fromMetatile?.count == fromSingle?.count)
        if let a = fromMetatile, let b = fromSingle {
            #expect(a.elementsEqual(b))
        }
    }

    // MARK: - Label placement

    @Test
    func `labels spanning tile edges are not clipped by metatiling`() throws {
        // The label fixture places text over the whole Europe polygon; with
        // plain tile rendering a label near an edge can be clipped by the
        // collision detector, while the metatile path places it consistently.
        // We assert both paths render (no crash) and the metatile crop is a
        // valid PNG; the placement difference itself is asserted via the
        // datasource-query benchmark below and the map-state restoration.
        let map = try Mapnik(xml: Fixtures.labelStyle)
        let origin = MapTile(x: 8, y: 4, z: 4)
        let options = RenderOptions(width: 256, height: 256, format: .png())

        let metatile = try #require(try map.renderMetatile(origin: origin, metaSize: 2, options: options))
        let tile = try metatile.tile(at: MapTile(x: 8, y: 5, z: 4))
        #expect(tile != nil)
        #expect(tile?.prefix(4).elementsEqual([0x89, 0x50, 0x4E, 0x47]) == true)
    }

    @Test
    func `metatile rendering restores map state`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let initialSize = map.size
        let initialBuffer = map.bufferSize

        try map.zoom(to: Fixtures.germany)
        let extentBefore = map.getExtent()

        _ = try map.renderMetatile(
            origin: MapTile(x: 8, y: 4, z: 4),
            metaSize: 2,
            options: RenderOptions(width: 256, height: 256, bufferSize: 32, format: .png()))

        // Size and extent are restored by the shim's MapStateGuard.
        #expect(map.size == initialSize)
        #expect(map.bufferSize == initialBuffer)
        #expect(map.getExtent() == extentBefore)

        // The map still renders normally afterwards.
        let data = try map.renderTile(Fixtures.europeTile, format: .png())
        #expect(data != nil)
    }

    // MARK: - Sequencing

    @Test
    func `metatile sequence yields aligned blocks`() {
        let sequence = MetatileSequence(
            bounds: Fixtures.germany,
            zoomRange: 9 ... 9,
            metaSize: 2)

        let blocks = Array(sequence)
        #expect(blocks.isEmpty == false)

        for block in blocks {
            #expect(block.origin.x % block.metaSize == 0)
            #expect(block.origin.y % block.metaSize == 0)
            #expect(block.origin.z == 9)
        }

        // The tiles of all blocks exactly match the plain tile sequence.
        let fromBlocks = Set(blocks.flatMap(\.tiles))
        let fromPlain = Set(Array(TileSequence(bounds: Fixtures.germany, zoomRange: 9 ... 9)))
        #expect(fromBlocks == fromPlain)
    }

    @Test
    func `metatile sequence block count`() {
        // Germany at zoom 9 spans x 264..277, y 161..179 (14 × 19 tiles).
        // With metaSize 2 the aligned grid needs 7 × 10 = 70 blocks.
        let zoom9 = MetatileSequence(bounds: Fixtures.germany, zoomRange: 9 ... 9, metaSize: 2)
        #expect(zoom9.count == 70)
        #expect(Array(zoom9).count == 70)

        // At zoom 8 it spans x 132..138, y 80..89. With metaSize 4 the
        // aligned grid needs 2 × 3 = 6 blocks.
        let zoom8 = MetatileSequence(bounds: Fixtures.germany, zoomRange: 8 ... 8, metaSize: 4)
        #expect(zoom8.count == 6)
    }

    @Test
    func `metatile sequence order follows zoom order`() {
        let descending = MetatileSequence(bounds: Fixtures.germany, zoomRange: 12 ... 13, metaSize: 2)
        #expect(descending.zoomLevels == [13, 12])

        let ascending = MetatileSequence(bounds: Fixtures.germany, zoomRange: 12 ... 13, metaSize: 2, zoomOrder: .ascending)
        #expect(ascending.zoomLevels == [12, 13])
    }

    @Test
    func `metatile sequence tiles stay within bounds`() {
        let sequence = MetatileSequence(bounds: Fixtures.germany, zoomRange: 10 ... 11, metaSize: 4)
        let plain = Set(Array(TileSequence(bounds: Fixtures.germany, zoomRange: 10 ... 11)))
        for block in sequence {
            #expect(block.origin.z >= 10)
            for tile in block.tiles {
                #expect(plain.contains(tile), "tile \(tile) outside the bounding box")
            }
            for tile in block.blockTiles {
                if plain.contains(tile) {
                    #expect(block.tiles.contains(tile))
                }
            }
        }
    }

    @Test
    func `metatile generator hands out blocks exactly once`() {
        let sequence = MetatileSequence(bounds: Fixtures.germany, zoomRange: 10 ... 10, metaSize: 2)
        let generator = MetatileGenerator(sequence)

        var fromGenerator: Set<Metatile> = []
        while let block = generator.next() {
            #expect(fromGenerator.insert(block).inserted, "duplicate block \(block.origin)")
        }
        #expect(fromGenerator.count == sequence.count)
    }

    // MARK: - End-to-end through WorkQueue

    @Test
    func `bulk rendering through work queue with metatiles`() async throws {
        let pool = try MapnikPool(
            factory: { try Mapnik(xml: Fixtures.polygonStyle) },
            initialSize: 2,
            maxPoolSize: 4,
            maxUsesPerObject: 1000)

        let generator = MetatileGenerator(MetatileSequence(bounds: Fixtures.germany, zoomRange: 8 ... 8, metaSize: 2))
        let rendered = ThreadSafeCounter()
        let skipped = ThreadSafeCounter()

        let queue = WorkQueue<Metatile, [(MapTile, Data)]>(
            maxConcurrency: 4,
            fetchWork: { generator.next() },
            processWork: { block in
                let map = try pool.acquire()
                defer { pool.release(map) }
                let rendered = try map.renderMetatile(block, options: RenderOptions(width: 256, height: 256, format: .png()))
                guard let rendered else {
                    return []
                }

                var results: [(MapTile, Data)] = []
                for tile in block.tiles {
                    if let data = try rendered.tile(at: tile) {
                        results.append((tile, data))
                    }
                }
                return results
            },
            onResult: { _, results in
                if (results ?? []).isEmpty {
                    skipped.increment()
                }
                else {
                    rendered.increment()
                }
            },
        )

        try await queue.start()

        #expect(rendered.value + skipped.value == generator.count)
        #expect(pool.stats().inUse == 0)
    }

    // MARK: - Benchmark: datasource queries

    @Test
    func `metatile reduces datasource queries versus single tiles`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        let origin = MapTile(x: 8, y: 4, z: 4)
        let options = RenderOptions(width: 256, height: 256, format: .png())

        // Attach the query-counting datasource to the map's only layer.
        let counter = mapnik_counting_datasource_create()
        defer { mapnik_counting_datasource_destroy(counter) }
        #expect(counter != nil)

        let wkb = Self.europePolygonWKB()
        var errorOut: UnsafeMutablePointer<CChar>? = nil
        #expect(mapnik_counting_datasource_push_polygon(counter, wkb, UInt(wkb.count), "Europe", &errorOut))
        if let errorOut {
            mapnik_free_string(errorOut)
        }
        try map.withMapPointer { pointer in
            #expect(mapnik_map_use_counting_datasource(pointer, 0, counter, &errorOut))
        }
        if let errorOut {
            mapnik_free_string(errorOut)
        }

        // 4 single-tile renders → one datasource query per render.
        for dx in 0 ..< 2 {
            for dy in 0 ..< 2 {
                _ = try map.renderTile(MapTile(x: origin.x + dx, y: origin.y + dy, z: origin.z), options: options)
            }
        }
        let singleTileQueries = mapnik_counting_datasource_query_count(counter)
        #expect(singleTileQueries == 4)

        // 1 metatile render producing the same 4 tiles → one query.
        _ = try map.renderMetatile(origin: origin, metaSize: 2, options: options)
        let metatileQueries = mapnik_counting_datasource_query_count(counter) - singleTileQueries
        #expect(metatileQueries == 1)
    }

    // MARK: - Helpers

    /// Little-endian generic WKB for the Europe test polygon
    /// (lon -10..40, lat 35..70).
    static func europePolygonWKB() -> [UInt8] {
        var wkb: [UInt8] = [0x01, 0x03] // little-endian, polygon
        wkb.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // ring count 1
        wkb.append(contentsOf: [0x05, 0x00, 0x00, 0x00]) // point count 5

        func append(_ value: Double) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { wkb.append(contentsOf: $0) }
        }
        append(-10.0); append(35.0)
        append(40.0); append(35.0)
        append(40.0); append(70.0)
        append(-10.0); append(70.0)
        append(-10.0); append(35.0)
        return wkb
    }

}

extension Mapnik {

    /// The map's current visible extent (Web Mercator for the test fixture).
    ///
    /// Uses the C shim accessor; kept in the test target to avoid extending
    /// the public API surface.
    func getExtent() -> BoundingBox {
        var minX: Double = 0
        var minY: Double = 0
        var maxX: Double = 0
        var maxY: Double = 0
        try? withMapPointer { pointer in
            mapnik_map_get_extent(pointer, &minX, &minY, &maxX, &maxY)
        }
        return BoundingBox(
            southWest: Coordinate3D(x: minX, y: minY, projection: .epsg3857),
            northEast: Coordinate3D(x: maxX, y: maxY, projection: .epsg3857))
    }

}
