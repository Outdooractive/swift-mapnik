import Foundation
import GISTools
import MapnikC

/// A Mapnik map: a stylesheet plus rendering entry points.
///
/// A `Mapnik` instance wraps a loaded Mapnik XML stylesheet. Tile rendering
/// temporarily reconfigures the underlying map (size and extent) and restores
/// the previous state afterwards, so repeated renders are independent of each
/// other.
///
/// Thread safety: a single instance must not render concurrently from
/// multiple tasks (mapnik renderers are not thread-safe). Use one instance
/// per worker, e.g. via `MapnikPool`, which is designed exactly for that.
///
/// Example:
///
/// ```swift
/// let xml = try String(contentsOf: styleURL, encoding: .utf8)
/// let map = try Mapnik(xml: xml)
/// let png = try map.renderTile(x: 1082, y: 715, z: 11, format: .png())
/// ```
public final class Mapnik: @unchecked Sendable {

    /// Guards map creation, stylesheet loading and destruction.
    ///
    /// mapnik uses shared global state (datasource and font registries) that
    /// is not protected against concurrent access from multiple threads.
    /// Loading styles in parallel from a pool crashes inside libmapnik, so
    /// object lifecycle operations are serialized; rendering itself stays
    /// parallel and lock-free.
    ///
    /// The C shim enforces the same serialization internally
    /// (`mapnik_lifecycle_mutex()` in mapnik_c.cpp), so Swift-side and C-side
    /// lifecycle paths cannot interleave; the Swift lock additionally covers
    /// the pointer hand-off between the two calls in `init`.
    private static let lifecycleLock = NSLock()

    private let map: OpaquePointer

    // MARK: - Lifecycle

    /// Creates a map from a Mapnik XML stylesheet string.
    ///
    /// Lazily initializes the mapnik library with platform default plugin and
    /// font paths (see `MapnikConfig`). Call `MapnikConfig.initialize` first
    /// if you need custom paths or want init failures to surface early.
    ///
    /// - Parameters:
    ///   - xml: A Mapnik XML stylesheet. Data sources are resolved relative
    ///     to the paths baked into the stylesheet.
    ///   - width: Initial map width in pixels. Only relevant for free-form
    ///     rendering; tiles set their own size per call.
    ///   - height: Initial map height in pixels.
    /// - Throws: `MapnikError.initialization` if the library failed to
    ///   initialize, or `MapnikError.invalidStyle` with the mapnik parser
    ///   message if the stylesheet is invalid.
    public convenience init(
        xml: String,
        width: Int = 256,
        height: Int = 256,
    ) throws {
        try self.init(
            width: width,
            height: height,
            srs: nil,
            load: { mapPointer in
                try CErrors.withError(MapnikError.invalidStyle) { errorOut in
                    mapnik_map_load_xml(mapPointer, xml, errorOut)
                }
            })
    }

    /// Creates a map from a Mapnik XML stylesheet file.
    ///
    /// Equivalent to `Mapnik(xml:)` but loads the stylesheet from a file,
    /// which avoids an extra in-memory copy of large stylesheets. Paths
    /// inside the stylesheet (datasource files, shapefiles...) are resolved
    /// relative to the stylesheet's location, matching mapnik's
    /// command-line behavior.
    ///
    /// Lazily initializes the mapnik library with platform default plugin and
    /// font paths (see `MapnikConfig`). Call `MapnikConfig.initialize` first
    /// if you need custom paths or want init failures to surface early.
    ///
    /// - Parameters:
    ///   - url: File URL of a Mapnik XML stylesheet.
    ///   - width: Initial map width in pixels. Only relevant for free-form
    ///     rendering; tiles set their own size per call.
    ///   - height: Initial map height in pixels.
    /// - Throws: `MapnikError.initialization` if the library failed to
    ///   initialize, `MapnikError.invalidInput` if the file does not exist,
    ///   or `MapnikError.invalidStyle` with the mapnik parser message if the
    ///   stylesheet is invalid.
    public convenience init(
        xmlFile url: URL,
        width: Int = 256,
        height: Int = 256,
    ) throws {
        try self.init(
            width: width,
            height: height,
            srs: nil,
            load: { mapPointer in
                try CErrors.withError(MapnikError.invalidStyle) { errorOut in
                    mapnik_map_load_xml_file(mapPointer, url.path(percentEncoded: false), errorOut)
                }
            })
    }

