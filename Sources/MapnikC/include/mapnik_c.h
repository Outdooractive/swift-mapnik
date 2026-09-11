#ifndef MAPNIK_C_H
#define MAPNIK_C_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle around a mapnik::Map.
typedef struct mapnik_map mapnik_map_t;

//
// Memory contract
// ---------------
// - Strings returned through `char** error_out` are allocated with `new char[]`
//   and must be released by the caller with `mapnik_free_string()`.
// - Buffers returned through `unsigned char** data` are allocated with
//   `new unsigned char[]` and must be released with `mapnik_free_buffer()`.
// - Every function clears `*error_out` on entry and sets it only on failure.
// - A NULL `error_out` pointer is legal; the message is then discarded.
//

// Release a string allocated by this library.
void mapnik_free_string(char* str);

// Release an image buffer allocated by this library.
void mapnik_free_buffer(unsigned char* data);

/// Register datasource input plugins and fonts.
/// Both paths are scanned recursively. Call once per process before creating maps.
bool mapnik_init(const char* input_plugins_path,
                 const char* fonts_path,
                 char** error_out);

/// List the font-face names registered via mapnik_init() (or any direct
/// registration done by the shim).
///
/// Returns a single NUL-separated string `name\0name\0...\0name\0` (an empty
/// registry yields an empty string), allocated with `new char[]` and
/// released with `mapnik_free_string()`. Returns NULL with details in
/// `*error_out` on failure.
char* mapnik_available_fonts(char** error_out);

// ---------------------------------------------------------------------------
// Map lifecycle
// ---------------------------------------------------------------------------

/// Create a map in Web Mercator (EPSG:3857) projection.
mapnik_map_t* mapnik_map_create(int width,
                                int height);

/// Create a map with an explicit projection string (e.g. "+init=epsg:3857").
mapnik_map_t* mapnik_map_create_with_srs(int width,
                                         int height,
                                         const char* srs);

/// Load a Mapnik XML stylesheet from a string. Returns false with details in `*error_out`.
bool mapnik_map_load_xml(mapnik_map_t* map,
                         const char* xml,
                         char** error_out);

/// Load a Mapnik XML stylesheet from a file. Returns false with details in `*error_out`.
bool mapnik_map_load_xml_file(mapnik_map_t* map,
                              const char* path,
                              char** error_out);

/// Serialize the current map (with any runtime modifications) back to XML.
///
/// Returns a string allocated with `new char[]` (release with
/// `mapnik_free_string()`), or NULL with details in `*error_out`. With
/// `explicit_defaults` the output carries every style/layer attribute even
/// when it equals mapnik's default.
char* mapnik_map_save_xml(mapnik_map_t* map,
                          bool explicit_defaults,
                          char** error_out);

/// Serialize the current map back to an XML file (replaced if it exists).
/// Returns false with details in `*error_out` on failure.
bool mapnik_map_save_xml_to_file(mapnik_map_t* map,
                                 bool explicit_defaults,
                                 const char* output_path,
                                 char** error_out);

void mapnik_map_destroy(mapnik_map_t* map);

// ---------------------------------------------------------------------------
// Map properties
// ---------------------------------------------------------------------------

void mapnik_map_resize(mapnik_map_t* map,
                       int width,
                       int height);

int mapnik_map_width(mapnik_map_t* map);
int mapnik_map_height(mapnik_map_t* map);

/// The map's projection string (a PROJ.4 string or an EPSG code like
/// "epsg:3857", as set by the stylesheet or the creation parameters).
///
/// Writes up to `buffer_count`-1 bytes of the SRS string plus a NUL
/// terminator into `srs_out`. Returns the full length of the string, or -1
/// if the map is not initialized. A return value >= `buffer_count` means
/// the output was truncated.
int mapnik_map_get_srs(mapnik_map_t* map,
                       char* srs_out,
                       int buffer_count);

/// Set the map's projection string. Returns false with details in
/// `*error_out` if the string is invalid.
bool mapnik_map_set_srs(mapnik_map_t* map,
                        const char* srs,
                        char** error_out);

/// Padding (in pixels) around the map extent used when querying layers.
void mapnik_map_set_buffer_size(mapnik_map_t* map,
                                int buffer_pixels);
int mapnik_map_buffer_size(mapnik_map_t* map);

