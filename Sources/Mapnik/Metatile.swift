import Foundation
import GISTools
import MapnikC

/// A metatile: an aligned block of `metaSize` × `metaSize` XYZ tiles.
///
/// The block is anchored at `origin`, the north-west (top-left) tile. Tiles
/// are aligned to the metatile grid (their coordinates are multiples of
/// `metaSize`), matching how tile servers group work.
///
/// `tiles` lists the tiles that should actually be produced from the block —
/// typically the intersection of the aligned block with a bounding box.
public struct Metatile: Sendable, Hashable {

    /// The block's top-left (north-west) tile. Its x/y are multiples of
    /// `metaSize` at zoom `z`.
    public let origin: MapTile

    /// Tiles per metatile edge, 1...16.
    public let metaSize: Int

    /// The tiles to deliver from this block (subset of the block).
    public let tiles: [MapTile]

    public init(origin: MapTile, metaSize: Int, tiles: [MapTile] = []) {
        precondition(metaSize >= 1, "metaSize must be positive")
        let isInside: (MapTile) -> Bool = { tile in
            tile.z == origin.z
                && tile.x >= origin.x
                && tile.x < origin.x + metaSize
                && tile.y >= origin.y
                && tile.y < origin.y + metaSize
        }
        precondition(tiles.allSatisfy(isInside), "tiles must belong to the metatile block")
        self.origin = origin
        self.metaSize = metaSize
        self.tiles = tiles
    }

    /// All tiles of the block, in row-major order.
    public var blockTiles: [MapTile] {
        (0 ..< metaSize * metaSize).map { index in
            MapTile(x: origin.x + index % metaSize, y: origin.y + index / metaSize, z: origin.z)
        }
    }

    /// True if `tile` is part of this metatile block.
    public func contains(_ tile: MapTile) -> Bool {
        tile.z == origin.z
            && tile.x >= origin.x
            && tile.x < origin.x + metaSize
            && tile.y >= origin.y
            && tile.y < origin.y + metaSize
    }

}

/// Options controlling metatile rendering.
///
/// A metatile is a block of `metaSize` × `metaSize` tiles rendered as one
/// image in a single pass: one datasource query per layer instead of one per
/// tile, and label placement (collision detection) sees the whole block, so
/// labels no longer clip at tile edges inside the block.
///
/// ```swift
/// let options = MetatileOptions(metaSize: 4, render: .tile(format: .png()))
/// let metatile = try map.renderMetatile(x: 1080, y: 714, z: 11, options: options)
/// let tile = try metatile?.tile(x: 1082, y: 715) // crop out one tile
/// ```
public struct MetatileOptions: Sendable {

    /// The number of tiles per metatile edge. 1 renders plain tiles; 4 and 8
    /// are common tile-server values. Larger blocks reduce datasource queries
    /// further but hold more pixels in memory.
    ///
    /// The maximum is 16 (a 16 × 16 metatile of 256-pixel tiles at scale 2
    /// already holds 8192² pixels = 256 MB of RGBA data).
    public static let maxMetaSize = 16

    /// Tiles per metatile edge.
    public var metaSize: Int

    /// Per-tile render options: `size` is the tile edge length in pixels,
    /// `scale` the scale factor, `format` the output format used when
    /// cropping, `bufferSize` the padding applied around the whole metatile.
    public var render: RenderOptions

    public init(metaSize: Int = 4, render: RenderOptions = .tile()) {
        self.metaSize = metaSize
        self.render = render
    }

    /// The metatile's pixel dimensions (`metaSize * size * scale`).
    public var metatileSize: Int {
        Int(Double(render.width) * render.scale) * metaSize
    }

    /// Validates the options, throwing `MapnikError.invalidInput` for out of
    /// range values.
    func validate() throws {
        guard metaSize >= 1, metaSize <= Self.maxMetaSize else {
            throw MapnikError.invalidInput("metaSize must be in 1...\(Self.maxMetaSize), got \(metaSize)")
        }

        try render.validate()
        guard Int(Double(render.width) * render.scale) > 0 else {
            throw MapnikError.invalidInput("tile width × scale must be positive, got \(render.width) × \(render.scale)")
        }
    }

}

/// The result of a metatile render: the raw RGBA pixels of the block plus
/// accessors that crop and encode individual tiles.
///
/// The metatile pixels are held until this value is released; a
/// `MetatileRendered` of 4 × 4 256-pixel tiles holds 4 MB. Use `tile(_:)`
/// to extract encoded tiles, then drop the value.
public struct MetatileRendered: Sendable {

