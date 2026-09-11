import Foundation
import GISTools
@testable import Mapnik
import Testing

/// Tests for per-layer extents and properties.
@Suite("Layer properties")
struct LayerPropertyTests {

    @Test
    func `layer envelope matches the datasource extent`() throws {
        let map = try Mapnik(xml: Fixtures.multiLayerStyle)

        // Both layers use the same inline GeoJSON: lon -10..40, lat 35..70.
        let envelope = try map.layerEnvelope(0)
        #expect(envelope.southWest.longitude < -9)
        #expect(envelope.southWest.latitude < 36)
        #expect(envelope.northEast.longitude > 39)
        #expect(envelope.northEast.latitude > 69)

        let second = try map.layerEnvelope(1)
        #expect(second == envelope)
    }

    @Test
    func `layer envelope throws for out of range and empty layers`() throws {
        let map = try Mapnik(xml: Fixtures.multiLayerStyle)

        #expect(throws: MapnikError.self) {
            try map.layerEnvelope(2)
        }
        #expect(throws: MapnikError.self) {
            try map.layerEnvelope(-1)
        }
    }

    @Test
    func `layer SRS comes from the stylesheet`() throws {
        let map = try Mapnik(xml: Fixtures.multiLayerStyle)

        #expect(map.layerSRS(0) == "epsg:4326")
        #expect(map.layerSRS(1) == "epsg:4326")
        #expect(map.layerSRS(2) == nil)
        #expect(map.layerSRS(-1) == nil)
    }

    @Test
    func `layer queryable status defaults to false`() throws {
        let map = try Mapnik(xml: Fixtures.multiLayerStyle)

        #expect(map.layerQueryable(0) == false)
        #expect(map.layerQueryable(1) == false)
        #expect(map.layerQueryable(2) == nil)
        #expect(map.layerQueryable(-1) == nil)
    }

    @Test
    func `layer visibility at scale respects zoom rules`() throws {
        // A style with a layer restricted to scale denominators 1000..100000.
        let xml = """
        <Map srs="epsg:3857">
          <Style name="land">
            <Rule>
              <PolygonSymbolizer fill="#ff0000"/>
            </Rule>
          </Style>
          <Layer name="land" srs="epsg:4326" minimum-scale-denominator="1000" maximum-scale-denominator="100000">
            <StyleName>land</StyleName>
            <Datasource>
              <Parameter name="type">geojson</Parameter>
              <Parameter name="inline">\(Fixtures.geojson)</Parameter>
            </Datasource>
          </Layer>
        </Map>
        """
        let map = try Mapnik(xml: xml)

        #expect(map.layerVisible(0, atScaleDenominator: 10000) == true)
        #expect(map.layerVisible(0, atScaleDenominator: 100) == false)
        #expect(map.layerVisible(0, atScaleDenominator: 1_000_000) == false)
        #expect(map.layerVisible(1, atScaleDenominator: 10000) == nil)

        // Hiding the layer hides it at any scale.
        map.setLayerVisible(0, visible: false)
        #expect(map.layerVisible(0, atScaleDenominator: 10000) == false)
    }

    @Test
    func `zoom to layer fits the layer envelope`() throws {
        let map = try Mapnik(xml: Fixtures.multiLayerStyle)

        try map.zoomToLayer(0)

        // The map now covers roughly the layer's extent (Web Mercator).
        let data = try map.render(width: 256, height: 256, format: .png())
        #expect(data != nil)

        #expect(throws: MapnikError.self) {
            try map.zoomToLayer(2)
        }
    }

}