/// Zoom to the given bounding box, in the map's SRS.
void mapnik_map_zoom_to_box(mapnik_map_t* map,
                            double minx,
                            double miny,
                            double maxx,
                            double maxy);

/// Zoom to a WGS 84 (lon/lat degrees) bounding box, reprojecting it to the
/// map's SRS first (the box edges are sampled so skewed projections produce
/// a tight envelope). Returns false with details in `*error_out` on failure.
bool mapnik_map_zoom_to_wgs84_box(mapnik_map_t* map,
                                  double minx,
                                  double miny,
                                  double maxx,
                                  double maxy,
                                  char** error_out);

/// The current visible extent of the map.
void mapnik_map_get_extent(mapnik_map_t* map,
                           double* minx,
                           double* miny,
                           double* maxx,
                           double* maxy);

/// Zoom to the combined extent of all layers.
bool mapnik_map_zoom_all(mapnik_map_t* map,
                         char** error_out);

// ---------------------------------------------------------------------------
// Layers
// ---------------------------------------------------------------------------

/// Number of layers defined by the stylesheet.
int mapnik_map_layer_count(mapnik_map_t* map);

/// Name of the layer at `index`, or NULL if `index` is out of range.
/// The returned string is owned by the map and valid until the map is destroyed.
const char* mapnik_map_layer_name(mapnik_map_t* map,
                                  int index);

/// Show or hide a layer.
bool mapnik_map_set_layer_visible(mapnik_map_t* map,
                                  int index,
                                  bool visible);

/// Current visibility of a layer. Sets `*visible` and returns true,
/// or returns false if `index` is out of range.
bool mapnik_map_layer_visible(mapnik_map_t* map,
                              int index,
                              bool* visible);

/// The geographic envelope of the layer at `index`, in the layer's own SRS.
///
/// Writes the box into the out-parameters and returns true, or returns
/// false with details in `*error_out` when the index is out of range or the
/// layer has no datasource.
bool mapnik_map_layer_envelope(mapnik_map_t* map,
                               int index,
                               double* minx,
                               double* miny,
                               double* maxx,
                               double* maxy,
                               char** error_out);

/// The layer's projection string (a PROJ.4 string or an EPSG code).
///
/// Writes up to `buffer_count`-1 bytes of the SRS string plus a NUL
/// terminator into `srs_out`. Returns the full length of the string, or -1
/// if the map or index is invalid (truncation indicated by a return value
/// >= `buffer_count`).
int mapnik_map_layer_srs(mapnik_map_t* map,
                         int index,
                         char* srs_out,
                         int buffer_count);

/// Whether the layer at `index` is queryable. Sets `*queryable` and returns
/// true, or returns false if `index` is out of range.
bool mapnik_map_layer_queryable(mapnik_map_t* map,
                                int index,
                                bool* queryable);

/// Whether the layer at `index` renders at the given scale denominator
/// (respecting the layer's min/max scale denominators and visibility).
/// Sets `*visible` and returns true, or returns false if `index` is out of
/// range.
bool mapnik_map_layer_visible_at_scale(mapnik_map_t* map,
                                       int index,
                                       double scale_denominator,
                                       bool* visible);

/// Zoom the map to the layer's envelope, reprojected from the layer's SRS
/// to the map's SRS (the box edges are sampled so skewed projections produce
/// a tight envelope). Returns false with details in `*error_out` on failure.
bool mapnik_map_zoom_to_layer(mapnik_map_t* map,
                              int index,
                              char** error_out);

// ---------------------------------------------------------------------------
// Rendering
//
// All render functions are `const` with respect to the map's extent and
// dimensions: free-form rendering uses the map's current view, and tile
// rendering temporarily reconfigures the map (resize + zoom) and restores
// the previous state afterwards (mapnik's feature_style_processor always
// queries with the map's own extent, so a const tile path is not available
// in mapnik 3.x).
//
// `type` is a Mapnik image type string:
//   "png", "png8", "png256", "png:c=<1-256>", "jpeg", "jpeg:quality=85",
//   "webp", "webp:quality=80:alpha_quality=90", "tiff"
//
// When `is_empty` is non-NULL it receives true if the rendered image is
// entirely transparent (no features painted). In that case no encoding is
// performed and `*data`/`*size` are set to NULL/0.
// ---------------------------------------------------------------------------

