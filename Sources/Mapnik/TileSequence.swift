import Foundation
import GISTools

/// A sequence of all XYZ tiles that intersect a bounding box, across a zoom
/// range.
///
/// Tiles are generated per zoom level in row-major order. The zoom order is
/// configurable, matching both tile-pyramid building (coarse first) and
/// region rendering workflows (fine first).
///
/// Example:
///
/// ```swift
/// let bounds = BoundingBox(
///     southWest: Coordinate3D(latitude: 47.2, longitude: 10.2),
///     northEast: Coordinate3D(latitude: 47.6, longitude: 10.6))
///
/// for tile in TileSequence(bounds: bounds, zoomRange: 14 ... 15) {
///     // render tile ...
/// }
/// ```
public struct TileSequence: Sequence, Sendable {

    /// Order in which zoom levels are visited.
    public enum ZoomOrder: Sendable, Hashable {

        /// Start at the lowest zoom level and zoom in. Useful for building
        /// coarse-to-fine tile pyramids.
        case ascending

        /// Start at the highest zoom level and zoom out.
        case descending

    }

    /// The bounding box the tiles cover, in WGS 84 degrees.
    public let bounds: BoundingBox

    /// The zoom levels to visit, 0...30.
    public let zoomRange: ClosedRange<Int>

    /// The order in which zoom levels are visited.
    public let zoomOrder: ZoomOrder

    /// Creates a tile sequence.
    ///
    /// - Parameters:
    ///   - bounds: The area to cover, in WGS 84 degrees.
    ///   - zoomRange: The zoom levels to visit, 0...30.
    ///   - zoomOrder: The order in which zoom levels are visited.
    /// - Throws: `MapnikError.invalidInput` when the zoom range is out of
    ///   range.
    public init(
        bounds: BoundingBox,
        zoomRange: ClosedRange<Int>,
        zoomOrder: ZoomOrder = .descending,
    ) throws {
        guard zoomRange.lowerBound >= 0, zoomRange.upperBound <= 30 else {
            throw MapnikError.invalidInput(
                "zoom range must be in 0...30, got \(zoomRange.lowerBound)...\(zoomRange.upperBound)")
        }

        self.bounds = bounds
        self.zoomRange = zoomRange
        self.zoomOrder = zoomOrder
    }

    /// Returns an iterator over the tiles.
    public func makeIterator() -> Iterator {
        Iterator(self)
    }

    /// The inclusive min/max tile coordinates at a zoom level.
    ///
    /// For a bounding box that crosses the antimeridian the tiles are not
    /// contiguous in `x`; use ``tileRanges(atZoom:)`` for those.
    public func tileRange(atZoom zoom: Int) -> (min: MapTile, max: MapTile) {
        let ranges = tileRanges(atZoom: zoom)
        let min = ranges.map(\.min).reduce(ranges[0].min) { lhs, rhs in
            MapTile(x: Swift.min(lhs.x, rhs.x), y: Swift.min(lhs.y, rhs.y), z: zoom)
        }
        let max = ranges.map(\.max).reduce(ranges[0].max) { lhs, rhs in
            MapTile(x: Swift.max(lhs.x, rhs.x), y: Swift.max(lhs.y, rhs.y), z: zoom)
        }
        return (min, max)
    }

    /// The inclusive tile ranges at a zoom level, in visit order.
    ///
    /// A bounding box that does not cross the antimeridian produces exactly
    /// one range. A box that does (e.g. 170°E ... 170°W) produces two: the
    /// eastern strip and the western strip, instead of incorrectly spanning
    /// the whole world.
    public func tileRanges(atZoom zoom: Int) -> [(min: MapTile, max: MapTile)] {
        let southWest = MapTile(coordinate: bounds.southWest, atZoom: zoom)
        let northEast = MapTile(coordinate: bounds.northEast, atZoom: zoom)

        let minY = Swift.min(southWest.y, northEast.y)
        let maxY = Swift.max(southWest.y, northEast.y)

        func range(minX: Int, maxX: Int) -> (min: MapTile, max: MapTile) {
            (MapTile(x: minX, y: minY, z: zoom), MapTile(x: maxX, y: maxY, z: zoom))
        }

        // `MapTile(coordinate:atZoom:)` wraps longitudes into 0 ..< 2^zoom, so
        // a box crossing the antimeridian yields minX > maxX.
        if southWest.x <= northEast.x {
            return [range(minX: southWest.x, maxX: northEast.x)]
        }

        let last = (1 << zoom) - 1
        return [
            range(minX: southWest.x, maxX: last),
            range(minX: 0, maxX: northEast.x),
        ]
    }

