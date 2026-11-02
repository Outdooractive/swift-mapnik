import Foundation
import GISTools

extension BoundingBox {

    /// `true` when the box is expressed in angular (lon/lat degrees)
    /// coordinates, or carries no projection at all (in which case degrees are
    /// assumed).
    var isGeographic: Bool {
        switch projection.kind {
        case .geographic, .undefined:
            true
        case .geocentric, .planar:
            false
        }
    }

    /// Returns the box in WGS 84 degrees.
    ///
    /// A box without a projection is assumed to already be in degrees; a box
    /// in another geographic CRS is reprojected.
    ///
    /// - Throws: `MapnikError.invalidInput` when the box is in a planar or
    ///   geocentric projection and would need an explicit conversion.
    func wgs84() throws -> BoundingBox {
        if isGeographic {
            return self
        }

        throw MapnikError.invalidInput(
            "bounding box must be in WGS 84 degrees (EPSG:4326), got \(projection)")
    }

    /// Throws unless the box is in angular (lon/lat degrees) coordinates.
    ///
    /// Mapnik's `zoom`/`render(bounds:)` APIs take degrees; a box in another
    /// projection would be silently reinterpreted as degrees, producing a NaN
    /// extent and an empty or wildly wrong image.
    func validateGeographic() throws {
        guard isGeographic else {
            throw MapnikError.invalidInput(
                "bounding box must be in WGS 84 degrees (EPSG:4326), got \(projection)")
        }
    }

}