    /// Creates a map object and loads a stylesheet into it.
    ///
    /// - Parameters:
    ///   - width: Initial map width in pixels.
    ///   - height: Initial map height in pixels.
    ///   - srs: Initial map SRS. Defaults to Web Mercator ("epsg:3857"); a
    ///     loaded stylesheet overwrites it with its own `@srs` attribute.
    ///   - load: Loads the stylesheet into the map (called with the map
    ///     pointer). Runs under the lifecycle lock.
    private init(
        width: Int,
        height: Int,
        srs: String?,
        load: (OpaquePointer) throws -> Void,
    ) throws {
        try MapnikConfig.ensureInitialized()

        guard width > 0, height > 0 else {
            throw MapnikError.invalidInput("width and height must be positive, got \(width)x\(height)")
        }

        // Note: once self.map is assigned, deinit owns the pointer. Assigning
        // before loading means a failed load is cleaned up by deinit when the
        // partially initialized object is released; destroying the map here
        // as well would be a double free.
        let mapPointer: OpaquePointer? = Self.lifecycleLock.withLock {
            if let srs {
                mapnik_map_create_with_srs(Int32(clamping: width), Int32(clamping: height), srs)
            }
            else {
                mapnik_map_create(Int32(clamping: width), Int32(clamping: height))
            }
        }
        guard let mapPointer else {
            throw MapnikError.initialization("could not create map object")
        }

        self.map = mapPointer

        try Self.lifecycleLock.withLock {
            try load(mapPointer)
        }
    }

    deinit {
        Self.lifecycleLock.withLock {
            mapnik_map_destroy(map)
        }
    }

    // MARK: - Tile rendering

    /// Renders an XYZ tile in Web Mercator projection.
    ///
    /// Tiles are always rendered in Web Mercator, regardless of the map's
    /// `srs`: the tile bounding box (EPSG:3857) is used as the map's extent
    /// for the duration of the call, and mapnik reprojects layer data into
    /// the map SRS on the fly. Rendering XYZ tiles of a map whose SRS is not
    /// Web Mercator (e.g. `epsg:4326`) is therefore valid, but the tile grid
    /// geometry is still Web Mercator's.
    ///
    /// - Parameters:
    ///   - x: Tile column at zoom `z`, 0 ..< 2^z.
    ///   - y: Tile row at zoom `z`, 0 ..< 2^z, counting from the north.
    ///   - z: Zoom level, 0...30.
    ///   - format: Output format. Defaults to lossless-ish WebP.
    ///   - size: Tile size in pixels. Defaults to 256; `512` is common for
    ///     MapLibre/Mapbox GL style tiles.
    ///   - scale: Scale factor, `2.0` for @2x tiles.
    ///   - bufferSize: Padding in pixels; `nil` uses the stylesheet buffer.
    /// - Returns: The encoded image, or `nil` if the tile is fully
    ///   transparent (no features painted).
    /// - Throws: `MapnikError.invalidInput` for out-of-range tiles,
    ///   `MapnikError.renderingFailed` if rendering failed.
    public func renderTile(
        x: Int,
        y: Int,
        z: Int,
        format: ImageFormat = .webp(),
        size: Int = 256,
        scale: Double = 1.0,
        bufferSize: Int? = nil,
    ) throws -> Data? {
        try renderTile(
            MapTile(x: x, y: y, z: z),
            format: format,
            size: size,
            scale: scale,
            bufferSize: bufferSize)
    }

    /// Renders an XYZ tile, taking size/format/scale from `options`.
    public func renderTile(
        _ tile: MapTile,
        options: RenderOptions,
    ) throws -> Data? {
        try options.validate()
        let previousBuffer = applyBuffer(options.bufferSize)
        defer {
            if let previousBuffer {
                setBufferSize(previousBuffer)
            }
        }

        var data: UnsafeMutablePointer<UInt8>? = nil
        var size: CUnsignedLong = 0
        var isEmpty = false

        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_render_tile_to_buffer(
                map,
                Int32(clamping: tile.x),
                Int32(clamping: tile.y),
                Int32(clamping: tile.z),
                Int32(clamping: options.width),
                options.scale,
                options.format.typeString,
                options.skipFullyTransparent,
                &data,
                &size,
                &isEmpty,
                errorOut)
        }

