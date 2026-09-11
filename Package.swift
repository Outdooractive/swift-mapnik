// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "swift-mapnik",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "Mapnik",
            targets: ["Mapnik"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Outdooractive/gis-tools.git", from: "2.5.0"),
    ],
    targets: [
        .target(
            name: "MapnikC",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-I/opt/homebrew/include",
                    "-I/opt/homebrew/opt/icu4c/include",
                ], .when(platforms: [.macOS])),
                .unsafeFlags([
                    "-I/usr/include",
                    // mapnik vendors AGG without path prefixes and includes
                    // <agg_*.h>, and its cairo backend includes <cairo.h>.
                    "-I/usr/include/mapnik/agg",
                    "-I/usr/include/cairo",
                ], .when(platforms: [.linux])),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-L/opt/homebrew/opt/icu4c/lib",
                ], .when(platforms: [.macOS])),
                .unsafeFlags([
                    "-L/usr/lib",
                    "-L/usr/local/lib",
                ], .when(platforms: [.linux])),
                // Resolving libmapnik by name (-lmapnik) is broken on
                // case-insensitive filesystems: SwiftPM's own -L products
                // dir contains libMapnik.a (the Swift target archive), and
                // the linker picks it up instead of Homebrew's libmapnik
                // dylib, leaving every mapnik C++ symbol undefined. Pass
                // the dylib path explicitly instead.
                .unsafeFlags([
                    "/opt/homebrew/lib/libmapnik.dylib",
                ], .when(platforms: [.macOS])),
                .linkedLibrary("mapnik", .when(platforms: [.linux])),
                .linkedLibrary("proj"),
                .linkedLibrary("icuuc"),
                .linkedLibrary("icui18n"),
                .linkedLibrary("cairo"),
            ],
        ),
        .target(
            name: "Mapnik",
            dependencies: [
                "MapnikC",
                .product(name: "GISTools", package: "gis-tools"),
            ],
        ),
        .testTarget(
            name: "MapnikTests",
            dependencies: [
                .byName(name: "Mapnik"),
                .product(name: "GISTools", package: "gis-tools"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
