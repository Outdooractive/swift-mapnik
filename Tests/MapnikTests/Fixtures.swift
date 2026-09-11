import Foundation
import GISTools
@testable import Mapnik

/// Minimal Mapnik XML stylesheets and inline GeoJSON data for tests.
///
/// The styles use the `geojson` input plugin (shipped with every mapnik
/// build) with inline data, so no external files, network or database are
/// needed.
enum Fixtures {

    /// A tiny world dataset: one polygon covering Europe.
    static let geojson = """
    {
      "type": "FeatureCollection",
      "features": [
        {
          "type": "Feature",
          "properties": { "name": "Europe" },
          "geometry": {
            "type": "Polygon",
            "coordinates": [[
              [-10.0, 35.0],
              [40.0, 35.0],
              [40.0, 70.0],
              [-10.0, 70.0],
              [-10.0, 35.0]
            ]]
          }
        }
      ]
    }
    """

    /// A stylesheet that fills the polygon in red with a black outline.
    static let polygonStyle = """
    <Map srs="epsg:3857" buffer-size="16">
      <Style name="land" filter-mode="first">
        <Rule>
          <PolygonSymbolizer fill="#d40000" fill-opacity="1.0"/>
          <LineSymbolizer stroke="#000000" stroke-width="1.0"/>
        </Rule>
      </Style>
      <Layer name="land" srs="epsg:4326">
        <StyleName>land</StyleName>
        <Datasource>
          <Parameter name="type">geojson</Parameter>
          <Parameter name="inline">\(geojson)</Parameter>
        </Datasource>
      </Layer>
    </Map>
    """

    /// A stylesheet with two layers, for layer introspection tests.
    static let multiLayerStyle = """
    <Map srs="epsg:3857">
      <Style name="one">
        <Rule>
          <PolygonSymbolizer fill="#ff0000"/>
        </Rule>
      </Style>
      <Style name="two">
        <Rule>
          <PolygonSymbolizer fill="#00ff00"/>
        </Rule>
      </Style>
      <Layer name="layer-one" srs="epsg:4326">
        <StyleName>one</StyleName>
        <Datasource>
          <Parameter name="type">geojson</Parameter>
          <Parameter name="inline">\(geojson)</Parameter>
        </Datasource>
      </Layer>
      <Layer name="layer-two" srs="epsg:4326">
        <StyleName>two</StyleName>
        <Datasource>
          <Parameter name="type">geojson</Parameter>
          <Parameter name="inline">\(geojson)</Parameter>
        </Datasource>
      </Layer>
    </Map>
    """

    /// A stylesheet with a text label (exercises font registration).
    static let labelStyle = """
    <Map srs="epsg:3857" buffer-size="32">
      <Style name="labels">
        <Rule>
          <TextSymbolizer size="12" face-name="DejaVu Sans Book"
            fill="#000000" halo-fill="#ffffff" halo-radius="1">[name]</TextSymbolizer>
        </Rule>
      </Style>
      <Layer name="labels" srs="epsg:4326">
        <StyleName>labels</StyleName>
        <Datasource>
          <Parameter name="type">geojson</Parameter>
          <Parameter name="inline">\(geojson)</Parameter>
        </Datasource>
      </Layer>
    </Map>
    """

    /// An intentionally broken stylesheet (unclosed tag).
    static let brokenStyle = """
    <Map srs="epsg:3857">
      <Layer name="broken">
    </Map>
    """

    /// A stylesheet referencing a datasource type that no plugin provides.
    static let unknownDatasourceStyle = """
    <Map srs="epsg:3857">
      <Style name="s">
        <Rule>
          <PolygonSymbolizer fill="#ff0000"/>
        </Rule>
      </Style>
      <Layer name="l" srs="epsg:4326">
        <StyleName>s</StyleName>
        <Datasource>
          <Parameter name="type">does-not-exist</Parameter>
          <Parameter name="file">/nonexistent/file.geojson</Parameter>
        </Datasource>
      </Layer>
    </Map>
    """

    /// A tile that intersects the Europe polygon (Germany at z4).
    static let europeTile = MapTile(x: 8, y: 5, z: 4)

    /// An ocean tile far from the polygon (South Pacific at z4).
    static let oceanTile = MapTile(x: 1, y: 12, z: 4)

    /// A bounding box roughly covering Germany.
    static let germany = BoundingBox(
        southWest: Coordinate3D(latitude: 47.2, longitude: 5.9),
        northEast: Coordinate3D(latitude: 55.0, longitude: 15.0))

}