    /// The number of tiles in this sequence.
    ///
    /// Sums the bounding box tile counts over the whole zoom range, so a
    /// region that spans one tile at zoom 14 and nine tiles at zoom 15
    /// yields 10.
    public var count: Int {
        var total = 0
        for zoom in zoomRange {
            for range in tileRanges(atZoom: zoom) {
                total += (range.max.x - range.min.x + 1) * (range.max.y - range.min.y + 1)
            }
        }
        return total
    }

    // MARK: - Iterator

    public struct Iterator: IteratorProtocol, Sendable {

        private let sequence: TileSequence
        private var zoomIndex: Int
        private var rangeIndex: Int
        private var ranges: [(min: MapTile, max: MapTile)]
        private var currentX: Int
        private var currentY: Int
        private var isFinished = false

        fileprivate init(_ sequence: TileSequence) {
            self.sequence = sequence
            self.zoomIndex = 0
            self.rangeIndex = 0

            let firstZoom = sequence.zoomLevels.first ?? 0
            self.ranges = sequence.tileRanges(atZoom: firstZoom)
            self.currentX = ranges[0].min.x
            self.currentY = ranges[0].min.y
        }

        /// Returns the next tile, or `nil` when the sequence is exhausted.
        public mutating func next() -> MapTile? {
            if isFinished {
                return nil
            }

            let range = ranges[rangeIndex]
            let tile = MapTile(x: currentX, y: currentY, z: range.min.z)

            // Advance the cursor (row-major order), moving to the next range
            // (antimeridian split) and then the next zoom level after the last
            // row.
            currentX += 1
            if currentX > range.max.x {
                currentX = range.min.x
                currentY += 1
                if currentY > range.max.y {
                    advanceRange()
                }
            }

            return tile
        }

        private mutating func advanceRange() {
            rangeIndex += 1
            if rangeIndex < ranges.count {
                currentX = ranges[rangeIndex].min.x
                currentY = ranges[rangeIndex].min.y
                return
            }

            advanceZoom()
        }

        private mutating func advanceZoom() {
            zoomIndex += 1
            let zoomLevels = sequence.zoomLevels
            guard zoomIndex < zoomLevels.count else {
                isFinished = true
                return
            }

            ranges = sequence.tileRanges(atZoom: zoomLevels[zoomIndex])
            rangeIndex = 0
            currentX = ranges[0].min.x
            currentY = ranges[0].min.y
        }

    }

    /// The zoom levels this sequence visits, in visit order.
    fileprivate var zoomLevels: [Int] {
        let levels = Array(zoomRange)
        return zoomOrder == .ascending ? levels : levels.reversed()
    }

}

/// A thread-safe tile generator that hands out tiles one by one.
///
/// Unlike the plain `Iterator`, this can be shared across tasks and used as
/// the work source for a `WorkQueue`. The mutable cursor is protected by an
/// `NSLock` since a class instance is shared by reference.
public final class TileGenerator: @unchecked Sendable {

    private let sequence: TileSequence
    private let lock = NSLock()
    private var iterator: TileSequence.Iterator

    /// Creates a generator for `sequence`.
    public init(_ sequence: TileSequence) {
        self.sequence = sequence
        self.iterator = sequence.makeIterator()
    }

