/// Output formats supported by the mapnik image writers.
///
/// Format options are expressed in the type string passed to mapnik, e.g.
/// `"webp:quality=80"`. See https://github.com/mapnik/mapnik/wiki/image-io.
public enum ImageFormat: Sendable, Hashable {

    /// 32-bit PNG. Options: `colors: 1...256` for paletted output.
    case png(colors: Int? = nil)

    /// 8-bit paletted PNG (at most 256 colors, much smaller output).
    case png256

    /// JPEG. Lossy, no alpha channel.
    case jpeg(quality: Int? = nil)

    /// WebP. Lossy by default, supports alpha.
    case webp(quality: Int? = nil, alphaQuality: Int? = nil, lossless: Bool = false)

    /// Uncompressed TIFF.
    case tiff

    /// SVG output via the cairo backend. Vector output ignores raster-only
    /// options; use `Mapnik.renderSVG(...)` instead of the pixel formats.
    case svg

    /// The mapnik image type string for this format.
    var typeString: String {
        switch self {
        case .png(nil):
            return "png"

        case let .png(.some(colors)):
            return "png:c=\(colors)"

        case .png256:
            return "png256"

        case .jpeg(nil):
            return "jpeg"

        case let .jpeg(.some(quality)):
            return "jpeg:quality=\(quality)"

        case .webp(nil, nil, false):
            return "webp"

        case let .webp(quality, alphaQuality, lossless):
            var parts = ["webp"]
            if let quality {
                parts.append("quality=\(quality)")
            }
            if let alphaQuality {
                parts.append("alpha_quality=\(alphaQuality)")
            }
            if lossless {
                parts.append("lossless=1")
            }
            return parts.joined(separator: ":")

        case .tiff:
            return "tiff"

        case .svg:
            return "svg"
        }
    }

    /// Formats that mapnik can encode into an in-memory buffer.
    /// (SVG is special-cased and handled by the cairo backend.)
    var supportsBufferEncoding: Bool {
        if case .svg = self {
            return false
        }
        return true
    }

}

/// Parameters controlling a render operation.
///
/// All renders are independent: the receiving `Mapnik` instance restores its
/// stylesheet-loaded state after each call, and per-call parameters (size,
/// buffer, format) only affect the produced image.
public struct RenderOptions: Sendable {

    /// Image width in pixels. For tiles this is the tile size.
    public var width: Int

    /// Image height in pixels.
    public var height: Int

    /// Optional buffer (padding) in pixels around the rendered extent.
    /// Larger buffers avoid clipped labels and partially rendered features
    /// at tile edges. When `nil`, the buffer from the stylesheet is used.
    public var bufferSize: Int?

    /// Scale factor for the renderer. `2.0` produces @2x (retina) tiles.
    public var scale: Double

    /// If the rendered image is fully transparent (no features painted),
    /// return `nil` from render calls instead of an encoded empty image.
    public var skipFullyTransparent: Bool

    /// Output format including any format-specific options.
    public var format: ImageFormat

    public init(
        width: Int = 256,
        height: Int = 256,
        bufferSize: Int? = nil,
        scale: Double = 1.0,
        skipFullyTransparent: Bool = true,
        format: ImageFormat = .webp(),
    ) {
        self.width = width
        self.height = height
        self.bufferSize = bufferSize
        self.scale = scale
        self.skipFullyTransparent = skipFullyTransparent
        self.format = format
    }

    /// Default options for a single map tile of the given size.
    public static func tile(
        size: Int = 256,
        format: ImageFormat = .webp(),
    ) -> RenderOptions {
        RenderOptions(width: size, height: size, format: format)
    }

    /// Options for a @2x (retina) tile.
    public static func retinaTile(
        size: Int = 256,
        format: ImageFormat = .webp(),
    ) -> RenderOptions {
        RenderOptions(width: size, height: size, scale: 2.0, format: format)
    }

    func validate() throws {
        guard width > 0, height > 0 else {
            throw MapnikError.invalidInput("width and height must be positive, got \(width)x\(height)")
        }
        guard scale > 0, scale.isFinite else {
            throw MapnikError.invalidInput("scale must be positive and finite, got \(scale)")
        }

        if let bufferSize, bufferSize < 0 {
            throw MapnikError.invalidInput("bufferSize must not be negative, got \(bufferSize)")
        }
        guard format.supportsBufferEncoding else {
            throw MapnikError.invalidInput("format \(format.typeString) requires a dedicated SVG render call")
        }
    }

}