        if isEmpty || data == nil || size == 0 {
            return nil
        }
        return dataBuffer(data, size: Int(size))
    }

    /// Renders an XYZ tile with default options.
    public func renderTile(
        _ tile: MapTile,
        format: ImageFormat = .webp(),
        size: Int = 256,
        scale: Double = 1.0,
        bufferSize: Int? = nil,
    ) throws -> Data? {
        try renderTile(tile, options: RenderOptions(
            width: size,
            height: size,
            bufferSize: bufferSize,
            scale: scale,
            skipFullyTransparent: true,
            format: format))
    }

    /// Renders an XYZ tile to a file.
    ///
    /// - Parameters:
    ///   - tile: The tile to render.
    ///   - url: Destination file URL. Replaced if it exists.
    ///   - format: Output format.
    ///   - size: Tile size in pixels.
    ///   - scale: Scale factor, `2.0` for @2x tiles.
    ///   - bufferSize: Padding in pixels; `nil` uses the stylesheet buffer.
    /// - Throws: `MapnikError.renderingFailed` if rendering or writing
    ///   failed. Writing an empty tile is reported as a failure; check with
    ///   the `Data`-returning variant if empty tiles are expected.
    public func renderTileToFile(
        _ tile: MapTile,
        to url: URL,
        format: ImageFormat = .webp(),
        size: Int = 256,
        scale: Double = 1.0,
        bufferSize: Int? = nil,
    ) throws {
        let options = RenderOptions(
            width: size,
            height: size,
            bufferSize: bufferSize,
            scale: scale,
            format: format)
        try options.validate()
        let previousBuffer = applyBuffer(options.bufferSize)
        defer {
            if let previousBuffer {
                setBufferSize(previousBuffer)
            }
        }

        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_render_tile_to_file(
                map,
                Int32(clamping: tile.x),
                Int32(clamping: tile.y),
                Int32(clamping: tile.z),
                Int32(clamping: options.width),
                options.scale,
                options.format.typeString,
                url.path(percentEncoded: false),
                errorOut)
        }
    }

    // MARK: - Metatile rendering

    /// Renders a metatile — a block of `metaSize` × `metaSize` XYZ tiles — in
    /// a single render pass.
    ///
    /// One pass performs one datasource query per layer (instead of one per
    /// tile) and runs label placement across the whole block, which avoids
    /// the clipped labels that occur when tiles are rendered independently.
    /// The individual tiles are cropped out of the returned
    /// `MetatileRendered` on demand.
    ///
    /// Like `renderTile`, the block is always rendered in Web Mercator XYZ
    /// geometry regardless of the map's `srs`. The render options' buffer
    /// (padding) applies around the whole block, not per tile — with the
    /// default `bufferSize` of 16 on a 4 × 4 metatile of 256-pixel tiles this
    /// gives proportionally less per-tile padding than a plain tile render;
    /// raise `bufferSize` if edge padding matters for your style.
    ///
    /// - Parameters:
    ///   - origin: The block's top-left (north-west) tile.
    ///   - metaSize: Tiles per metatile edge, 1...16.
    ///   - options: Per-tile render options (tile size, scale, format, buffer).
    /// - Returns: The rendered metatile, or `nil` if the whole block is fully
    ///   transparent and `skipFullyTransparent` is set.
    /// - Throws: `MapnikError.invalidInput` for out-of-range tiles or options,
    ///   `MapnikError.renderingFailed` if rendering failed.
    public func renderMetatile(
        origin: MapTile,
        metaSize: Int,
        options: RenderOptions = .tile(),
    ) throws -> MetatileRendered? {
        guard metaSize >= 1, metaSize <= MetatileOptions.maxMetaSize else {
            throw MapnikError.invalidInput(
                "metaSize must be in 1...\(MetatileOptions.maxMetaSize), got \(metaSize)")
        }

        return try renderMetatile(Metatile(
            origin: origin,
            metaSize: metaSize,
            tiles: []), options: options)
    }

    /// Renders the tiles of a `Metatile` block in one pass.
    ///
    /// Only the origin and block size of `metatile` matter for rendering;
    /// its tile list is ignored (crop what you need from the result).
    public func renderMetatile(
        _ metatile: Metatile,
        options: RenderOptions = .tile(),
    ) throws -> MetatileRendered? {
        try renderMetatile(metatile, options: MetatileOptions(metaSize: metatile.metaSize, render: options))
    }

    /// Renders a metatile with full option control.
    public func renderMetatile(
        _ metatile: Metatile,
        options: MetatileOptions,
    ) throws -> MetatileRendered? {
        try options.validate()
        let previousBuffer = applyBuffer(options.render.bufferSize)
        defer {
            if let previousBuffer {
                setBufferSize(previousBuffer)
            }
        }

        var data: UnsafeMutablePointer<UInt8>? = nil
        var size: CUnsignedLong = 0
        var width: Int32 = 0
        var height: Int32 = 0
        var isEmpty = false

        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_render_metatile(
                map,
                Int32(clamping: metatile.origin.x),
                Int32(clamping: metatile.origin.y),
                Int32(clamping: metatile.origin.z),
                Int32(clamping: options.render.width),
                options.render.scale,
                Int32(clamping: options.metaSize),
                &data,
                &size,
                &width,
                &height,
                &isEmpty,
                errorOut)
        }

        let byteCount = Int(size)
        guard let data, byteCount > 0, width > 0, height > 0 else {
            throw MapnikError.renderingFailed("metatile render produced no output")
        }

        if isEmpty, options.render.skipFullyTransparent {
            defer { mapnik_free_buffer(data) }
            return nil
        }

        let buffer = Data(
            bytesNoCopy: data,
            count: byteCount,
            deallocator: .custom { buffer, _ in
                mapnik_free_buffer(buffer)
            })

        return MetatileRendered(
            origin: metatile.origin,
            metaSize: options.metaSize,
            options: options.render,
            width: Int(width),
            height: Int(height),
            isFullyTransparent: isEmpty,
            rgba: buffer)
    }

    // MARK: - Free-form (bounding box) rendering

    /// Renders the current map view: whatever extent the stylesheet or a
    /// previous `zoom(to:)` call set.
    ///
    /// If the map has no extent yet (no zoom call, no `zoom-to-extent` in
    /// the stylesheet), it first zooms to the combined extent of all layers.
    public func render(
        width: Int = 256,
        height: Int = 256,
        scale: Double = 1.0,
        bufferSize: Int? = nil,
        format: ImageFormat = .webp(),
    ) throws -> Data? {
        try render(RenderOptions(
            width: width,
            height: height,
            bufferSize: bufferSize,
            scale: scale,
            skipFullyTransparent: true,
            format: format))
    }

    /// Renders the current map view with the given options.
    public func render(_ options: RenderOptions) throws -> Data? {
        try options.validate()

        mapnik_map_resize(map, Int32(clamping: options.width), Int32(clamping: options.height))
        let previousBuffer = applyBuffer(options.bufferSize)
        defer {
            if let previousBuffer {
                setBufferSize(previousBuffer)
            }
        }
        zoomAllIfUnset()

        var data: UnsafeMutablePointer<UInt8>? = nil
        var size: CUnsignedLong = 0
        var isEmpty = false

        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_render_to_buffer(
                map,
                options.format.typeString,
                options.skipFullyTransparent,
                &data,
                &size,
                &isEmpty,
                errorOut)
        }

        if isEmpty || data == nil || size == 0 {
            return nil
        }
        return dataBuffer(data, size: Int(size))
    }

    /// Renders a geographic bounding box (WGS 84 degrees) into an image.
    ///
    /// The bounding box is projected to Web Mercator, fitted into the image
    /// and rendered. This is the simplest way to produce a map thumbnail or
    /// a static map image of an arbitrary region.
    public func render(
        bounds: BoundingBox,
        width: Int = 800,
        height: Int = 600,
        scale: Double = 1.0,
        bufferSize: Int? = nil,
        format: ImageFormat = .webp(),
    ) throws -> Data? {
        try render(bounds: bounds, options: RenderOptions(
            width: width,
            height: height,
            bufferSize: bufferSize,
            scale: scale,
            skipFullyTransparent: true,
            format: format))
    }

    /// Renders a bounding box with full option control.
    public func render(bounds: BoundingBox, options: RenderOptions) throws -> Data? {
        try options.validate()
        try zoom(to: bounds)
        return try render(options)
    }

    /// Renders the current map view to a file.
    ///
    /// If the map has no extent yet, it first zooms to the layer extent.
    public func renderToFile(
        to url: URL,
        width: Int = 800,
        height: Int = 600,
        scale: Double = 1.0,
        format: ImageFormat = .webp(),
    ) throws {
        try RenderOptions(width: width, height: height, scale: scale, format: format).validate()

        mapnik_map_resize(map, Int32(clamping: width), Int32(clamping: height))
        zoomAllIfUnset()

        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_render_to_file(
                map,
                format.typeString,
                url.path(percentEncoded: false),
                errorOut)
        }
    }

    // MARK: - Vector rendering (cairo)

    /// The cairo vector surface types mapnik's backend supports.
    enum CairoSurfaceType: String, CaseIterable, Sendable {

        case svg
        case pdf
        case postScript = "ps"

    }

    /// Renders the current map view as an SVG document.
    ///
    /// Vector output goes through mapnik's cairo backend and produces vector
    /// output for the layers that support it. If the map has no extent yet,
    /// it first zooms to the layer extent.
    public func renderSVG(scale: Double = 1.0) throws -> Data {
        try renderCairoSurface(.svg, scale: scale)
    }

    /// Renders the current map view as an SVG file.
    public func renderSVG(to url: URL, scale: Double = 1.0) throws {
        try renderCairoSurface(.svg, scale: scale, to: url)
    }

    /// Renders the current map view as a PDF document.
    ///
    /// Like `renderSVG`, vector output goes through mapnik's cairo backend;
    /// PDF suits print/graphics workflows. If the map has no extent yet, it
    /// first zooms to the layer extent.
    ///
    /// - Parameter scale: Scale factor for symbolizer sizes (`2.0` produces
    ///   twice-size labels and line widths).
    /// - Returns: The PDF document bytes.
    /// - Throws: `MapnikError.renderingFailed` when rendering failed.
    public func renderPDF(scale: Double = 1.0) throws -> Data {
        try renderCairoSurface(.pdf, scale: scale)
    }

    /// Renders the current map view as a PDF file.
    public func renderPDF(to url: URL, scale: Double = 1.0) throws {
        try renderCairoSurface(.pdf, scale: scale, to: url)
    }

    /// Renders the current map view as a PostScript document.
    ///
    /// Like `renderPDF`, but emitting PostScript (`.ps`) output.
    public func renderPostScript(scale: Double = 1.0) throws -> Data {
        try renderCairoSurface(.postScript, scale: scale)
    }

    /// Renders the current map view as a PostScript file.
    public func renderPostScript(to url: URL, scale: Double = 1.0) throws {
        try renderCairoSurface(.postScript, scale: scale, to: url)
    }

    // MARK: - Private (cairo)

    /// Renders a cairo vector surface into memory (via a temporary file,
    /// since mapnik exposes no to-buffer variant).
    private func renderCairoSurface(_ surface: CairoSurfaceType, scale: Double) throws -> Data {
        guard scale > 0, scale.isFinite else {
            throw MapnikError.invalidInput("scale must be positive and finite, got \(scale)")
        }

        zoomAllIfUnset()

        var data: UnsafeMutablePointer<UInt8>? = nil
        var size: CUnsignedLong = 0

        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_render_to_cairo_buffer(map, scale, surface.rawValue, &data, &size, errorOut)
        }

        guard let data, size > 0 else {
            throw MapnikError.renderingFailed("\(surface.rawValue) render produced no output")
        }

        return dataBuffer(data, size: Int(size))
    }

    /// Renders a cairo vector surface to a file.
    private func renderCairoSurface(_ surface: CairoSurfaceType, scale: Double, to url: URL) throws {
        guard scale > 0, scale.isFinite else {
            throw MapnikError.invalidInput("scale must be positive and finite, got \(scale)")
        }

        zoomAllIfUnset()

        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_render_to_cairo_file(
                map,
                scale,
                surface.rawValue,
                url.path(percentEncoded: false),
                errorOut)
        }
    }

    // MARK: - XML serialization

    /// Serializes the current map — with any runtime modifications (SRS
    /// changes, layer visibility, buffer size, zoom state) — back to Mapnik
    /// XML.
    ///
    /// Useful for style debugging (see what a loaded stylesheet actually
    /// contains) and server-side preprocessing of generated XML.
    ///
    /// - Parameter explicitDefaults: When true, the output carries every
    ///   style/layer attribute even when it equals mapnik's default, which
    ///   makes the serialization more explicit for round-tripping into
    ///   other tools.
    /// - Returns: The Mapnik XML document.
    /// - Throws: `MapnikError.renderingFailed` when serialization failed.
    public func saveXML(explicitDefaults: Bool = false) throws -> String {
        var slot: UnsafeMutablePointer<CChar>? = nil
        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            if let pointer = mapnik_map_save_xml(map, explicitDefaults, errorOut) {
                slot = pointer
                return true
            }
            return false
        }

        guard let pointer = slot else {
            throw MapnikError.renderingFailed("map XML serialization produced no output")
        }

        defer { mapnik_free_string(pointer) }

        return String(cString: pointer)
    }

    /// Serializes the current map back to a Mapnik XML file, replacing the
    /// file if it exists. See ``saveXML(explicitDefaults:)``.
    ///
    /// - Throws: `MapnikError.renderingFailed` when serialization or writing
    ///   failed.
    public func saveXML(to url: URL, explicitDefaults: Bool = false) throws {
        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_save_xml_to_file(
                map,
                explicitDefaults,
                url.path(percentEncoded: false),
                errorOut)
        }
    }

    // MARK: - Map view control

    /// The map's projection string.
    ///
    /// A PROJ.4 string or an EPSG code like `"epsg:3857"` (Web Mercator) or
    /// `"epsg:4326"` (WGS 84 geographic), as set by the stylesheet's `@srs`
    /// attribute or `setSRS`. Tile rendering (`renderTile`) always renders
    /// Web Mercator XYZ tiles; free-form rendering (`render`,
    /// `zoom(to:)`) happens in this SRS.
    public var srs: String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = mapnik_map_get_srs(map, &buffer, Int32(buffer.count))
        guard length >= 0 else {
            return ""
        }

        // Truncation (length >= buffer count) is practically impossible for
        // projection strings; return what fits either way.
        let bytes = buffer.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// Sets the map's projection string.
    ///
    /// A PROJ.4 string or an EPSG code (e.g. `"epsg:3857"`, `"epsg:4326"`).
    /// Existing layer extents are re-interpreted against the new SRS, so set
    /// this right after creating the map and before zooming.
    ///
    /// - Throws: `MapnikError.renderingFailed` if the projection string is
    ///   invalid.
    public func setSRS(_ srs: String) throws {
        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_set_srs(map, srs, errorOut)
        }
    }

    /// Zooms the map so the given bounding box fits the current dimensions.
    ///
    /// The box (WGS 84 degrees) is reprojected to the map's SRS first, which
    /// works for Web Mercator maps as well as for maps with any other
    /// projection. Note that the map itself is not resized; the box is
    /// fitted into whatever dimensions the map currently has.
    public func zoom(to bounds: BoundingBox) throws {
        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_zoom_to_wgs84_box(
                map,
                bounds.southWest.x,
                bounds.southWest.y,
                bounds.northEast.x,
                bounds.northEast.y,
                errorOut)
        }
    }

    /// Zooms the map to the combined extent of all layers.
    ///
    /// - Throws: `MapnikError.renderingFailed` if no layer has an extent
    ///   (e.g. all layers are empty).
    public func zoomAll() throws {
        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_zoom_all(map, errorOut)
        }
    }

    /// Sets the buffer (padding) in pixels used for subsequent renders.
    public func setBufferSize(_ pixels: Int) {
        mapnik_map_set_buffer_size(map, Int32(clamping: pixels))
    }

    /// The current buffer size in pixels.
    public var bufferSize: Int {
        Int(mapnik_map_buffer_size(map))
    }

    /// The current map dimensions in pixels.
    public var size: (width: Int, height: Int) {
        (Int(mapnik_map_width(map)), Int(mapnik_map_height(map)))
    }

    // MARK: - Layers

    /// The names of all layers defined by the stylesheet, in render order.
    public var layerNames: [String] {
        let count = mapnik_map_layer_count(map)
        guard count > 0 else {
            return []
        }

        return (0 ..< count).compactMap { index in
            mapnik_map_layer_name(map, Int32(index)).map { String(cString: $0) }
        }
    }

    /// Shows or hides a layer by index (render order, 0-based).
    ///
    /// - Returns: `false` if the index is out of range.
    @discardableResult
    public func setLayerVisible(_ index: Int, visible: Bool) -> Bool {
        mapnik_map_set_layer_visible(map, Int32(clamping: index), visible)
    }

    /// The visibility of the layer at `index`, or `nil` if out of range.
    public func layerVisible(_ index: Int) -> Bool? {
        guard index >= 0 else {
            return nil
        }

        var visible = false
        guard mapnik_map_layer_visible(map, Int32(index), &visible) else {
            return nil
        }

        return visible
    }

    /// The geographic envelope of the layer at `index`.
    ///
    /// The box is in the layer's own SRS (see ``layerSRS(_:)``), as computed
    /// from the layer's datasource — the same value `zoomAll` unions over.
    ///
    /// - Parameter index: The layer index, in render order, 0-based.
    /// - Throws: `MapnikError.renderingFailed` when the index is out of
    ///   range or the layer has no usable envelope.
    public func layerEnvelope(_ index: Int) throws -> BoundingBox {
        guard index >= 0 else {
            throw MapnikError.invalidInput("layer index must not be negative, got \(index)")
        }

        var minX: Double = 0
        var minY: Double = 0
        var maxX: Double = 0
        var maxY: Double = 0

        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_layer_envelope(
                map,
                Int32(clamping: index),
                &minX,
                &minY,
                &maxX,
                &maxY,
                errorOut)
        }

        return BoundingBox(
            southWest: Coordinate3D(x: minX, y: minY, projection: .noSRID),
            northEast: Coordinate3D(x: maxX, y: maxY, projection: .noSRID))
    }

    /// The layer's projection string.
    ///
    /// A PROJ.4 string or an EPSG code, as set by the stylesheet's layer
    /// `@srs` attribute. `nil` when the index is out of range.
    public func layerSRS(_ index: Int) -> String? {
        guard index >= 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: 256)
        let length = mapnik_map_layer_srs(map, Int32(index), &buffer, Int32(buffer.count))
        guard length >= 0 else {
            return nil
        }

        // Truncation (length >= buffer count) is practically impossible for
        // projection strings; return what fits either way.
        let bytes = buffer.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// Whether the layer at `index` is queryable (responds to feature
    /// queries), or `nil` if out of range.
    public func layerQueryable(_ index: Int) -> Bool? {
        guard index >= 0 else {
            return nil
        }

        var queryable = false
        guard mapnik_map_layer_queryable(map, Int32(index), &queryable) else {
            return nil
        }

        return queryable
    }

    /// Whether the layer at `index` renders at the given scale denominator
    /// (respecting the layer's min/max scale denominators and visibility),
    /// or `nil` if out of range.
    public func layerVisible(_ index: Int, atScaleDenominator scaleDenominator: Double) -> Bool? {
        guard index >= 0 else {
            return nil
        }

        var visible = false
        guard mapnik_map_layer_visible_at_scale(map, Int32(index), scaleDenominator, &visible) else {
            return nil
        }

        return visible
    }

    /// Zooms the map so the layer's envelope fits the current dimensions.
    ///
    /// The envelope (in the layer's SRS) is reprojected to the map's SRS
    /// first, which works for Web Mercator maps as well as for maps with any
    /// other projection. Note that the map itself is not resized; the box is
    /// fitted into whatever dimensions the map currently has.
    ///
    /// - Parameter index: The layer index, in render order, 0-based.
    /// - Throws: `MapnikError.renderingFailed` when the index is out of
    ///   range, the layer has no usable envelope, or the reprojection fails.
    public func zoomToLayer(_ index: Int) throws {
        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_zoom_to_layer(map, Int32(clamping: index), errorOut)
        }
    }

    // MARK: - PNG palette rendering

    /// Renders the current map view as a palette-quantized PNG.
    ///
    /// Pass at most 256 packed ARGB colors (`0xAARRGGBB`); the image is
    /// quantized to those, which reduces tile sizes dramatically for flat
    /// cartography. Colors outside the palette still render through
    /// mapnik's internal error-diffusion.
    public func renderPNG256(
        colors: [UInt32],
        width: Int = 256,
        height: Int = 256,
        scale: Double = 1.0,
    ) throws -> Data? {
        try renderPNG256(colors: colors, options: RenderOptions(
            width: width,
            height: height,
            scale: scale,
            skipFullyTransparent: true,
            format: .png256))
    }

    /// Renders a palette-quantized PNG with full option control.
    public func renderPNG256(colors: [UInt32], options: RenderOptions) throws -> Data? {
        try options.validate()
        guard colors.isEmpty == false, colors.count <= 256 else {
            throw MapnikError.invalidInput("palette must contain 1...256 colors, got \(colors.count)")
        }

        mapnik_map_resize(map, Int32(clamping: options.width), Int32(clamping: options.height))
        let previousBuffer = applyBuffer(options.bufferSize)
        defer {
            if let previousBuffer {
                setBufferSize(previousBuffer)
            }
        }
        zoomAllIfUnset()

        var data: UnsafeMutablePointer<UInt8>? = nil
        var size: CUnsignedLong = 0
        var isEmpty = false

        var creationError: String?
        let palette: OpaquePointer? = colors.withUnsafeBufferPointer { buffer in
            var errorOut: UnsafeMutablePointer<CChar>? = nil
            defer {
                if let pointer = errorOut {
                    creationError = String(cString: pointer)
                    mapnik_free_string(pointer)
                }
            }
            return mapnik_palette_create(buffer.baseAddress, Int32(colors.count), &errorOut)
        }

        guard let palette else {
            throw MapnikError.renderingFailed(creationError ?? "could not create palette")
        }

        defer { mapnik_palette_destroy(palette) }

        try CErrors.withError(MapnikError.renderingFailed) { errorOut in
            mapnik_map_render_to_buffer_with_palette(
                map,
                palette,
                &data,
                &size,
                &isEmpty,
                errorOut)
        }

        if isEmpty || data == nil || size == 0 {
            return nil
        }
        return dataBuffer(data, size: Int(size))
    }

    // MARK: - Private

    /// Zooms to the layer extent if the map has no usable extent yet.
    ///
    /// A freshly loaded map has an inverted, empty extent; rendering it
    /// would always produce a fully transparent image.
    func zoomAllIfUnset() {
        var minX: Double = 0
        var minY: Double = 0
        var maxX: Double = 0
        var maxY: Double = 0
        mapnik_map_get_extent(map, &minX, &minY, &maxX, &maxY)
        if (minX < maxX) == false || (minY < maxY) == false {
            try? zoomAll()
        }
    }

    /// Applies an optional buffer override, returning the previous buffer
    /// size (or `nil` when nothing was overridden) for the caller to restore
    /// after the render — every render call site does, so renders stay
    /// independent of each other.
    @discardableResult
    private func applyBuffer(_ buffer: Int?) -> Int? {
        guard let buffer else {
            return nil
        }

        let previous = mapnik_map_buffer_size(map)
        mapnik_map_set_buffer_size(map, Int32(clamping: buffer))
        return Int(previous)
    }

    /// Wraps a C-allocated buffer into a `Data` that frees it with
    /// `mapnik_free_buffer` when released.
    private func dataBuffer(_ pointer: UnsafeMutablePointer<UInt8>?, size: Int) -> Data {
        guard let pointer, size > 0 else {
            return Data()
        }

        return Data(
            bytesNoCopy: pointer,
            count: size,
            deallocator: .custom { buffer, _ in
                mapnik_free_buffer(buffer)
            })
    }

    /// Runs `body` with the underlying C map pointer.
    ///
    /// Intended for tests and internal plumbing; not part of the public API.
    func withMapPointer(_ body: (OpaquePointer) throws -> Void) throws {
        try body(map)
    }

}