    /// Returns the next tile, or `nil` when the sequence is exhausted.
    public func next() -> MapTile? {
        lock.lock()
        defer { lock.unlock() }
        return iterator.next()
    }

    /// The total number of tiles in the underlying sequence.
    public var count: Int {
        sequence.count
    }

}

/// A sequence of metatiles covering a bounding box across a zoom range.
///
/// Like `TileSequence`, but hands out aligned `metaSize` × `metaSize` blocks
/// instead of individual tiles: rendering one block is a single mapnik pass
/// (one datasource query per layer) and produces the pixels for up to
/// `metaSize`² tiles, from which each tile can be cropped.
///
/// Blocks are aligned to the metatile grid (tile coordinates that are
/// multiples of `metaSize`); each block's `tiles` list contains only the
/// tiles that intersect the bounding box, so crops for tiles outside the box
/// are never requested. Blocks are yielded in row-major order, zoom levels
/// in visit order like `TileSequence`.
///
/// Example:
///
/// ```swift
/// for metatile in MetatileSequence(bounds: bounds, zoomRange: 14 ... 15) {
///     let rendered = try map.renderMetatile(metatile, options: .tile())
///     for tile in metatile.tiles {
///         if let data = try rendered?.tile(at: tile) {
///             // write data ...
///         }
///     }
/// }
/// ```
public struct MetatileSequence: Sequence, Sendable {

    /// Number of tiles per metatile edge, 1...16.
    public let metaSize: Int

    /// The bounding box the blocks cover, in WGS 84 degrees.
    public let bounds: BoundingBox

    /// The zoom levels to visit, 0...30.
    public let zoomRange: ClosedRange<Int>

    /// The order in which zoom levels are visited.
    public let zoomOrder: TileSequence.ZoomOrder

    /// Creates a metatile sequence.
    ///
    /// - Parameters:
    ///   - bounds: The area to cover, in WGS 84 degrees.
    ///   - zoomRange: The zoom levels to visit, 0...30.
    ///   - metaSize: Tiles per metatile edge, 1...``MetatileOptions/maxMetaSize``.
    ///   - zoomOrder: The order in which zoom levels are visited.
    /// - Throws: `MapnikError.invalidInput` when `metaSize` or the zoom range
    ///   is out of range.
    public init(
        bounds: BoundingBox,
        zoomRange: ClosedRange<Int>,
        metaSize: Int = 4,
        zoomOrder: TileSequence.ZoomOrder = .descending,
    ) throws {
        guard metaSize >= 1, metaSize <= MetatileOptions.maxMetaSize else {
            throw MapnikError.invalidInput(
                "metaSize must be in 1...\(MetatileOptions.maxMetaSize), got \(metaSize)")
        }
        guard zoomRange.lowerBound >= 0, zoomRange.upperBound <= 30 else {
            throw MapnikError.invalidInput(
                "zoom range must be in 0...30, got \(zoomRange.lowerBound)...\(zoomRange.upperBound)")
        }

        self.metaSize = metaSize
        self.bounds = bounds
        self.zoomRange = zoomRange
        self.zoomOrder = zoomOrder
    }

    /// Returns an iterator over the tiles.
    public func makeIterator() -> Iterator {
        Iterator(self)
    }

    /// The zoom levels this sequence visits, in visit order.
    public var zoomLevels: [Int] {
        let levels = Array(zoomRange)
        return zoomOrder == .ascending ? levels : levels.reversed()
    }

    /// The aligned metatile origin (tile coordinates floored to a multiple of
    /// `metaSize`) covering the tile at (x, y) at `zoom`.
    ///
    /// - Parameters:
    ///   - x: Tile column.
    ///   - y: Tile row.
    ///   - zoom: Zoom level of the tile; stored on the returned origin so it
    ///     can be passed to `Mapnik.renderMetatile(origin:metaSize:)`.
    public func metatileOrigin(forX x: Int, forY y: Int, atZoom zoom: Int) -> MapTile {
        MapTile(
            x: x - ((x % metaSize) + metaSize) % metaSize,
            y: y - ((y % metaSize) + metaSize) % metaSize,
            z: zoom)
    }

