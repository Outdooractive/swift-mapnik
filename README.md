[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FOutdooractive%2Fswift-mapnik%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Outdooractive/swift-mapnik)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FOutdooractive%2Fswift-mapnik%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Outdooractive/swift-mapnik)
[![](https://img.shields.io/github/license/Outdooractive/swift-mapnik)](https://github.com/Outdooractive/swift-mapnik/blob/main/LICENSE)
[![](https://img.shields.io/github/v/release/Outdooractive/swift-mapnik?sort=semver&display_name=tag)](https://github.com/Outdooractive/swift-mapnik/releases) [![](https://img.shields.io/github/release-date/Outdooractive/swift-mapnik?display_date=published_at)](https://github.com/Outdooractive/swift-mapnik/releases)
[![](https://img.shields.io/github/issues/Outdooractive/swift-mapnik)](https://github.com/Outdooractive/swift-mapnik/issues) [![](https://img.shields.io/github/issues-pr/Outdooractive/swift-mapnik)](https://github.com/Outdooractive/swift-mapnik/pulls)

# swift-mapnik

Swift bindings for the [Mapnik](https://mapnik.org/) C++ map rendering toolkit: render map tiles (XYZ scheme) and free-form map images in Web Mercator from Mapnik XML stylesheets, on macOS and Linux.

Output formats include PNG (8/24/32-bit, paletted), JPEG, WebP, TIFF and SVG (via cairo). Geographic types (`Coordinate3D`, `BoundingBox`, `MapTile`) come from the [GISTools](https://github.com/Outdooractive/gis-tools) library, which this package depends on.

## Table of Contents

- [swift-mapnik](#swift-mapnik)
  - [Requirements](#requirements)
  - [Installation with Swift Package Manager](#installation-with-swift-package-manager)
  - [Quick start](#quick-start)
- [Rendering tiles](#rendering-tiles)
- [Free-form rendering](#free-form-rendering)
- [Metatile rendering](#metatile-rendering)
- [Output formats](#output-formats)
- [Palette quantization](#palette-quantization)
- [XML serialization](#xml-serialization)
- [Layers](#layers)
- [Datasource inspection](#datasource-inspection)
- [Feature queries](#feature-queries)
- [Bulk rendering](#bulk-rendering)
- [Global initialization](#global-initialization)
- [Thread-safety](#thread-safety)
- [Documentation](#documentation)
- [Package layout](#package-layout)
- [Tests](#tests)
- [Related packages](#related-packages)
- [Contributing](#contributing)
- [License](#license)
- [Authors](#authors)

## Requirements

This package requires Swift 6.3 or higher and the Mapnik 3.x C++ library with development headers, and compiles on macOS (\>= macOS 15) and Linux. The [GISTools](https://github.com/Outdooractive/gis-tools) dependency is resolved automatically.

### macOS (Homebrew)

```sh
brew install mapnik
```

The build expects Homebrew under `/opt/homebrew` (Apple Silicon). Mapnik's datasource plugins and fonts are picked up from `/opt/homebrew/lib/mapnik/input` and `/opt/homebrew/share/mapnik/fonts`.

### Linux (Debian/Ubuntu)

```sh
sudo apt install libmapnik-dev mapnik-utils fonts-dejavu-core
```

Plugins and fonts are picked up from `/usr/lib/mapnik/3.1/input` and `/usr/share/fonts`. Custom paths can be set via `MapnikConfig.initialize`.

> Note: SwiftPM on Linux needs a Clang-based C++ toolchain. If your environment forces GCC (`CC`/`CXX`), build with `CC=/usr/bin/clang CXX=/usr/bin/clang++ swift build`.

## Installation with Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/Outdooractive/swift-mapnik", from: "1.0.0"),
],
targets: [
    .target(name: "MyTarget", dependencies: [
        .product(name: "Mapnik", package: "swift-mapnik"),
    ]),
]
```

## Quick start

```swift
import Mapnik

let xml = try String(contentsOf: styleURL, encoding: .utf8)
let map = try Mapnik(xml: xml)

// Render a 256×256 WebP tile (XYZ scheme, Web Mercator)
let tile = try map.renderTile(x: 1082, y: 715, z: 11)
try tile?.write(to: outputURL)
```

Stylesheets can also be loaded directly from a file; paths inside the stylesheet (datasource files...) are then resolved relative to the stylesheet's location, matching mapnik's command-line behavior:

```swift
let map = try Mapnik(xmlFile: styleURL)
```

# Rendering tiles

[Implementation](Sources/Mapnik/Mapnik.swift)

```swift
let map = try Mapnik(xml: xml)                       // loads a stylesheet

// XYZ tile, format and options configurable
let webp = try map.renderTile(x: 8656, y: 5722, z: 14, format: .webp(quality: 85))
let png  = try map.renderTile(MapTile(x: 8, y: 5, z: 4), format: .png256)
let hiDPI = try map.renderTile(x: 8656, y: 5722, z: 14, scale: 2.0)  // @2x

// nil = tile is fully transparent (no features painted)
if let image = try map.renderTile(tile) { ... }
```

A `Mapnik` instance wraps a loaded Mapnik XML stylesheet; tile rendering temporarily reconfigures the underlying map (size and extent) and restores the previous state afterwards, so repeated renders are independent of each other. `renderTileToFile` writes directly to a file.

# Free-form rendering

[Implementation](Sources/Mapnik/Mapnik.swift)

```swift
// Arbitrary region, WGS 84 bounding box, projected to the map's SRS
let image = try map.render(bounds: germany, width: 1024, height: 768)

// Or control the view yourself
try map.zoom(to: germany)
let current = try map.render(width: 800, height: 600)
try map.zoomAll()                                    // fit all layers
```

The map's SRS defaults to the stylesheet's `@srs` attribute (Web Mercator in the examples above). It can be read and changed at runtime; the bounding box of `zoom(to:)` and `render(bounds:)` is always WGS 84 degrees and is reprojected to the map's SRS for you:

```swift
let map = try Mapnik(xml: xml)
#expect(map.srs == "epsg:3857")

try map.setSRS("epsg:4326")                          // render in geographic coordinates
let image = try map.render(bounds: germany, width: 1024, height: 768)
```

SVG, PDF and PostScript output go through mapnik's cairo backend, producing vector output for the layers that support it:

```swift
let svg = try map.renderSVG(scale: 2.0)              // Data
try map.renderSVG(to: url)

let pdf = try map.renderPDF()                        // Data ("%PDF-" magic)
try map.renderPDF(to: url)                           // print/graphics workflows
try map.renderPostScript(to: url)                    // .ps output
```

# Metatile rendering

[Implementation](Sources/Mapnik/Metatile.swift)

A metatile is a block of N×N XYZ tiles rendered as one image in a single pass. This halves (quarters, ...) the number of datasource queries — a 4×4 metatile needs one query per layer instead of 16 — and lets mapnik's label placement (collision detection) see the whole block, so labels no longer clip at tile edges inside the block. Tile servers use this technique to keep label rendering consistent across tile boundaries.

```swift
// Render a 4×4 block starting at tile (1080, 712)
let metatile = try map.renderMetatile(origin: MapTile(x: 1080, y: 712, z: 11), metaSize: 4)

// Crop individual tiles out of the block on demand (WebP by default)
let tile = try metatile?.tile(at: MapTile(x: 1082, y: 715, z: 11))
try tile?.write(to: outputURL)

// Or by offset within the block
let byOffset = try metatile?.tile(dx: 2, dy: 3, format: .png256)
```

`MetatileOptions` controls the block size (`metaSize`, 1...16) and the per-tile `RenderOptions` (tile size, scale factor, format, buffer). The rendered block is returned as a `MetatileRendered` holding the raw RGBA pixels; crop tiles out of it, then drop it. A fully transparent block returns `nil`, like `renderTile`.

Like `renderTile`, the block is always rendered in Web Mercator XYZ geometry regardless of the map's SRS. The buffer (padding) applies around the whole block, not per tile — raise `bufferSize` if edge padding matters for your style.

# Output formats

[Implementation](Sources/Mapnik/RenderOptions.swift)

Formats are expressed as `ImageFormat` values, mapped to mapnik's image type strings (`webp:quality=80` etc., see the [mapnik image-io docs](https://github.com/mapnik/mapnik/wiki/image-io)):

```swift
.png()                          // 32-bit PNG
.png(colors: 64)                // paletted PNG with at most 64 colors
.png256                         // 8-bit paletted PNG
.jpeg(quality: 85)
.webp(quality: 80, alphaQuality: 90, lossless: true)
.tiff
.svg                            // via Mapnik.renderSVG; PDF/PS via renderPDF/renderPostScript
```

`RenderOptions` bundles size, buffer (padding), scale factor and format; `nil` buffer uses the stylesheet's buffer.

# Palette quantization

[Implementation](Sources/Mapnik/Mapnik.swift)

Passing an explicit palette reuses the exact same color table across tiles, which helps tile caches stay small and visually consistent:

```swift
let data = try map.renderPNG256(colors: [0xFFFF0000, 0xFF000000, 0xFFFFFFFF])
```

Colors outside the palette still render through mapnik's internal error-diffusion.

# XML serialization

[Implementation](Sources/Mapnik/Mapnik.swift)

The current map — with any runtime modifications (SRS changes, layer visibility, buffer size, zoom state) — can be serialized back to Mapnik XML. Useful for style debugging (see what a loaded stylesheet actually contains) and server-side preprocessing of generated XML:

```swift
let map = try Mapnik(xml: xml)
let regenerated = try map.saveXML()                     // String
try map.saveXML(to: debugURL)                           // or to a file
let explicit = try map.saveXML(explicitDefaults: true)  // carry all attributes
```

Note: mapnik's serializer omits inactive layers from the output; hidden layers do not round-trip.

# Layers

[Implementation](Sources/Mapnik/Mapnik.swift)

```swift
map.layerNames                        // ["water", "roads", "labels"]
map.setLayerVisible(2, visible: false)
```

Each layer also carries its own properties, in the layer's own SRS:

```swift
let envelope = try map.layerEnvelope(2)              // BoundingBox in the layer SRS
try map.zoomToLayer(2)                               // fit the map to one layer
let srs = map.layerSRS(2)                            // "epsg:3857" or a PROJ.4 string
let queryable = map.layerQueryable(2)                // responds to feature queries?
let visible = map.layerVisible(2, atScaleDenominator: 10_000)
```

# Datasource inspection

[Implementation](Sources/Mapnik/MapnikDatasource.swift)

`MapnikDatasource` creates a datasource directly from the name/value parameters of a Mapnik XML `<Datasource>` block (or a CartoCSS project's layer `Datasource` object). `inspect(maxFeatures:srs:fieldFilter:)` returns a `DatasourceInfo`: the datasource type, geometry type, extents (native + geographic), the field list and a small sample of features with typed attributes — mirroring what TileMill's datasource inspection returned to the layer editor:

```swift
let datasource = try MapnikDatasource(parameters: [
    ("type", "geojson"),
    ("file", "/path/to/data.geojson"),
])
let info = try datasource.inspect(maxFeatures: 10, srs: "+init=epsg:3857")

// Trim wide tables down to the attributes the editor shows:
let focused = try datasource.inspect(
    maxFeatures: 10,
    srs: "+init=epsg:3857",
    fieldFilter: ["name", "population"])
```

# Feature queries

[Implementation](Sources/Mapnik/FeatureQuery.swift)

Interactive maps need hit-testing: what is at this coordinate? `queryPoint` queries a map layer at a geographic coordinate (or in raw map SRS coordinates), honoring the layer's visibility rules like a render; `MapnikDatasource.queryBox` queries a standalone datasource in a bounding box. Both return GISTools `Feature` values with the feature id, its attributes and its geometry:

```swift
let map = try Mapnik(xml: xml)
let features = try map.queryPoint(at: Coordinate3D(latitude: 52.5, longitude: 13.4), layerIndex: 2)
for feature in features {
    print(feature.properties)            // ["name": "Europe", "population": 83000000, ...]
    print(feature.geometry.asJson)       // GeoJSON geometry, in the map SRS
    print(feature.boundingBox ?? "n/a")  // calculated from the geometry
}

// Or query a datasource directly in its native SRS:
let datasource = try MapnikDatasource(parameters: [("type", "geojson"), ("file", "/path/to/data.geojson")])
let info = try datasource.inspect(maxFeatures: 1, srs: "+init=epsg:4326")
let inBox = try datasource.queryBox(info.extent, maxFeatures: 100)
```

Note: features without a geometry (attributes-only hits) are dropped from query results, since GISTools `Feature` requires one. Geometry samples for inspection UIs come from `queryBox` (which decodes geometries); `inspect` stays about schema, extents, fields and typed attribute samples (`[String: JSONValue]`).

# Bulk rendering

[Implementation](Sources/Mapnik/TileSequence.swift)

`TileSequence`/`TileGenerator` enumerate all tiles intersecting a bounding box across a zoom range; `MapnikPool` amortizes map creation; `WorkQueue` renders with bounded concurrency:

```swift
let germany = BoundingBox(
    southWest: Coordinate3D(latitude: 47.2, longitude: 5.9),
    northEast: Coordinate3D(latitude: 55.0, longitude: 15.0))

let pool = try MapnikPool(factory: { try Mapnik(xml: xml) },
                          initialSize: 4,
                          maxPoolSize: 16)

var generator = TileGenerator(TileSequence(bounds: germany, zoomRange: 10 ... 13))
let queue = WorkQueue<MapTile, Data>(
    maxConcurrency: 4,
    fetchWork: { generator.next() },
    processWork: { tile in
        let map = try pool.acquire()
        defer { pool.release(map) }
        return try map.renderTile(tile)
    },
    onResult: { tile, data in
        guard let data else { return }              // skipped: empty tile
        try data.write(to: tileURL(tile))
    })

try await queue.start()
```

For bulk pipelines, metatile grouping cuts the number of datasource queries by `metaSize`² and fixes label clipping at tile edges. `MetatileSequence`/`MetatileGenerator` yield aligned `metaSize` × `metaSize` blocks (tiles aligned to the metatile grid, like tile servers group work), and each block's `tiles` list contains only the tiles that intersect the bounding box:

```swift
let pool = try MapnikPool(factory: { try Mapnik(xml: xml) },
                          initialSize: 4,
                          maxPoolSize: 16)

var generator = MetatileGenerator(MetatileSequence(bounds: germany, zoomRange: 10 ... 13, metaSize: 4))
let queue = WorkQueue<Metatile, [(MapTile, Data)]>(
    maxConcurrency: 4,
    fetchWork: { generator.next() },
    processWork: { block in
        let map = try pool.acquire()
        defer { pool.release(map) }
        guard let metatile = try map.renderMetatile(block) else {
            return []                               // whole block is transparent
        }
        return block.tiles.compactMap { tile in
            try metatile.tile(at: tile).map { (tile, $0) }
        }
    },
    onResult: { _, results in
        for (tile, data) in results ?? [] {
            try data.write(to: tileURL(tile))
        }
    })

try await queue.start()
```

`TilelistBuilder` turns a set of rendered tiles into the tilelist JSON consumed by tile servers:

```swift
let builder = TilelistBuilder()
builder.add(tile)
let json = ["all": builder.tilelist]
```

# Global initialization

[Implementation](Sources/Mapnik/MapnikConfig.swift)

`Mapnik(xml:...)` lazily initializes the mapnik library with platform default plugin and font paths. Call `MapnikConfig.initialize` first if you need custom paths or want init failures to surface early:

```swift
try MapnikConfig.initialize(plugins: "/path/to/mapnik/input", fonts: "/path/to/fonts")
```

It is safe (and cheap) to call `MapnikConfig.initialize` multiple times; only the first call has an effect.

The font faces registered by `initialize` (recursively scanning the font directory) can be listed to validate a stylesheet against the installed fonts, e.g. `face-name="DejaVu Sans Book"`:

```swift
let fonts = try MapnikConfig.availableFonts()
if !fonts.contains("DejaVu Sans Book") {
    print("style references an unregistered font")
}
```

# Thread-safety

- A `Mapnik` instance must not render concurrently from multiple tasks; mapnik renderers are not thread-safe.
- Creating and destroying map objects touches global mapnik state, so the lifecycle is serialized internally (at the cost of parallel style loading). Rendering itself runs fully parallel and lock-free.
- Use one instance per worker, e.g. via `MapnikPool`, which retires objects after a configurable number of uses to bound memory growth.

# Documentation

Every public symbol carries a doc comment. Browse `Sources/Mapnik/` directly, or generate reference documentation with [DocC](https://www.swift.org/documentation/docc/) after adding the [swift-docc-plugin](https://github.com/swiftlang/swift-docc-plugin):

```sh
swift package generate-documentation
```

# Package layout

```
Sources/Mapnik/           # public API: Mapnik, RenderOptions/ImageFormat,
│                         #   Metatile/MetatileOptions/MetatileRendered,
│                         #   MapnikConfig, MapnikDatasource, TileSequence/
│                         #   TileGenerator + MetatileSequence/Generator,
│                         #   TilelistBuilder, MapnikPool, WorkQueue
├── Extensions/           # GISTools helpers (BoundingBox parsing)
Sources/MapnikC/          # C shim between Swift and the Mapnik C++ toolkit
│                         #   (C++ exceptions → out-params, buffer hand-off)
Tests/MapnikTests/        # Swift Testing: rendering + unit tests
```

# Tests

```sh
swift test                                # requires mapnik (see Requirements)
```

The test fixtures use inline GeoJSON only; no network access or external data is needed.

# Related packages

- [swift-stb-image](https://github.com/Outdooractive/swift-stb-image): Swift wrapper around stb_image/stb_image_write and libwebp for reading and writing PNG, JPG and WebP images
- [gis-tools](https://github.com/Outdooractive/gis-tools): GIS tools for Swift, including a GeoJSON implementation and many algorithms
- [mvt-tools](https://github.com/Outdooractive/mvt-tools): Vector tiles reader/writer for Swift
- [swift-carto](https://github.com/Outdooractive/swift-carto): A Swift port of Mapbox's carto compiler — compiles CartoCSS stylesheets into the Mapnik XML consumed by this package

# Contributing

Please [create an issue](https://github.com/Outdooractive/swift-mapnik/issues) or [open a pull request](https://github.com/Outdooractive/swift-mapnik/pulls) with a fix or enhancement.

# License

MIT. The Mapnik C++ library itself is LGPL; these bindings link against it dynamically at runtime. The test fixtures use inline GeoJSON only.

# Authors

Thomas Rasch, Outdooractive