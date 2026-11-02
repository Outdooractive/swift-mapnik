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

    /// Upper bound for ``metaSize``. Larger blocks hold quadratically more
    /// pixels: a 16 × 16 metatile of 256-pixel tiles at scale 2 already holds
    /// 8192² pixels = 256 MB of RGBA data.
    public static let maxMetaSize = 16

    /// The block's top-left (north-west) tile. Its x/y are multiples of
    /// `metaSize` at zoom `z`.
    public let origin: MapTile

    /// Tiles per metatile edge, 1...16.
    public let metaSize: Int

    /// The tiles to deliver from this block (subset of the block).
    public let tiles: [MapTile]

    /// Creates a metatile block.
    ///
    /// - Parameters:
    ///   - origin: The block's top-left (north-west) tile.
    ///   - metaSize: Tiles per metatile edge, 1...``maxMetaSize``.
    ///   - tiles: The tiles to deliver from this block; each must lie inside
    ///     the block. Defaults to an empty list.
    public init(origin: MapTile, metaSize: Int, tiles: [MapTile] = []) {
        precondition(metaSize >= 1, "metaSize must be positive")
        precondition(metaSize <= Self.maxMetaSize, "metaSize must not exceed \(Self.maxMetaSize)")
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
/// let block = Metatile(origin: MapTile(x: 1080, y: 712, z: 11), metaSize: 4)
/// let metatile = try map.renderMetatile(block, options: options)
/// let tile = try metatile?.tile(at: MapTile(x: 1082, y: 715, z: 11)) // crop one tile
/// ```
public struct MetatileOptions: Sendable {

    /// The number of tiles per metatile edge. 1 renders plain tiles; 4 and 8
    /// are common tile-server values. Larger blocks reduce datasource queries
    /// further but hold more pixels in memory.
    ///
    /// The maximum is 16 (a 16 × 16 metatile of 256-pixel tiles at scale 2
    /// already holds 8192² pixels = 256 MB of RGBA data).
    public static let maxMetaSize = Metatile.maxMetaSize

    /// Tiles per metatile edge.
    public var metaSize: Int

    /// Per-tile render options: `width`/`height` are the tile edge lengths in
    /// pixels, `scale` the scale factor, `format` the output format used when
    /// cropping, `bufferSize` the padding applied around the whole metatile.
    public var render: RenderOptions

    public init(metaSize: Int = 4, render: RenderOptions = .tile()) {
        self.metaSize = metaSize
        self.render = render
    }

    /// The metatile's pixel dimensions (`metaSize * width * scale` by
    /// `metaSize * height * scale`).
    public var metatileWidth: Int {
        Int(Double(render.width) * render.scale) * metaSize
    }

    /// The metatile's pixel height (`metaSize * height * scale`).
    public var metatileHeight: Int {
        Int(Double(render.height) * render.scale) * metaSize
    }

    /// The metatile's pixel dimensions, assuming square tiles.
    ///
    /// Use ``metatileWidth``/``metatileHeight`` for non-square tiles.
    public var metatileSize: Int {
        metatileWidth
    }

    /// Validates the options, throwing `MapnikError.invalidInput` for out of
    /// range values.
    func validate() throws {
        guard metaSize >= 1, metaSize <= Self.maxMetaSize else {
            throw MapnikError.invalidInput("metaSize must be in 1...\(Self.maxMetaSize), got \(metaSize)")
        }

        try render.validate()
        try Self.validatePixelSize(render.width, render.scale, metaSize: metaSize)
        try Self.validatePixelSize(render.height, render.scale, metaSize: metaSize)
    }

    /// Throws when `edge * scale * metaSize` does not fit in an `Int`.
    private static func validatePixelSize(_ edge: Int, _ scale: Double, metaSize: Int) throws {
        let pixels = Double(edge) * scale
        guard pixels > 0, pixels.isFinite,
              pixels * Double(metaSize) <= Double(Int.max)
        else {
            throw MapnikError.invalidInput(
                "tile size × scale × metaSize is out of range, got \(edge) × \(scale) × \(metaSize)")
        }
    }

}

/// The result of a metatile render: the raw RGBA pixels of the block plus
/// accessors that crop and encode individual tiles.
///
/// The metatile pixels are held until this value is released; a
/// `MetatileRendered` of 4 × 4 256-pixel tiles holds 4 MB. Use `tile(_:)`
/// to extract encoded tiles, then drop the value.
///
/// - Note: a cropped tile is byte-for-byte identical to the same tile rendered
///   on its own when the per-tile device size (`tileSize * scale`) is an
///   integer and the metatile is rendered at the same scale. With fractional
///   scale factors the block is rasterized as one image, so sub-pixel geometry
///   can differ slightly from a standalone tile render.
public struct MetatileRendered: Sendable {

    /// The metatile's top-left (north-west) tile.
    public let origin: MapTile

    /// Tiles per metatile edge.
    public let metaSize: Int

    /// Tile edge length in pixels (before scale).
    public let tileSize: Int

    /// Tile edge height in pixels (before scale). Equal to ``tileSize`` for
    /// square tiles.
    public let tileHeight: Int

    /// Scale factor used for rendering.
    public let scale: Double

    /// The metatile's pixel dimensions.
    public let width: Int
    public let height: Int

    /// True if the whole metatile is transparent (no features painted).
    /// Individual `tile` calls still honor their own skip logic.
    public let isFullyTransparent: Bool

    /// The RGBA pixel at (`x`, `y`) within the metatile image (premultiplied,
    /// `[r, g, b, a]`). Diagnostics/testing helper — not for bulk pixel access.
    ///
    /// - Returns: `nil` for out-of-range coordinates.
    public func pixel(x: Int, y: Int) -> [UInt8]? {
        guard x >= 0, x < width, y >= 0, y < height else {
            return nil
        }

        let offset = (y * width + x) * 4
        guard offset + 3 < rgba.count else {
            return nil
        }

        return [rgba[offset], rgba[offset + 1], rgba[offset + 2], rgba[offset + 3]]
    }

    /// The raw premultiplied RGBA8 pixels of the whole block, top-down with no
    /// row padding (`width * height * 4` bytes).
    ///
    /// The buffer is shared (copy-on-write), so this accessor is cheap.
    public var pixels: Data {
        rgba
    }

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
        self.tileHeight = options.height
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

    /// The vertical pixel stride of one tile inside the metatile image.
    var strideY: Int {
        Int(Double(tileHeight) * scale)
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

        let stridePixels = stride
        let stridePixelsY = strideY
        guard stridePixels * metaSize == width, stridePixelsY * metaSize == height else {
            throw MapnikError.renderingFailed(
                "metatile stride mismatch: \(stridePixels)×\(stridePixelsY) per tile × \(metaSize) "
                    + "does not match the \(width)×\(height) block")
        }

        let imageFormat = format ?? options.format
        if case .svg = imageFormat {
            throw MapnikError.invalidInput("format \(imageFormat.typeString) requires a dedicated SVG render call")
        }

        let offsetBytes = (dy * stridePixelsY * width + dx * stridePixels) * 4

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
                    Int32(clamping: stridePixelsY),
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
        guard let data else {
            return nil
        }

        return Data(
            bytesNoCopy: data,
            count: Int(size),
            deallocator: .custom { buffer, _ in
                mapnik_free_buffer(buffer)
            })
    }

}
