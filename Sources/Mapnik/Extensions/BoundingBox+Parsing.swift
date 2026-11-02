import Foundation
import GISTools

extension BoundingBox {

    /// Parses bounding boxes of the form `"x1,y1,x2,y2"` (minLon, minLat,
    /// maxLon, maxLat), tolerating surrounding whitespace.
    ///
    /// Returns `nil` if the string does not contain exactly four parseable,
    /// finite numbers or if the minimum values are not smaller than the
    /// maximum ones. The result is always in EPSG:4326.
    ///
    /// Parsing is positional: a string with five fields where one is
    /// unparseable is rejected rather than silently dropping the bad field and
    /// shifting the remaining values into the wrong slots.
    public init?(parsing string: some StringProtocol) {
        let components = string.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 4 else {
            return nil
        }

        let values = components.map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard values.allSatisfy({ $0 != nil }) else {
            return nil
        }

        let numbers = values.compactMap(\.self)
        guard numbers.allSatisfy(\.isFinite) else {
            return nil
        }

        let xMin = numbers[0]
        let yMin = numbers[1]
        let xMax = numbers[2]
        let yMax = numbers[3]

        guard xMin < xMax, yMin < yMax else {
            return nil
        }

        self.init(
            southWest: Coordinate3D(latitude: yMin, longitude: xMin),
            northEast: Coordinate3D(latitude: yMax, longitude: xMax))
    }

}
