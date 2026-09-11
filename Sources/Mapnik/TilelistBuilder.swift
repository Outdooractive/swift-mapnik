import Foundation
import GISTools

/// Builds a compact tilelist describing which tiles exist in a database.
///
/// The output format is the tilelist JSON consumed by tile servers:
///
/// ```json
/// { "all": { "14": { "8656": [[5722, 5730], [5750, 5750]] } } }
/// ```
///
/// i.e. zoom level → tile row → array of inclusive `[minX, maxX]` ranges of
/// contiguous tiles. Rows and zoom levels are emitted in ascending order.
public final class TilelistBuilder: @unchecked Sendable {

    /// z → y → sorted set of x values.
    private struct State {

        // z → y → set of x values
        var tiles: [Int: [Int: Set<Int>]] = [:]
        var count = 0

    }

    private var state = State()
    private let lock = NSLock()

    public init() {}

    /// Adds a single tile to the list.
    public func add(_ tile: MapTile) {
        lock.lock()
        defer { lock.unlock() }
        addUnlocked(tile)
    }

    /// Adds a sequence of tiles, e.g. the output of a render run.
    public func add(_ tiles: some Sequence<MapTile>) {
        lock.lock()
        defer { lock.unlock() }
        for tile in tiles {
            addUnlocked(tile)
        }
    }

    private func addUnlocked(_ tile: MapTile) {
        state.tiles[tile.z, default: [:]][tile.y, default: []].insert(tile.x)
        state.count += 1
    }

    /// The number of tiles added so far.
    public var tileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.count
    }

    /// A value encodable to the tilelist JSON format.
    ///
    /// Encodes as a dictionary keyed by zoom level (as string), each holding
    /// a dictionary keyed by tile row (as string), each holding an array of
    /// `[minX, maxX]` ranges. Wrap it in `["all": builder.tilelist]` to match
    /// the tileserver schema exactly.
    public var tilelist: Tilelist {
        lock.lock()
        defer { lock.unlock() }

        var all: [String: [String: [[Int]]]] = [:]

        for z in state.tiles.keys.sorted() {
            guard let rows = state.tiles[z] else { continue }

            var yRanges: [String: [[Int]]] = [:]
            for y in rows.keys.sorted() {
                guard let sortedX = rows[y]?.sorted(), sortedX.isEmpty == false else {
                    continue
                }

                var ranges: [[Int]] = []
                var rangeStart = sortedX[0]
                var rangeEnd = sortedX[0]

                for x in sortedX.dropFirst() {
                    if x == rangeEnd + 1 {
                        rangeEnd = x
                    }
                    else {
                        ranges.append([rangeStart, rangeEnd])
                        rangeStart = x
                        rangeEnd = x
                    }
                }
                ranges.append([rangeStart, rangeEnd])

                yRanges[String(y)] = ranges
            }

            all[String(z)] = yRanges
        }

        return Tilelist(all: all)
    }

    // MARK: - Codable output

    /// The tilelist in its JSON-ready form.
    public struct Tilelist: Codable, Sendable, Equatable {

        /// zoom level (as string) → tile row (as string) → [minX, maxX] ranges.
        public var all: [String: [String: [[Int]]]]

        public init(all: [String: [String: [[Int]]]]) {
            self.all = all
        }

    }

}
