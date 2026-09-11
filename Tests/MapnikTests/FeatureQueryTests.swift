import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Tests for feature queries: point hit-testing on a map layer and box
/// queries on a standalone datasource.
@Suite("Feature queries")
struct FeatureQueryTests {

    // MARK: - Datasource box queries

    @Test
    func `datasource box query returns features with attributes and geometry`() throws {
        let datasource = try MapnikDatasource(parameters: [
            ("type", "geojson"),
            ("inline", Fixtures.geojson),
        ])

        let info = try datasource.inspect(maxFeatures: 1, srs: "+init=epsg:4326")
        let features = try datasource.queryBox(info.extent, maxFeatures: 10)

        #expect(features.count == 1)
        let feature = try #require(features.first)
        #expect(feature.id == .int(1))
        #expect(feature.properties["name"] as? String == "Europe")
    }

    @Test
    func `datasource box query decodes the polygon geometry`() throws {
        let datasource = try MapnikDatasource(parameters: [
            ("type", "geojson"),
            ("inline", Fixtures.geojson),
        ])

        let info = try datasource.inspect(maxFeatures: 1, srs: "+init=epsg:4326")
        let features = try datasource.queryBox(info.extent, maxFeatures: 10)
        let feature = try #require(features.first)

        // The Europe polygon covers lon -10..40, lat 35..70. Coordinates are
        // raw (noSRID), so use them directly.
        let coordinates = feature.geometry.allCoordinates
        #expect(coordinates.isEmpty == false)
        #expect(coordinates.allSatisfy({ $0.latitude >= 34.9 }))
        #expect(coordinates.allSatisfy({ $0.latitude <= 70.1 }))
        #expect(coordinates.allSatisfy({ $0.longitude >= -10.1 }))
        #expect(coordinates.allSatisfy({ $0.longitude <= 40.1 }))
    }

    @Test
    func `datasource box query produces a valid GeoJSON feature`() throws {
        let datasource = try MapnikDatasource(parameters: [
            ("type", "geojson"),
            ("inline", Fixtures.geojson),
        ])

        let info = try datasource.inspect(maxFeatures: 1, srs: "+init=epsg:4326")
        let features = try datasource.queryBox(info.extent, maxFeatures: 10)
        let feature = try #require(features.first)

        let json = feature.asJson
        #expect(json["type"] as? String == "Feature")
        #expect((json["geometry"] as? [String: Sendable])?["type"] as? String == "Polygon")
        #expect(feature.boundingBox != nil)
    }

    @Test
    func `datasource box query returns empty outside the extent`() throws {
        let datasource = try MapnikDatasource(parameters: [
            ("type", "geojson"),
            ("inline", Fixtures.geojson),
        ])

        let features = try datasource.queryBox([0, 0, 1, 1], maxFeatures: 10)
        #expect(features.isEmpty)
    }

    @Test
    func `datasource box query rejects invalid input`() throws {
        let datasource = try MapnikDatasource(parameters: [
            ("type", "geojson"),
            ("inline", Fixtures.geojson),
        ])

        #expect(throws: MapnikError.self) {
            try datasource.queryBox([0, 0, 1], maxFeatures: 10)
        }
        #expect(throws: MapnikError.self) {
            try datasource.queryBox([0, 0, 1, 1], maxFeatures: 0)
        }
        #expect(throws: MapnikError.self) {
            try datasource.queryBox([1, 1, 0, 0], maxFeatures: 10)
        }
    }

    // MARK: - Map point queries

    @Test
    func `map point query finds the polygon at a coordinate inside it`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        // Inside the Europe polygon (Berlin).
        let features = try map.queryPoint(
            at: Coordinate3D(latitude: 52.5, longitude: 13.4),
            layerIndex: 0)
        #expect(features.count == 1)
        #expect(features.first?.properties["name"] as? String == "Europe")
    }

    @Test
    func `map point query returns nothing outside the polygon`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        // South Pacific.
        let features = try map.queryPoint(
            at: Coordinate3D(latitude: -40.0, longitude: -140.0),
            layerIndex: 0)
        #expect(features.isEmpty)
    }

    @Test
    func `map point query works in raw map SRS coordinates`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        // Berlin in Web Mercator.
        let berlin = MapTile(x: 550, y: 335, z: 10).centerCoordinate(projection: .epsg3857)
        let features = try map.queryPoint(
            x: berlin.x,
            y: berlin.y,
            layerIndex: 0)
        #expect(features.count == 1)
    }

    @Test
    func `map point query rejects invalid input`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)

        #expect(throws: MapnikError.self) {
            try map.queryPoint(at: Coordinate3D(latitude: 52.5, longitude: 13.4), layerIndex: 1)
        }
        #expect(throws: MapnikError.self) {
            try map.queryPoint(at: Coordinate3D(latitude: 52.5, longitude: 13.4), layerIndex: -1)
        }
        #expect(throws: MapnikError.self) {
            try map.queryPoint(at: Coordinate3D(latitude: 52.5, longitude: 13.4), layerIndex: 0, maxFeatures: 0)
        }
    }

    @Test
    func `map point query respects layer visibility`() throws {
        let map = try Mapnik(xml: Fixtures.polygonStyle)
        try map.zoom(to: Fixtures.germany)
        map.setLayerVisible(0, visible: false)

        let features = try map.queryPoint(
            at: Coordinate3D(latitude: 52.5, longitude: 13.4),
            layerIndex: 0)
        #expect(features.isEmpty)
    }

    // MARK: - Hex decoding

    @Test
    func `hex decoding round trips`() throws {
        let original: [UInt8] = [0x01, 0x03, 0xAB, 0xFF, 0x00]
        let hex = original.map { String(format: "%02x", $0) }.joined()

        let decoded = try #require(Data(hexEncoded: hex))
        #expect(Array(decoded) == original)
    }

    @Test
    func `hex decoding rejects invalid input`() {
        #expect(Data(hexEncoded: "abc") == nil)
        #expect(Data(hexEncoded: "zz") == nil)
    }

}
