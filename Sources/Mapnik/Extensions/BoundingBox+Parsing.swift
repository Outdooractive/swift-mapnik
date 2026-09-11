import Foundation
import GISTools

extension BoundingBox {

    /// Parses bounding boxes of the form `"x1,y1,x2,y2"` (minLon, minLat,
    /// maxLon, maxLat), tolerating surrounding whitespace.
    ///
    /// Returns `nil` if the string does not contain exactly four parseable
    /// numbers or if the minimum values are not smaller than the maximum
    /// ones. The result is always in EPSG:4326.
    public init?(parsing string: some StringProtocol) {
        let components = string
            .split(separator: ",")
            .compactMap({ Double($0.trimmingCharacters(in: .whitespaces)) })

        guard components.count == 4 else {
            return nil
        }

        let xMin = components[0]
        let yMin = components[1]
        let xMax = components[2]
        let yMax = components[3]

        guard xMin < xMax, yMin < yMax else {
            return nil
        }

        self.init(
            southWest: Coordinate3D(latitude: yMin, longitude: xMin),
            northEast: Coordinate3D(latitude: yMax, longitude: xMax))
    }

}