/// Render the current map view into memory.
/// When `skip_empty` is true, fully transparent results produce
/// `*is_empty = true` instead of an encoded image.
bool mapnik_map_render_to_buffer(mapnik_map_t* map,
                                 const char* type,
                                 bool skip_empty,
                                 unsigned char** data,
                                 unsigned long* size,
                                 bool* is_empty,
                                 char** error_out);

/// Render the current map view to a file.
bool mapnik_map_render_to_file(mapnik_map_t* map,
                               const char* type,
                               const char* output_path,
                               char** error_out);

/// Render an XYZ tile (Web Mercator, Google scheme) into memory.
/// `scale_factor` supports retina-style output (e.g. 2.0 for @2x tiles).
bool mapnik_map_render_tile_to_buffer(mapnik_map_t* map,
                                      int tile_x,
                                      int tile_y,
                                      int zoom,
                                      int tile_size,
                                      double scale_factor,
                                      const char* type,
                                      bool skip_empty,
                                      unsigned char** data,
                                      unsigned long* size,
                                      bool* is_empty,
                                      char** error_out);

/// Render an XYZ tile to a file.
bool mapnik_map_render_tile_to_file(mapnik_map_t* map,
                                    int tile_x,
                                    int tile_y,
                                    int zoom,
                                    int tile_size,
                                    double scale_factor,
                                    const char* type,
                                    const char* output_path,
                                    char** error_out);

/// Render a metatile: a `meta_size` × `meta_size` block of XYZ tiles rendered
/// in one pass (one datasource query per layer instead of one per tile, and
/// label placement sees the whole block, avoiding clipped labels at tile
/// edges).
///
/// `tile_x`/`tile_y` are the coordinates of the block's top-left (north-west)
/// tile; the block spans tiles (tile_x .. tile_x + meta_size - 1,
/// tile_y .. tile_y + meta_size - 1) at `zoom`.
///
/// On success the raw premultiplied RGBA8 image of the whole metatile is
/// written to `*data` (allocated with `new unsigned char[]`, release with
/// `mapnik_free_buffer()`), its dimensions in pixels to `*out_width`/
/// `*out_height`, and `*is_empty` reports whether the metatile is entirely
/// transparent. When `*is_empty` is true the buffer is still allocated; the
/// caller decides whether to keep it.
///
/// Tile (dx, dy) within the metatile starts at pixel column
/// `dx * tile_size * scale_factor`, row `dy * tile_size * scale_factor` and
/// is `tile_size * scale_factor` pixels wide/tall.
bool mapnik_map_render_metatile(mapnik_map_t* map,
                                int tile_x,
                                int tile_y,
                                int zoom,
                                int tile_size,
                                double scale_factor,
                                int meta_size,
                                unsigned char** data,
                                unsigned long* size,
                                int* out_width,
                                int* out_height,
                                bool* is_empty,
                                char** error_out);

/// Crop a region of a raw RGBA8 image (premultiplied alpha, 4 bytes per
/// pixel, no row padding, top-down) and encode it with the mapnik image
/// writer. `src` is owned by the caller and must stay valid for the call.
/// Semantics otherwise match mapnik_map_render_to_buffer (skip_empty,
/// `*data` ownership via mapnik_free_buffer, `*is_empty` for fully
/// transparent crops).
bool mapnik_image_crop_encode(unsigned char const* src,
                              int src_width,
                              int src_height,
                              int offset_x,
                              int offset_y,
                              int crop_width,
                              int crop_height,
                              const char* type,
                              bool skip_empty,
                              unsigned char** data,
                              unsigned long* size,
                              bool* is_empty,
                              char** error_out);

/// Render the current map view with the cairo backend into memory.
///
/// `type` selects the vector surface: "svg", "pdf" or "ps". Returns false
/// with details in `*error_out` for other types or render failures.
bool mapnik_map_render_to_cairo_buffer(mapnik_map_t* map,
                                       double scale_factor,
                                       const char* type,
                                       unsigned char** data,
                                       unsigned long* size,
                                       char** error_out);

/// Render the current map view with the cairo backend to a file (replaced
/// if it exists). `type` selects the vector surface: "svg", "pdf" or "ps".
bool mapnik_map_render_to_cairo_file(mapnik_map_t* map,
                                     double scale_factor,
                                     const char* type,
                                     const char* output_path,
                                     char** error_out);