    /// The number of metatile blocks in this sequence.
    public var count: Int {
        var total = 0
        for zoom in zoomLevels {
            for range in tileRanges(atZoom: zoom) {
                let xBlocks = blockCount(from: range.min.x, to: range.max.x)
                let yBlocks = blockCount(from: range.min.y, to: range.max.y)
                total += xBlocks * yBlocks
            }
        }
        return total
    }

    /// The inclusive min/max tile coordinates at a zoom level.
    ///
    /// For a bounding box that crosses the antimeridian the tiles are not
    /// contiguous in `x`; use ``tileRanges(atZoom:)`` for those.
    public func tileRange(atZoom zoom: Int) -> (min: MapTile, max: MapTile) {
        let ranges = tileRanges(atZoom: zoom)
        let min = ranges.map(\.min).reduce(ranges[0].min) { lhs, rhs in
            MapTile(x: Swift.min(lhs.x, rhs.x), y: Swift.min(lhs.y, rhs.y), z: zoom)
        }
        let max = ranges.map(\.max).reduce(ranges[0].max) { lhs, rhs in
            MapTile(x: Swift.max(lhs.x, rhs.x), y: Swift.max(lhs.y, rhs.y), z: zoom)
        }
        return (min, max)
    }

    /// The inclusive tile ranges at a zoom level, in visit order.
    ///
    /// A bounding box that crosses the antimeridian produces two ranges
    /// instead of incorrectly spanning the whole world.
    public func tileRanges(atZoom zoom: Int) -> [(min: MapTile, max: MapTile)] {
        let southWest = MapTile(coordinate: bounds.southWest, atZoom: zoom)
        let northEast = MapTile(coordinate: bounds.northEast, atZoom: zoom)

        let minY = Swift.min(southWest.y, northEast.y)
        let maxY = Swift.max(southWest.y, northEast.y)

        func range(minX: Int, maxX: Int) -> (min: MapTile, max: MapTile) {
            (MapTile(x: minX, y: minY, z: zoom), MapTile(x: maxX, y: maxY, z: zoom))
        }

        if southWest.x <= northEast.x {
            return [range(minX: southWest.x, maxX: northEast.x)]
        }

        let last = (1 << zoom) - 1
        return [
            range(minX: southWest.x, maxX: last),
            range(minX: 0, maxX: northEast.x),
        ]
    }

    /// Number of aligned metatile blocks needed to cover tiles
    /// `from`...`to` (inclusive) along one axis.
    private func blockCount(from: Int, to: Int) -> Int {
        let firstBlock = from - ((from % metaSize) + metaSize) % metaSize
        let lastBlock = to - ((to % metaSize) + metaSize) % metaSize
        return (lastBlock - firstBlock) / metaSize + 1
    }

    // MARK: - Iterator

    public struct Iterator: IteratorProtocol, Sendable {

        private let sequence: MetatileSequence
        private var zoomIndex: Int
        private var rangeIndex: Int
        private var ranges: [(min: MapTile, max: MapTile)]
        private var blockX: Int
        private var blockY: Int
        private var maxBlockX: Int
        private var maxBlockY: Int
        private var isFinished = false

        fileprivate init(_ sequence: MetatileSequence) {
            self.sequence = sequence
            self.zoomIndex = 0
            self.rangeIndex = 0

            let firstZoom = sequence.zoomLevels.first ?? 0
            self.ranges = sequence.tileRanges(atZoom: firstZoom)
            self.blockX = Self.floorToBlock(ranges[0].min.x, sequence.metaSize)
            self.blockY = Self.floorToBlock(ranges[0].min.y, sequence.metaSize)
            self.maxBlockX = Self.floorToBlock(ranges[0].max.x, sequence.metaSize)
            self.maxBlockY = Self.floorToBlock(ranges[0].max.y, sequence.metaSize)
        }

