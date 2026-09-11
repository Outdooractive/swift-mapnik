# AGENTS.md

# swift-mapnik — Swift bindings for the Mapnik C++ map rendering toolkit

Swift bindings for the [Mapnik](https://mapnik.org/) C++ toolkit: render
map tiles (XYZ scheme) and free-form map images in Web Mercator from Mapnik
XML stylesheets, on macOS and Linux. Output formats include PNG
(8/24/32-bit, paletted), JPEG, WebP, TIFF and SVG (via cairo).

Mapnik's object model is exposed through a small C shim (`MapnikC`) and a
Swift façade (`Mapnik`): C++ exceptions never cross the boundary, every
entry point reports errors through an out-parameter, and the Swift layer
turns those into thrown `MapnikError` values. The lifecycle (map
create/load/destroy) touches global mapnik state and is serialized
internally on both the C and the Swift side; rendering itself stays
parallel and lock-free.

## Products

- **`Mapnik`** — the library target: the `Mapnik` map/render entry point,
  `RenderOptions`/`ImageFormat`, `MapnikConfig`, datasource inspection,
  tile enumeration, pooling and work queue plumbing.
- **`MapnikC`** — the C/C++ shim target (`Sources/MapnikC/`): C ABI wrappers
  around mapnik objects (`mapnik_map_t`, `mapnik_datasource_t`,
  `mapnik_palette_t`), buffer/string ownership hand-off
  (`mapnik_free_buffer`/`mapnik_free_string`) and error out-parameters.
  Swift code never includes mapnik C++ headers directly.

## Key source areas

```
Sources/Mapnik/
├── Mapnik.swift         # public entry point: stylesheet loading, tile
│                        #   rendering, free-form rendering, SVG/PDF/PS,
│                        #   layers, palettes, metatile rendering, XML round trip
├── Metatile.swift       # Metatile block descriptor, MetatileOptions,
│                        #   MetatileRendered (crop + encode from raw RGBA)
├── RenderOptions.swift  # ImageFormat (mapnik type strings) + RenderOptions
├── MapnikConfig.swift   # one-time global init (plugin + font paths)
├── MapnikDatasource.swift # datasource from parameters + inspect() → DatasourceInfo
├── MapnikError.swift    # error type bridging the C error strings
├── MapnikPool.swift     # thread-safe pool with per-object use limits
├── TileSequence.swift   # TileSequence (tiles ∩ bbox across zooms) +
│                        #   TileGenerator (thread-safe shared cursor) +
│                        #   MetatileSequence/MetatileGenerator (aligned
│                        #   metatile blocks for bulk rendering)
├── TilelistBuilder.swift # tilelist JSON (zoom → row → [minX, maxX] ranges)
├── WorkQueue.swift      # actor with bounded concurrency for bulk rendering
└── Extensions/          # GISTools helpers (BoundingBox "x1,y1,x2,y2" parsing)
Sources/MapnikC/         # C shim: mapnik_c.cpp + include/mapnik_c.h
Tests/MapnikTests/       # Swift Testing: rendering + unit tests
```

- **`Mapnik.swift`** — the central public entry point. Tile rendering
  temporarily reconfigures the underlying map (resize + zoom) and restores
  the previous state afterwards (mapnik's feature_style_processor always
  queries with the map's own extent). Fully transparent results return
  `nil` instead of an encoded empty image. Renders take `RenderOptions`;
  formats map to mapnik's image type strings (`webp:quality=80`, …).
  Layer accessors expose per-layer envelopes/SRS/queryable state and
  `zoomToLayer`; feature queries expose hit-testing.
- **`MapnikConfig.swift`** — process-wide one-time initialization:
  registers datasource input plugins and fonts. Lazy platform defaults
  apply when `Mapnik(xml:...)` is used directly; call `MapnikConfig.initialize`
  first for custom paths. `availableFonts()` enumerates the registered
  font faces (through `mapnik_available_fonts`, NUL-separated transfer).
- **`MapnikDatasource.swift`** — builds a datasource from the same
  name/value parameters a Mapnik XML `<Datasource>` block carries, and
  inspects it (type, geometry type, extents, fields, typed attribute
  samples, field filtering) the way TileMill's layer editor did. Nothing
  here renders.
- **`FeatureQuery.swift`** — feature hit-testing: `Mapnik.queryPoint`
  (map layer, WGS 84 or map-SRS coordinates) and
  `MapnikDatasource.queryBox` (datasource, native SRS). Returns GISTools
  `Feature` values (WKB decoded through `WKBCoder`); geometry-less hits
  are dropped.
- **`MapnikPool.swift`** — thread-safe object pool; objects are retired
  after `maxUsesPerObject` uses to bound memory growth. `acquire` throws
  when the pool is exhausted (it never blocks).
- **`WorkQueue.swift`** — actor pulling work from `fetchWork` with bounded
  `processWork` concurrency, results delivered to `onResult` in completion
  order; cooperatively cancellation-aware. Glue between `TileGenerator`
  and `MapnikPool`.
- **`TilelistBuilder.swift`** — accumulates tiles and emits the tilelist
  JSON schema consumed by tile servers (`{ "all": { "14": { "8656":
  [[5722, 5730]] } } }`).

## Mapnik semantics notes

- The installed mapnik library is built with the cairo backend (headers
  gate the cairo API behind `HAVE_CAIRO`; the shim defines it before
  including any mapnik headers).
- Tiles are rendered through temporary map resize + zoom with a
  `MapStateGuard` restore, because mapnik 3.x's feature_style_processor
  always queries with the map's own extent — there is no const tile path.
- Retina/scale rendering: the map is resized to the *device* pixel size and
  `scale_factor` only boosts symbolizer sizes. mapnik's agg_renderer maps
  the extent to the map's own dimensions regardless of scale factor, so
  sizing only the image renders at the wrong resolution.
- Metatiles (`renderMetatile`) render a `metaSize`² tile block in one pass
  (one datasource query per layer) and return the raw premultiplied RGBA
  buffer; tiles are cropped + encoded from it on demand via
  `mapnik_image_crop_encode`.
- Buffer overrides: every render call site snapshots the previous buffer
  size (`applyBuffer` returns it) and restores it afterwards, so an
  explicit `bufferSize` never lingers into subsequent renders.
- Encoded output for fully transparent images is skipped
  (`skipFullyTransparent`); render calls return `nil` in that case.
- `renderPNG256(colors:)` builds a `mapnik::rgba_palette` from up to 256
  packed ARGB (`0xAARRGGBB`) colors; colors outside the palette render
  through mapnik's error-diffusion.
- C-allocated buffers are wrapped into `Data` with a
  `.custom(mapnik_free_buffer)` deallocator — never free them manually.
- The counting datasource (`mapnik_counting_datasource_*` shim calls,
  subclassing `memory_datasource`) exists for query-count assertions in
  tests; a datasource attached via `mapnik_map_use_counting_datasource`
  must be kept alive as long as the map may render.

## Dependencies

- **GISTools** — geographic types (`Coordinate3D`, `BoundingBox`, `MapTile`)
  and projections. The only dependency of the library target; do not add
  more without asking first.
- No third-party frameworks in the C shim.

## Build & test

Builds on macOS (≥ macOS 15, Homebrew mapnik under `/opt/homebrew`) and
Linux (Debian/Ubuntu `libmapnik-dev`, plugins under
`/usr/lib/mapnik/3.1/input`) with Swift 6.3+:

```bash
swift build           # build the library
swift test            # run tests (Swift Testing): rendering + unit tests
```

In the development container `CC` defaults to `gcc`, which rejects Swift's
`-target`/`-fblocks` flags — use the toolchain's clang:
`CC=clang CXX=clang++ swift build`. On Linux the shim needs mapnik's AGG
and cairo headers on the include path (handled in `Package.swift`).

Test fixtures use inline GeoJSON only; no network access or external data
is needed.

## Swift instructions

- DO USE idiomatic Swift 6
- DO write tests for everything you do, use Swift Testing (`import Testing`), not XCTest
- DO ASK if anything is unclear, or you need a decision
- DO add proper Swift DocC code documentation to your code
- DO NOT introduce third-party frameworks without asking first (the library
  target's only dependency is GISTools)
- AVOID force unwraps and force `try` unless it is unrecoverable
- Assume strict Swift concurrency rules are being applied (`Mapnik`,
  `MapnikPool`, `TileGenerator` and `TilelistBuilder` are
  `@unchecked Sendable` because their internal state is lock-protected)

## Code style conventions

4-space indentation, no tabs, DocC documentation, Swift 6 concurrency,
`Sendable` conformance on all model types. Formatting is enforced with
[SwiftFormat](https://github.com/nicklockwood/SwiftFormat) (`.swiftformat`
in the repo root): run `swiftformat Sources Tests --swift-version 6.3`
before finishing. Key rules:

### Spacing

- 4-space indentation, no tabs
- Commas: Left-hugging, space follows. `x, y`
- Binary operators: single-space padding before and after. `a + (b * c)`
- Return arrow tokens: Spaces on both sides. `f() -> T`
- Ranges: spaces on both sides. `1 ... 3`
- Trailing closure: space before opening brace. `function() { ... }`
- Comments: space between delimiters and text. `// comment`
- Trailing whitespace: Never.

### General

- Multiple `if` conditions separated by `,`, not `&&`. `if a == 1, b == 2 {}`
- Use `isNotEmpty` instead of `!isEmpty`
- Left-hugging colons with space after. `let x: [String: String]`
- `struct` by default, `class` only when needed, `actor` for mutable shared state
- `Sendable` conformance on all model types
- `guard let` / `if let` with early returns
- `// MARK:` and `// MARK: -` to organize extensions
- `PascalCase` for types, `camelCase` for everything else
- Put `else` on its own line

### C/C++ shim conventions

- C++ exceptions must never cross the C boundary; catch and report through
  `error_out` strings, freed by the caller via `mapnik_free_string`.
- Buffers handed to Swift are owned by the caller and freed with
  `mapnik_free_buffer`; never return mapnik-internal pointers directly.
- Every public shim function has a DocC-style `///` comment in
  `include/mapnik_c.h` describing ownership and lifetime of returned
  pointers.

## Repository extras

- The test fixtures in `Tests/MapnikTests/` are inline GeoJSON
  (polygons over Europe, a synthetic 2×2 TIFF built from raw bytes) and
  landmark coordinates (Berlin, New York) — no external data files.