    /// The metatile's top-left (north-west) tile.
    public let origin: MapTile

    /// Tiles per metatile edge.
    public let metaSize: Int

    /// Tile edge length in pixels (before scale).
    public let tileSize: Int

    /// Scale factor used for rendering.
    public let scale: Double

    /// The metatile's pixel dimensions.
    public let width: Int
    public let height: Int

    /// True if the whole metatile is transparent (no features painted).
    /// Individual `tile` calls still honor their own skip logic.
    public let isFullyTransparent: Bool

    let rgba: Data
    let options: RenderOptions

    init(
        origin: MapTile,
        metaSize: Int,
        options: RenderOptions,
        width: Int,
        height: Int,
        isFullyTransparent: Bool,
        rgba: Data,
    ) {
        self.origin = origin
        self.metaSize = metaSize
        self.tileSize = options.width
        self.scale = options.scale
        self.width = width
        self.height = height
        self.isFullyTransparent = isFullyTransparent
        self.rgba = rgba
        self.options = options
    }

    /// The metatile's pixel stride (edge length) of one tile inside the
    /// metatile image, including the scale factor.
    var stride: Int {
        Int(Double(tileSize) * scale)
    }

    /// Crops and encodes the tile at offset (`dx`, `dy`) inside the metatile.
    ///
    /// - Parameters:
    ///   - dx: Tile column within the metatile, 0 ..< metaSize.
    ///   - dy: Tile row within the metatile, 0 ..< metaSize.
    ///   - format: Output format; defaults to the format from the render
    ///     options used to produce this metatile.
    /// - Returns: The encoded tile, or `nil` if the tile is fully transparent
    ///   and skipping is enabled.
    /// - Throws: `MapnikError.invalidInput` for out-of-range offsets,
    ///   `MapnikError.renderingFailed` if encoding failed.
    public func tile(dx: Int, dy: Int, format: ImageFormat? = nil) throws -> Data? {
        try cropTile(dx: dx, dy: dy, format: format)
    }

    /// Crops and encodes the tile identified by an absolute XYZ coordinate,
    /// which must lie inside this metatile's block.
    ///
    /// - Throws: `MapnikError.invalidInput` if the tile is outside the block.
    public func tile(at tile: MapTile) throws -> Data? {
        let dx = tile.x - origin.x
        let dy = tile.y - origin.y
        guard tile.z == origin.z, dx >= 0, dx < metaSize, dy >= 0, dy < metaSize else {
            throw MapnikError.invalidInput(
                "tile \(tile) is not part of metatile \(origin) + \(metaSize)×\(metaSize)")
        }

        return try cropTile(dx: dx, dy: dy, format: nil)
    }

    // MARK: - Private

    private func cropTile(dx: Int, dy: Int, format: ImageFormat?) throws -> Data? {
        guard dx >= 0, dx < metaSize, dy >= 0, dy < metaSize else {
            throw MapnikError.invalidInput(
                "tile offset (\(dx), \(dy)) out of range for \(metaSize)×\(metaSize) metatile")
        }
        guard rgba.count == width * height * 4, width > 0, height > 0 else {
            throw MapnikError.renderingFailed(
                "metatile buffer size mismatch: got \(rgba.count) bytes, expected \(width * height * 4)")
        }

        let imageFormat = format ?? options.format
        if case .svg = imageFormat {
            throw MapnikError.invalidInput("format \(imageFormat.typeString) requires a dedicated SVG render call")
        }

        let stridePixels = stride
        let offsetBytes = (dy * stridePixels * width + dx * stridePixels) * 4

        var data: UnsafeMutablePointer<UInt8>? = nil
        var size: CUnsignedLong = 0
        var isEmpty = false

        try rgba.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            try CErrors.withError(MapnikError.renderingFailed) { errorOut in
                guard let base = buffer.baseAddress else {
                    throw MapnikError.renderingFailed("metatile buffer is empty")
                }

                return mapnik_image_crop_encode(
                    base.assumingMemoryBound(to: UInt8.self) + offsetBytes,
                    Int32(clamping: width),
                    Int32(clamping: height),
                    0,
                    0,
                    Int32(clamping: stridePixels),
                    Int32(clamping: stridePixels),
                    imageFormat.typeString,
                    options.skipFullyTransparent,
                    &data,
                    &size,
                    &isEmpty,
                    errorOut)
            }
        }

        if isEmpty || data == nil || size == 0 {
            return nil
        }
        return Data(
            bytesNoCopy: data!,
            count: Int(size),
            deallocator: .custom { buffer, _ in
                mapnik_free_buffer(buffer)
            })
    }

}