// ---------------------------------------------------------------------------
// Datasource inspection
//
// Builds a datasource directly from name/value parameter pairs (the format
// Mapnik XML <Parameter> elements carry, and what CartoCSS projects store in
// their layer `Datasource` objects) and inspects it: field list, geometry
// type, feature samples and geographic extent. Nothing here renders; all
// entry points are thread-safe with respect to map creation (the datasource
// registry is global and not thread-safe, so creation is serialized inside
// this library like map creation).
// ---------------------------------------------------------------------------

/// Opaque handle around a mapnik::datasource.
typedef struct mapnik_datasource mapnik_datasource_t;

/// Create a datasource from `count` name/value parameter pairs.
///
/// `keys`/`values` are parallel arrays of `count` NUL-terminated strings
/// (both may be NULL only when `count == 0`). The `type` parameter selects
/// the input plugin (postgis, shape, geojson, gdal, ...); it must have been
/// registered via mapnik_init() first.
///
/// The projection of the data is given by the caller's `srs` parameter
/// (a PROJ.4 string or EPSG code, as in layer SRS) — the extent values
/// returned by mapnik_datasource_inspect() are in that SRS.
mapnik_datasource_t* mapnik_datasource_create(const char* const* keys,
                                               const char* const* values,
                                               int count,
                                               char** error_out);

/// Release a datasource handle.
void mapnik_datasource_destroy(mapnik_datasource_t* datasource);

/// Inspect a datasource and return a JSON document allocated with
/// `new char[]` (release with `mapnik_free_string()`), or NULL with details
/// in `*error_out`.
///
/// JSON shape (stable field order for testability):
///   {
///     "type": "vector" | "raster",
///     "geometry_type": "point"|"linestring"|"polygon"|"collection"|"unknown"
///                      (null for raster datasources),
///     "extent": [minx, miny, maxx, maxy],          // in the datasource SRS
///     "unproj_extent": [w, s, e, n],               // lon/lat (WGS84), clamped
///     "fields": [["name", "String"|"Integer"|"Float"|"Double"|"Boolean"|"Geometry"|"Object"], ...],
///     "features": [ {"name": value-as-typed-JSON, ...}, ... ]  // up to max_features
///   }
///
/// With a field filter (`field_count` > 0), only the named fields are
/// listed and sampled. Feature samples carry attributes only; geometry
/// samples are available through mapnik_datasource_query_box.
///
/// Raster datasources report `type: "raster"`, `geometry_type: null`, no
/// fields and no features (there is no featureset to iterate).
char* mapnik_datasource_inspect(mapnik_datasource_t* datasource,
                                const char* srs,
                                int max_features,
                                const char* const* field_names,
                                int field_count,
                                char** error_out);

/// List the sub-layers of an OGR datasource.
///
/// Writes up to `buffer_count` layer names into `layers_out` (each a pointer
/// into the internal, statically cached message string — copy before the
/// next call). Returns the total number of names available, or -1 with
/// details in `*error_out` when the datasource is not an OGR source or the
/// message cannot be parsed. Used to fill sublayer selectors in editor UIs.
int mapnik_datasource_ogr_layers(mapnik_datasource_t* datasource,
                                 const char** layers_out,
                                 int buffer_count,
                                 char** error_out);

// ---------------------------------------------------------------------------
// Feature queries
//
// Hit-testing: query the features of a map layer at a point (in the map's
// SRS) or of a standalone datasource in a box (in the datasource's SRS).
// Both return a JSON document:
//
//   {"features":[{"id":<id>,"wkb":"<hex or null>","properties":{...}}, ...]}
//
// The geometry is generic little-endian WKB hex (empty geometries emit
// "wkb":null). Attribute values are JSON strings (the same uniform schema
// inspect() uses). Nothing here renders.
// ---------------------------------------------------------------------------

/// Query the features of the layer at `index` intersecting the map point
/// (`x`, `y` in the map's SRS), honoring the layer's visibility and scale
/// rules like a render would.
///
/// Writes a document allocated with `new char[]` (release with
/// `mapnik_free_string()`) into `*json_out`. Returns false with details in
/// `*error_out` on failure (out-of-range index, query errors).
bool mapnik_map_query_point(mapnik_map_t* map,
                            int layer_index,
                            double x,
                            double y,
                            int max_features,
                            char** json_out,
                            char** error_out);