        public mutating func next() -> Metatile? {
            if isFinished {
                return nil
            }

            let range = ranges[rangeIndex]
            let origin = MapTile(x: blockX, y: blockY, z: range.min.z)
            let tiles = Self.tilesForBlock(
                origin: origin,
                metaSize: sequence.metaSize,
                minTile: range.min,
                maxTile: range.max)

            // Advance to the next block (row-major), moving to the next range
            // (antimeridian split) and then the next zoom level after the last
            // row of blocks.
            blockX += sequence.metaSize
            if blockX > maxBlockX {
                blockX = Self.floorToBlock(range.min.x, sequence.metaSize)
                blockY += sequence.metaSize
                if blockY > maxBlockY {
                    advanceRange()
                }
            }

            return Metatile(uncheckedOrigin: origin, metaSize: sequence.metaSize, tiles: tiles)
        }

        private mutating func advanceRange() {
            rangeIndex += 1
            if rangeIndex < ranges.count {
                let range = ranges[rangeIndex]
                blockX = Self.floorToBlock(range.min.x, sequence.metaSize)
                blockY = Self.floorToBlock(range.min.y, sequence.metaSize)
                maxBlockX = Self.floorToBlock(range.max.x, sequence.metaSize)
                maxBlockY = Self.floorToBlock(range.max.y, sequence.metaSize)
                return
            }

            advanceZoom()
        }

        private mutating func advanceZoom() {
            zoomIndex += 1
            let zoomLevels = sequence.zoomLevels
            guard zoomIndex < zoomLevels.count else {
                isFinished = true
                return
            }

            ranges = sequence.tileRanges(atZoom: zoomLevels[zoomIndex])
            rangeIndex = 0
            let range = ranges[0]
            blockX = Self.floorToBlock(range.min.x, sequence.metaSize)
            blockY = Self.floorToBlock(range.min.y, sequence.metaSize)
            maxBlockX = Self.floorToBlock(range.max.x, sequence.metaSize)
            maxBlockY = Self.floorToBlock(range.max.y, sequence.metaSize)
        }

        private static func floorToBlock(_ coordinate: Int, _ metaSize: Int) -> Int {
            coordinate - ((coordinate % metaSize) + metaSize) % metaSize
        }

        private static func tilesForBlock(
            origin: MapTile,
            metaSize: Int,
            minTile: MapTile,
            maxTile: MapTile,
        ) -> [MapTile] {
            var tiles: [MapTile] = []
            let minY = Swift.max(origin.y, minTile.y)
            let maxY = Swift.min(origin.y + metaSize - 1, maxTile.y)
            let minX = Swift.max(origin.x, minTile.x)
            let maxX = Swift.min(origin.x + metaSize - 1, maxTile.x)
            var y = minY
            while y <= maxY {
                var x = minX
                while x <= maxX {
                    tiles.append(MapTile(x: x, y: y, z: origin.z))
                    x += 1
                }
                y += 1
            }
            return tiles
        }

    }

}

/// A thread-safe metatile generator that hands out blocks one by one.
///
/// The metatile counterpart of `TileGenerator`: shareable across tasks and
/// usable as the work source of a `WorkQueue`, whose `processWork` closure
/// then renders whole blocks and crops the individual tiles.
public final class MetatileGenerator: @unchecked Sendable {

    private let lock = NSLock()
    private var iterator: MetatileSequence.Iterator
    private let sequence: MetatileSequence

    /// Creates a generator for `sequence`.
    public init(_ sequence: MetatileSequence) {
        self.sequence = sequence
        self.iterator = sequence.makeIterator()
    }

    /// Returns the next metatile block, or `nil` when the sequence is
    /// exhausted.
    public func next() -> Metatile? {
        lock.lock()
        defer { lock.unlock() }
        return iterator.next()
    }

    /// The total number of metatile blocks in the underlying sequence.
    public var count: Int {
        sequence.count
    }

}