/// Transform a WGS 84 (lon/lat degrees) point into the map's SRS. Writes
/// the projected coordinates into `*out_x`/`*out_y`. Returns false with
/// details in `*error_out` when the SRS is invalid or the projection fails.
bool mapnik_map_project_from_wgs84(mapnik_map_t* map,
                                   double lon,
                                   double lat,
                                   double* out_x,
                                   double* out_y,
                                   char** error_out);

/// Query the features of a standalone datasource intersecting the box
/// (minx/miny/maxx/maxy in the datasource's native SRS). Honors no
/// visibility or scale rules — it is a plain featureset query.
///
/// Writes a document allocated with `new char[]` (release with
/// `mapnik_free_string()`) into `*json_out`. Returns false with details in
/// `*error_out` on failure.
bool mapnik_datasource_query_box(mapnik_datasource_t* datasource,
                                 double minx,
                                 double miny,
                                 double maxx,
                                 double maxy,
                                 int max_features,
                                 char** json_out,
                                 char** error_out);

// ---------------------------------------------------------------------------
// Counting datasource (test instrumentation)
//
// A mapnik::memory_datasource subclass that counts how often mapnik queries
// it. Lets test suites assert the number of datasource queries a render
// performs — e.g. that a metatile performs one query per layer instead of
// one per tile. Nothing here renders.
//
// The handle is attached to a map layer via mapnik_map_use_counting_datasource;
// ownership stays with the caller (destroy with
// mapnik_counting_datasource_destroy when done).
// ---------------------------------------------------------------------------

/// Opaque handle around a query-counting memory datasource.
typedef struct mapnik_counting_datasource mapnik_counting_datasource_t;

/// Create an empty counting datasource. Its layer envelope is empty until
/// the first feature is pushed.
mapnik_counting_datasource_t* mapnik_counting_datasource_create(void);

/// Release a counting datasource handle.
void mapnik_counting_datasource_destroy(mapnik_counting_datasource_t* datasource);

/// Push a polygon feature (WKB, little- or big-endian generic WKB, XY) with
/// a `name` string attribute. Also extends the datasource envelope to
/// include the geometry's bounding box (memory_datasource's envelope() only
/// reports the explicitly set envelope).
///
/// Returns false with details in `*error_out` on malformed WKB.
bool mapnik_counting_datasource_push_polygon(mapnik_counting_datasource_t* datasource,
                                             const unsigned char* wkb,
                                             unsigned long wkb_size,
                                             const char* name,
                                             char** error_out);

/// Attach the datasource to the layer at `index` of the map. The map keeps a
/// shared reference; the caller must keep the handle alive while the map is
/// in use (or until replaced).
bool mapnik_map_use_counting_datasource(mapnik_map_t* map,
                                        int layer_index,
                                        mapnik_counting_datasource_t* datasource,
                                        char** error_out);

/// Number of `features(query)` calls mapnik has performed on this datasource.
/// Monotonic; reset by replacing or re-creating the datasource.
int mapnik_counting_datasource_query_count(mapnik_counting_datasource_t* datasource);

// ---------------------------------------------------------------------------
// PNG palettes
// ---------------------------------------------------------------------------

/// Opaque handle around a mapnik::rgba_palette.
typedef struct mapnik_palette mapnik_palette_t;

/// Build a palette from up to 256 packed ARGB colors (0xAARRGGBB).
/// Returns NULL if `color_count` is 0 or a color repeats.
mapnik_palette_t* mapnik_palette_create(const unsigned int* colors,
                                        int color_count,
                                        char** error_out);

void mapnik_palette_destroy(mapnik_palette_t* palette);

/// Like mapnik_map_render_to_buffer, but quantizes the PNG output to `palette`.
/// Only "png" types support palettes.
bool mapnik_map_render_to_buffer_with_palette(mapnik_map_t* map,
                                              mapnik_palette_t* palette,
                                              unsigned char** data,
                                              unsigned long* size,
                                              bool* is_empty,
                                              char** error_out);

/// Like mapnik_map_render_to_file, but quantizes the PNG output to `palette`.
bool mapnik_map_render_to_file_with_palette(mapnik_map_t* map,
                                            mapnik_palette_t* palette,
                                            const char* output_path,
                                            char** error_out);

#ifdef __cplusplus
} // extern "C"
#endif
#endif // MAPNIK_C_H