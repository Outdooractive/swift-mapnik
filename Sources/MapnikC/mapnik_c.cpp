//
//  C shim between Swift and the Mapnik C++ toolkit.
//
//  Design rules:
//  - C++ exceptions never cross the boundary; every entry point catches and
//    reports through an out-parameter instead.
//  - Diagnostics from mapnik (e.what()) are returned to the caller so that
//    failures are actionable instead of silently swallowed.
//  - Tile rendering temporarily reconfigures the map (resize + zoom) and
//    restores the previous state afterwards; mapnik's feature_style_processor
//    always queries with the map's own extent, so a const tile path is not
//    available in mapnik 3.x.
//

#include "mapnik_c.h"

// The installed mapnik library is built with the cairo backend (verified via
// exported save_to_cairo_file symbols), but the headers gate the cairo API on
// this macro. Define it before including any mapnik headers.
#ifndef HAVE_CAIRO
#define HAVE_CAIRO 1
#endif

#include <mapnik/map.hpp>
#include <mapnik/layer.hpp>
#include <mapnik/load_map.hpp>
#include <mapnik/save_map.hpp>
#include <mapnik/agg_renderer.hpp>
#include <mapnik/cairo_io.hpp>
#include <mapnik/image.hpp>
#include <mapnik/image_util.hpp>
#include <mapnik/datasource.hpp>
#include <mapnik/datasource_cache.hpp>
#include <mapnik/memory_datasource.hpp>
#include <mapnik/feature.hpp>
#include <mapnik/featureset.hpp>
#include <mapnik/feature_layer_desc.hpp>
#include <mapnik/attribute_descriptor.hpp>
#include <mapnik/projection.hpp>
#include <mapnik/proj_transform.hpp>
#include <mapnik/font_engine_freetype.hpp>
#include <mapnik/palette.hpp>
#include <mapnik/well_known_srs.hpp>
#include <mapnik/wkb.hpp>
#include <mapnik/util/geometry_to_wkb.hpp>

// mapnik vendors a modified copy of Anti-Grain Geometry; its headers
// include "agg_*.h" without a path prefix.
#include <mapnik/agg/agg_trans_affine.h>

#include <cstdio>
#include <cstring>
#include <exception>
#include <algorithm>
#include <atomic>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <set>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

namespace {

// Web Mercator: the projected square spans 2 * PI * R with R = 6378137.
constexpr double kWebMercatorExtent = 2.0 * 3.14159265358979323846 * 6378137.0;

} // namespace

/// Definitions of the opaque types declared in mapnik_c.h.
/// Must live in the global namespace to match the header's forward declarations.
struct mapnik_map {
    std::unique_ptr<mapnik::Map> map;
};

struct mapnik_palette {
    std::unique_ptr<mapnik::rgba_palette> palette;
};

struct mapnik_datasource {
    std::shared_ptr<mapnik::datasource> datasource;
};

/// A memory_datasource that counts how often mapnik queries it.
///
/// Used by test suites to assert the number of datasource queries a render
/// performs (e.g. one per layer for a metatile instead of one per tile).
class counting_datasource_impl : public mapnik::memory_datasource {
public:
    counting_datasource_impl()
        : mapnik::memory_datasource(mapnik::parameters()) {}

    mapnik::featureset_ptr features(mapnik::query const& q) const override {
        query_count.fetch_add(1, std::memory_order_relaxed);
        return mapnik::memory_datasource::features(q);
    }

    mapnik::featureset_ptr features_at_point(mapnik::coord2d const& pt, double tol = 0) const override {
        point_query_count.fetch_add(1, std::memory_order_relaxed);
        return mapnik::memory_datasource::features_at_point(pt, tol);
    }

    mutable std::atomic<int> query_count{0};
    mutable std::atomic<int> point_query_count{0};
};

/// Serializes map/datasource creation and stylesheet loading. Mapnik's
/// datasource and font registries are global mutable state and not
/// thread-safe; rendering itself stays parallel and lock-free.
std::mutex& mapnik_lifecycle_mutex() {
    static std::mutex mutex;
    return mutex;
}

namespace {

/// Copy `message` into a freshly allocated C string (new char[]).
char* allocate_error_message(std::string const& message) {
    char* buffer = new (std::nothrow) char[message.size() + 1];
    if (buffer != nullptr) {
        std::memcpy(buffer, message.c_str(), message.size() + 1);
    }
    return buffer;
}

/// Store `message` in *error_out (if requested) and return false for convenience.
bool report_error(char** error_out, std::string const& message) {
    if (error_out != nullptr) {
        *error_out = allocate_error_message(message);
    }
    return false;
}

/// Copy a list of names into a freshly allocated NUL-separated buffer
/// (`name\0name\0...\0`), suitable for transfer to the caller. Returns the
/// buffer or NULL after storing an error message.
char* copy_names_to_buffer(std::vector<std::string> const& names, char** error_out) {
    std::size_t total = 1; // final terminator
    for (std::string const& name : names) {
        total += name.size() + 1;
    }

    char* buffer = new (std::nothrow) char[total];
    if (buffer == nullptr) {
        report_error(error_out, "out of memory while copying names");
        return nullptr;
    }

    std::size_t offset = 0;
    for (std::string const& name : names) {
        std::memcpy(buffer + offset, name.c_str(), name.size() + 1);
        offset += name.size() + 1;
    }
    buffer[offset] = '\0';
    return buffer;
}

/// Guard against NULL handles in every entry point.
bool require_map(mapnik_map_t* map, char** error_out) {
    if (map == nullptr || map->map == nullptr) {
        return report_error(error_out, "map is not initialized");
    }
    return true;
}

/// Check that an XYZ tile coordinate is within the valid range for `zoom`.
bool validate_tile_coordinates(int tile_x, int tile_y, int zoom, char** error_out) {
    if (zoom < 0 || zoom > 30) {
        return report_error(error_out, "zoom level out of range: " + std::to_string(zoom));
    }
    long long const tile_count = 1LL << zoom;
    if (tile_x < 0 || tile_x >= tile_count || tile_y < 0 || tile_y >= tile_count) {
        std::ostringstream message;
        message << "tile coordinates (" << tile_x << ", " << tile_y
                << ") out of range for zoom " << zoom;
        return report_error(error_out, message.str());
    }
    return true;
}

/// Bounding box of an XYZ tile in Web Mercator coordinates.
mapnik::box2d<double> tile_bounding_box(int tile_x, int tile_y, int zoom, int tile_size) {
    double const resolution = kWebMercatorExtent / (static_cast<double>(tile_size) * (1LL << zoom));
    double const min_x = -kWebMercatorExtent / 2.0 + tile_x * tile_size * resolution;
    double const min_y = kWebMercatorExtent / 2.0 - (tile_y + 1) * tile_size * resolution;
    return mapnik::box2d<double>(min_x, min_y, min_x + tile_size * resolution, min_y + tile_size * resolution);
}

/// True if every alpha byte is zero. Honors row padding and premultiplication.
bool is_fully_transparent(mapnik::image_rgba8 const& image) {
    std::size_t const width = image.width();
    std::size_t const height = image.height();
    if (width == 0 || height == 0) {
        return true;
    }

    unsigned char const* bytes = image.bytes();
    std::size_t const row_size = image.row_size();

    for (std::size_t y = 0; y < height; ++y) {
        unsigned char const* row = bytes + y * row_size;
        for (std::size_t x = 0; x < width; ++x) {
            if (row[x * 4 + 3] > 0) {
                return false;
            }
        }
    }
    return true;
}

/// Render the current map view into a fresh RGBA image.
std::unique_ptr<mapnik::image_rgba8> render_view(mapnik::Map const& map, double scale_factor) {
    auto image = std::make_unique<mapnik::image_rgba8>(
        static_cast<int>(map.width() * scale_factor),
        static_cast<int>(map.height() * scale_factor));
    image->set_premultiplied(true);

    mapnik::agg_renderer<mapnik::image_rgba8> renderer(map, *image, scale_factor);
    renderer.apply();
    return image;
}

/// Restores a map's dimensions and extent when it goes out of scope.
class MapStateGuard {
public:
    MapStateGuard(mapnik::Map& map)
        : map_(map),
          extent_(map.get_current_extent()),
          width_(static_cast<int>(map.width())),
          height_(static_cast<int>(map.height())) {}

    ~MapStateGuard() {
        try {
            map_.resize(static_cast<unsigned>(width_), static_cast<unsigned>(height_));
            map_.zoom_to_box(extent_);
        }
        catch (...) {
            // Never throw from a destructor.
        }
    }

    MapStateGuard(MapStateGuard const&) = delete;
    MapStateGuard& operator= (MapStateGuard const&) = delete;

private:
    mapnik::Map& map_;
    mapnik::box2d<double> extent_;
    int width_;
    int height_;
};

/// Render an XYZ tile into a fresh RGBA image.
///
/// mapnik's feature_style_processor always queries with the map's own extent
/// and buffer (see feature_style_processor_impl.hpp), so the reliable way to
/// render a tile is to temporarily reconfigure the map and restore it after.
/// The map's dimensions and visible extent are preserved across the call.
///
/// Retina rendering: the map is resized to the device pixel size and the
/// scale factor only boosts symbolizer sizes (line widths, fonts) — mapnik's
/// agg_renderer maps the extent to the map's own dimensions regardless of the
/// scale factor, so scaling only the image would render at the wrong
/// resolution.
std::unique_ptr<mapnik::image_rgba8> render_tile_view(mapnik::Map& map,
                                                      int tile_x, int tile_y, int zoom,
                                                      int tile_size, double scale_factor) {
    MapStateGuard guard(map);

    long long const device_size = static_cast<long long>(tile_size * scale_factor);
    map.resize(static_cast<unsigned>(device_size), static_cast<unsigned>(device_size));
    map.zoom_to_box(tile_bounding_box(tile_x, tile_y, zoom, tile_size));

    auto image = std::make_unique<mapnik::image_rgba8>(
        static_cast<int>(device_size),
        static_cast<int>(device_size));
    image->set_premultiplied(true);

    mapnik::agg_renderer<mapnik::image_rgba8> renderer(map, *image, scale_factor);
    renderer.apply();
    return image;
}

/// Render a metatile (a block of N×N tiles rendered as one image) into a
/// fresh RGBA image.
///
/// One render call covers `meta_size`² tiles, which reduces the number of
/// datasource queries by a factor of `meta_size`² and lets label placement
/// (collision detection) see the whole block instead of a single tile, so
/// labels no longer clip at tile edges within the block.
///
/// `tile_size` is the edge length of a single output tile in pixels before
/// scale; the returned image is `meta_size * tile_size * scale_factor` pixels
/// per edge. Tile (dx, dy) within the metatile starts at
/// `(dx * tile_size * scale_factor, dy * tile_size * scale_factor)`.
std::unique_ptr<mapnik::image_rgba8> render_metatile_view(mapnik::Map& map,
                                                          int tile_x, int tile_y, int zoom,
                                                          int tile_size, double scale_factor,
                                                          int meta_size) {
    long long const device_width = static_cast<long long>(tile_size * scale_factor) * meta_size;
    if (device_width <= 0 || device_width > std::numeric_limits<int>::max() / 2) {
        throw std::runtime_error("metatile size out of range");
    }

    MapStateGuard guard(map);

    // The map's dimensions are the device pixel size of the whole block; the
    // scale factor only boosts symbolizer sizes (see render_tile_view).
    map.resize(static_cast<unsigned>(device_width), static_cast<unsigned>(device_width));

    // The metatile spans the boxes of its origin tile plus (meta_size - 1)
    // tiles to the east and south.
    double const resolution = kWebMercatorExtent / (static_cast<double>(tile_size) * (1LL << zoom));
    double const min_x = -kWebMercatorExtent / 2.0 + tile_x * tile_size * resolution;
    double const max_y = kWebMercatorExtent / 2.0 - tile_y * tile_size * resolution;
    map.zoom_to_box(mapnik::box2d<double>(
        min_x,
        max_y - meta_size * tile_size * resolution,
        min_x + meta_size * tile_size * resolution,
        max_y));

    auto image = std::make_unique<mapnik::image_rgba8>(
        static_cast<int>(device_width), static_cast<int>(device_width));
    image->set_premultiplied(true);

    mapnik::agg_renderer<mapnik::image_rgba8> renderer(map, *image, scale_factor);
    renderer.apply();
    return image;
}

/// Copy an RGBA image's bytes into a freshly allocated output buffer.
bool copy_image_to_output_buffer(mapnik::image_rgba8 const& image,
                                 unsigned char** data,
                                 unsigned long* size,
                                 char** error_out) {
    std::size_t const byte_count = image.width() * image.height() * 4;
    unsigned char* output = new (std::nothrow) unsigned char[byte_count == 0 ? 1 : byte_count];
    if (output == nullptr) {
        return report_error(error_out, "out of memory while copying image buffer");
    }
    std::memcpy(output, image.bytes(), byte_count);
    *data = output;
    *size = static_cast<unsigned long>(byte_count);
    return true;
}

/// Encode an RGBA image, skipping fully transparent images when requested.
bool encode_image(mapnik::image_rgba8 const& image,
                  std::string const& type,
                  bool skip_empty,
                  unsigned char** data,
                  unsigned long* size,
                  bool* is_empty,
                  char** error_out) {
    if (data == nullptr || size == nullptr) {
        return report_error(error_out, "output pointers must not be null");
    }
    *data = nullptr;
    *size = 0;
    if (is_empty != nullptr) {
        *is_empty = false;
    }

    if (skip_empty && is_fully_transparent(image)) {
        if (is_empty != nullptr) {
            *is_empty = true;
        }
        return true;
    }

    std::string buffer = mapnik::save_to_string(image, type);

    *data = new (std::nothrow) unsigned char[buffer.size() == 0 ? 1 : buffer.size()];
    if (*data == nullptr) {
        return report_error(error_out, "out of memory while encoding image");
    }
    std::memcpy(*data, buffer.data(), buffer.size());
    *size = static_cast<unsigned long>(buffer.size());
    return true;
}

/// Crop a region from a raw RGBA buffer and encode it in the given format.
///
/// The source is an RGBA8 image with premultiplied alpha (as produced by
/// mapnik's renderer), `src_width` * 4 bytes per row, top-down. The cropped
/// region is copied into an image of its own and encoded, matching the
/// single-tile render path byte for byte.
bool crop_encode(unsigned char const* src,
                 int src_width, int src_height,
                 int offset_x, int offset_y,
                 int crop_width, int crop_height,
                 std::string const& type,
                 bool skip_empty,
                 unsigned char** data,
                 unsigned long* size,
                 bool* is_empty,
                 char** error_out) {
    if (src_width <= 0 || src_height <= 0) {
        return report_error(error_out, "source dimensions must be positive");
    }
    if (crop_width <= 0 || crop_height <= 0) {
        return report_error(error_out, "crop dimensions must be positive");
    }
    if (offset_x < 0 || offset_y < 0 ||
        offset_x + crop_width > src_width ||
        offset_y + crop_height > src_height) {
        return report_error(error_out, "crop region out of range for source image");
    }

    mapnik::image_rgba8 tile(crop_width, crop_height, true, true);
    tile.set_premultiplied(true);
    for (int row = 0; row < crop_height; ++row) {
        unsigned char const* src_row = src + (static_cast<std::size_t>(offset_y + row) * src_width + offset_x) * 4;
        std::memcpy(tile.get_row(row), src_row, static_cast<std::size_t>(crop_width) * 4);
    }

    return encode_image(tile, type, skip_empty, data, size, is_empty, error_out);
}

/// Copy a std::string into a freshly allocated output buffer.
bool copy_to_output_buffer(std::string const& buffer,
                           unsigned char** data,
                           unsigned long* size,
                           char** error_out) {
    if (data == nullptr || size == nullptr) {
        return report_error(error_out, "output pointers must not be null");
    }
    *data = new (std::nothrow) unsigned char[buffer.size() == 0 ? 1 : buffer.size()];
    if (*data == nullptr) {
        return report_error(error_out, "out of memory");
    }
    std::memcpy(*data, buffer.data(), buffer.size());
    *size = static_cast<unsigned long>(buffer.size());
    return true;
}

/// Write a buffer to a file, replacing the file if it exists.
bool write_buffer_to_file(unsigned char const* data,
                          unsigned long size,
                          const char* output_path,
                          char** error_out) {
    std::FILE* file = std::fopen(output_path, "wb");
    if (file == nullptr) {
        return report_error(error_out, std::string("could not open '") + output_path + "' for writing");
    }
    std::size_t const written = std::fwrite(data, 1, size, file);
    std::fclose(file);
    if (written != static_cast<std::size_t>(size)) {
        return report_error(error_out, std::string("short write to '") + output_path + "'");
    }
    return true;
}

// --- SVG (cairo) -----------------------------------------------------------

/// Render the map with the cairo backend (svg/pdf/ps) into a string.
///
/// mapnik only exposes `save_to_cairo_file` (no to-buffer variant), so we
/// render to a temporary file and read it back.
bool render_cairo_to_buffer(mapnik::Map const& map,
                            double scale_factor,
                            std::string const& type,
                            std::string* output,
                            char** error_out) {
    char pathTemplate[] = "/tmp/mapnik-cairo-XXXXXX";
    int fd = mkstemp(pathTemplate);
    if (fd < 0) {
        return report_error(error_out, "could not create temporary file for cairo rendering");
    }
    ::close(fd);

    try {
        mapnik::save_to_cairo_file(map, std::string(pathTemplate), type, scale_factor, 0.0);
    }
    catch (std::exception const& e) {
        ::remove(pathTemplate);
        return report_error(error_out, e.what());
    }

    std::ifstream file(pathTemplate, std::ios::in | std::ios::binary);
    if (!file) {
        ::remove(pathTemplate);
        return report_error(error_out, "could not read back temporary cairo file");
    }
    std::ostringstream buffer;
    buffer << file.rdbuf();
    file.close();
    ::remove(pathTemplate);

    *output = buffer.str();
    return true;
}

/// The vector surface types mapnik's cairo backend accepts.
bool is_cairo_type(std::string const& type) {
    return type == "svg" || type == "pdf" || type == "ps";
}

} // namespace

// ---------------------------------------------------------------------------
// Memory management
// ---------------------------------------------------------------------------

void mapnik_free_string(char* str) {
    delete[] str;
}

void mapnik_free_buffer(unsigned char* data) {
    delete[] data;
}

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

bool mapnik_init(const char* input_plugins_path,
                 const char* fonts_path,
                 char** error_out) {
    try {
        if (input_plugins_path != nullptr && *input_plugins_path != '\0') {
            mapnik::datasource_cache::instance().register_datasources(
                std::string(input_plugins_path), true /* recursive */);
        }
        if (fonts_path != nullptr && *fonts_path != '\0') {
            mapnik::freetype_engine::register_fonts(std::string(fonts_path), true /* recursive */);
        }
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, std::string("mapnik_init failed: ") + e.what());
    }
}

/// List the registered font-face names.
///
/// Returns a single NUL-separated string containing all face names
/// (`name\0name\0...\0name\0`, an empty sequence yields an empty string),
/// allocated with `new char[]` and released with `mapnik_free_string()`.
/// Returns NULL with details in `*error_out` on failure. Thread-safe: mapnik
/// holds the font registry state, so registration and enumeration share the
/// lifecycle mutex.
char* mapnik_available_fonts(char** error_out) {
    try {
        std::lock_guard<std::mutex> lock(mapnik_lifecycle_mutex());
        std::vector<std::string> const names = mapnik::freetype_engine::face_names();
        return copy_names_to_buffer(names, error_out);
    }
    catch (std::exception const& e) {
        report_error(error_out, e.what());
        return nullptr;
    }
}

// ---------------------------------------------------------------------------
// Map lifecycle
// ---------------------------------------------------------------------------

mapnik_map_t* mapnik_map_create(int width, int height) {
    try {
        std::lock_guard<std::mutex> lock(mapnik_lifecycle_mutex());
        return new mapnik_map_t{
            std::make_unique<mapnik::Map>(width, height, mapnik::MAPNIK_WEBMERCATOR_PROJ)};
    }
    catch (...) {
        return nullptr;
    }
}

mapnik_map_t* mapnik_map_create_with_srs(int width, int height, const char* srs) {
    try {
        if (srs == nullptr) {
            return nullptr;
        }
        std::lock_guard<std::mutex> lock(mapnik_lifecycle_mutex());
        return new mapnik_map_t{
            std::make_unique<mapnik::Map>(width, height, std::string(srs))};
    }
    catch (...) {
        return nullptr;
    }
}

bool mapnik_map_load_xml(mapnik_map_t* map, const char* xml, char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (xml == nullptr) {
        return report_error(error_out, "xml string is null");
    }
    try {
        std::lock_guard<std::mutex> lock(mapnik_lifecycle_mutex());
        mapnik::load_map_string(*map->map, std::string(xml));
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
}

bool mapnik_map_load_xml_file(mapnik_map_t* map, const char* path, char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (path == nullptr) {
        return report_error(error_out, "path is null");
    }
    try {
        std::lock_guard<std::mutex> lock(mapnik_lifecycle_mutex());
        mapnik::load_map(*map->map, std::string(path));
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
}

void mapnik_map_destroy(mapnik_map_t* map) {
    if (map != nullptr) {
        std::lock_guard<std::mutex> lock(mapnik_lifecycle_mutex());
        delete map;
    }
}

// ---------------------------------------------------------------------------
// Map properties
// ---------------------------------------------------------------------------

/// Serialize the current map (with any runtime modifications) back to XML.
///
/// Returns a string allocated with `new char[]` (release with
/// `mapnik_free_string()`), or NULL with details in `*error_out`. With
/// `explicit_defaults` the output carries every style/layer attribute even
/// when it equals mapnik's default, which makes round-tripping into other
/// tools more explicit.
char* mapnik_map_save_xml(mapnik_map_t* map,
                          bool explicit_defaults,
                          char** error_out) {
    if (!require_map(map, error_out)) {
        return nullptr;
    }
    try {
        std::string xml = mapnik::save_map_to_string(*map->map, explicit_defaults);
        char* result = new (std::nothrow) char[xml.size() + 1];
        if (result == nullptr) {
            report_error(error_out, "out of memory while serializing the map XML");
            return nullptr;
        }
        std::memcpy(result, xml.c_str(), xml.size() + 1);
        return result;
    }
    catch (std::exception const& e) {
        report_error(error_out, e.what());
        return nullptr;
    }
    catch (...) {
        report_error(error_out, "unknown error serializing the map XML");
        return nullptr;
    }
}

/// Serialize the current map back to an XML file (replaced if it exists).
bool mapnik_map_save_xml_to_file(mapnik_map_t* map,
                                 bool explicit_defaults,
                                 const char* output_path,
                                 char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (output_path == nullptr || *output_path == '\0') {
        return report_error(error_out, "output path must not be empty");
    }
    try {
        mapnik::save_map(*map->map, std::string(output_path), explicit_defaults);
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
    catch (...) {
        return report_error(error_out, "unknown error writing the map XML");
    }
}

void mapnik_map_resize(mapnik_map_t* map, int width, int height) {
    if (map != nullptr && map->map != nullptr && width > 0 && height > 0) {
        map->map->resize(width, height);
    }
}

int mapnik_map_width(mapnik_map_t* map) {
    return (map != nullptr && map->map != nullptr) ? static_cast<int>(map->map->width()) : 0;
}

int mapnik_map_height(mapnik_map_t* map) {
    return (map != nullptr && map->map != nullptr) ? static_cast<int>(map->map->height()) : 0;
}

void mapnik_map_set_buffer_size(mapnik_map_t* map, int buffer_pixels) {
    if (map != nullptr && map->map != nullptr) {
        map->map->set_buffer_size(buffer_pixels);
    }
}

int mapnik_map_buffer_size(mapnik_map_t* map) {
    return (map != nullptr && map->map != nullptr) ? map->map->buffer_size() : 0;
}

int mapnik_map_get_srs(mapnik_map_t* map, char* srs_out, int buffer_count) {
    if (map == nullptr || map->map == nullptr || srs_out == nullptr || buffer_count <= 0) {
        return -1;
    }
    try {
        std::string const srs = map->map->srs();
        int const length = static_cast<int>(srs.size());
        int const copy_length = std::min<int>(length, buffer_count - 1);
        std::memcpy(srs_out, srs.data(), static_cast<std::size_t>(copy_length));
        srs_out[copy_length] = '\0';
        return length;
    }
    catch (...) {
        return -1;
    }
}

bool mapnik_map_set_srs(mapnik_map_t* map, const char* srs, char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (srs == nullptr || *srs == '\0') {
        return report_error(error_out, "srs string is empty");
    }
    try {
        // Validate eagerly: mapnik::projection throws on an unknown
        // projection, and zoom_to_box would only surface the problem later.
        mapnik::projection check(srs);
        (void)check;
        map->map->set_srs(std::string(srs));
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, std::string("invalid srs: ") + e.what());
    }
}

void mapnik_map_zoom_to_box(mapnik_map_t* map,
                            double minx,
                            double miny,
                            double maxx,
                            double maxy) {
    if (map != nullptr && map->map != nullptr) {
        map->map->zoom_to_box(mapnik::box2d<double>(minx, miny, maxx, maxy));
    }
}

/// Zoom to a WGS 84 (lon/lat degrees) bounding box, reprojecting it to the
/// map's SRS first. Lets callers with geographic boxes target maps in any
/// projection (Web Mercator and others) without knowing the SRS.
///
/// The box edges are sampled (16 points per side) before transformation so
/// skewed projections produce a sufficiently tight envelope.
bool mapnik_map_zoom_to_wgs84_box(mapnik_map_t* map,
                                  double minx,
                                  double miny,
                                  double maxx,
                                  double maxy,
                                  char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    try {
        mapnik::box2d<double> box(minx, miny, maxx, maxy);
        mapnik::projection source("+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs");
        mapnik::projection dest(map->map->srs());
        mapnik::proj_transform transform(source, dest);
        mapnik::box2d<double> transformed = box;
        if (!transform.forward(transformed, 16)) {
            return report_error(error_out,
                "could not transform the bounding box to the map SRS — check that the SRS is valid");
        }
        map->map->zoom_to_box(transformed);
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, std::string("zoom to box failed: ") + e.what());
    }
}

void mapnik_map_get_extent(mapnik_map_t* map,
                           double* minx,
                           double* miny,
                           double* maxx,
                           double* maxy) {
    if (map == nullptr || map->map == nullptr || minx == nullptr || miny == nullptr
        || maxx == nullptr || maxy == nullptr) {
        return;
    }
    try {
        mapnik::box2d<double> const& extent = map->map->get_current_extent();
        *minx = extent.minx();
        *miny = extent.miny();
        *maxx = extent.maxx();
        *maxy = extent.maxy();
    }
    catch (...) {
    }
}

bool mapnik_map_zoom_all(mapnik_map_t* map, char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    try {
        map->map->zoom_all();
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, std::string("zoom_all failed: ") + e.what());
    }
}

// ---------------------------------------------------------------------------
// Layers
// ---------------------------------------------------------------------------

int mapnik_map_layer_count(mapnik_map_t* map) {
    if (map == nullptr || map->map == nullptr) {
        return 0;
    }
    try {
        return static_cast<int>(map->map->layer_count());
    }
    catch (...) {
        return 0;
    }
}

const char* mapnik_map_layer_name(mapnik_map_t* map, int index) {
    if (map == nullptr || map->map == nullptr || index < 0) {
        return nullptr;
    }
    try {
        std::size_t const i = static_cast<std::size_t>(index);
        if (i >= map->map->layer_count()) {
            return nullptr;
        }
        // The returned string_view stays valid as long as the map lives.
        return map->map->get_layer(i).name().c_str();
    }
    catch (...) {
        return nullptr;
    }
}

bool mapnik_map_set_layer_visible(mapnik_map_t* map, int index, bool visible) {
    if (map == nullptr || map->map == nullptr || index < 0) {
        return false;
    }
    try {
        std::size_t const i = static_cast<std::size_t>(index);
        if (i >= map->map->layer_count()) {
            return false;
        }
        map->map->get_layer(i).set_active(visible);
        return true;
    }
    catch (...) {
        return false;
    }
}

bool mapnik_map_layer_visible(mapnik_map_t* map, int index, bool* visible) {
    if (map == nullptr || map->map == nullptr || index < 0 || visible == nullptr) {
        return false;
    }
    try {
        std::size_t const i = static_cast<std::size_t>(index);
        if (i >= map->map->layer_count()) {
            return false;
        }
        *visible = map->map->get_layer(i).active();
        return true;
    }
    catch (...) {
        return false;
    }
}

/// The geographic envelope of the layer at `index`, in the layer's own SRS.
///
/// Returns true and writes the box into the out-parameters, or false when
/// the index is out of range or the layer has no datasource.
bool mapnik_map_layer_envelope(mapnik_map_t* map,
                               int index,
                               double* minx,
                               double* miny,
                               double* maxx,
                               double* maxy,
                               char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (index < 0 || minx == nullptr || miny == nullptr || maxx == nullptr || maxy == nullptr) {
        return report_error(error_out, "invalid parameters for layer envelope");
    }
    try {
        std::size_t const i = static_cast<std::size_t>(index);
        if (i >= map->map->layer_count()) {
            return report_error(error_out, "layer index out of range");
        }
        mapnik::box2d<double> const& envelope = map->map->get_layer(i).envelope();
        if (!envelope.valid()) {
            return report_error(error_out, "layer envelope is not valid (no datasource attached?)");
        }
        *minx = envelope.minx();
        *miny = envelope.miny();
        *maxx = envelope.maxx();
        *maxy = envelope.maxy();
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
    catch (...) {
        return report_error(error_out, "unknown error reading the layer envelope");
    }
}

/// The layer's projection string (a PROJ.4 string or an EPSG code).
///
/// Writes up to `buffer_count`-1 bytes of the SRS string plus a NUL
/// terminator into `srs_out`. Returns the full length of the string, or -1
/// when the map or index is invalid.
int mapnik_map_layer_srs(mapnik_map_t* map, int index, char* srs_out, int buffer_count) {
    if (map == nullptr || map->map == nullptr || index < 0 || srs_out == nullptr || buffer_count <= 0) {
        return -1;
    }
    try {
        std::size_t const i = static_cast<std::size_t>(index);
        if (i >= map->map->layer_count()) {
            return -1;
        }
        std::string const& srs = map->map->get_layer(i).srs();
        std::size_t const length = std::min(srs.size(), static_cast<std::size_t>(buffer_count) - 1);
        std::memcpy(srs_out, srs.c_str(), length);
        srs_out[length] = '\0';
        return static_cast<int>(srs.size());
    }
    catch (...) {
        return -1;
    }
}

/// Whether the layer at `index` is queryable.
///
/// Writes `*queryable` and returns true, or returns false when the index is
/// out of range.
bool mapnik_map_layer_queryable(mapnik_map_t* map, int index, bool* queryable) {
    if (map == nullptr || map->map == nullptr || index < 0 || queryable == nullptr) {
        return false;
    }
    try {
        std::size_t const i = static_cast<std::size_t>(index);
        if (i >= map->map->layer_count()) {
            return false;
        }
        *queryable = map->map->get_layer(i).queryable();
        return true;
    }
    catch (...) {
        return false;
    }
}

/// Whether the layer at `index` renders at the given scale denominator
/// (respecting the layer's min/max scale denominators and visibility).
bool mapnik_map_layer_visible_at_scale(mapnik_map_t* map,
                                       int index,
                                       double scale_denominator,
                                       bool* visible) {
    if (map == nullptr || map->map == nullptr || index < 0 || visible == nullptr) {
        return false;
    }
    try {
        std::size_t const i = static_cast<std::size_t>(index);
        if (i >= map->map->layer_count()) {
            return false;
        }
        *visible = map->map->get_layer(i).visible(scale_denominator);
        return true;
    }
    catch (...) {
        return false;
    }
}

/// Zooms the map to the layer's envelope, reprojected from the layer's SRS
/// to the map's SRS (the box edges are sampled so skewed projections produce
/// a tight envelope). Returns false with details in `*error_out` on failure.
bool mapnik_map_zoom_to_layer(mapnik_map_t* map,
                              int index,
                              char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    try {
        std::size_t const i = static_cast<std::size_t>(index);
        if (i >= map->map->layer_count()) {
            return report_error(error_out, "layer index out of range");
        }
        mapnik::layer const& layer = map->map->get_layer(i);
        mapnik::box2d<double> envelope = layer.envelope();
        if (!envelope.valid()) {
            return report_error(error_out, "layer envelope is not valid (no datasource attached?)");
        }

        mapnik::projection source(layer.srs(), true);
        mapnik::projection dest(map->map->srs(), true);
        if (source == dest) {
            map->map->zoom_to_box(envelope);
            return true;
        }
        mapnik::proj_transform transform(source, dest);
        if (!transform.forward(envelope, 8)) {
            return report_error(error_out, "could not transform the layer envelope to the map SRS");
        }
        map->map->zoom_to_box(envelope);
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
    catch (...) {
        return report_error(error_out, "unknown error zooming to the layer");
    }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

bool mapnik_map_render_to_buffer(mapnik_map_t* map,
                                 const char* type,
                                 bool skip_empty,
                                 unsigned char** data,
                                 unsigned long* size,
                                 bool* is_empty,
                                 char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    try {
        std::string const type_string = (type != nullptr && *type != '\0') ? type : "png";
        auto image = render_view(*map->map, 1.0);
        return encode_image(*image, type_string, skip_empty, data, size, is_empty, error_out);
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
}

bool mapnik_map_render_to_file(mapnik_map_t* map,
                               const char* type,
                               const char* output_path,
                               char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (output_path == nullptr || *output_path == '\0') {
        return report_error(error_out, "output path must not be empty");
    }
    try {
        std::string const type_string = (type != nullptr && *type != '\0') ? type : "png";
        auto image = render_view(*map->map, 1.0);
        mapnik::save_to_file(*image, std::string(output_path), type_string);
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
}

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
                                      char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (!validate_tile_coordinates(tile_x, tile_y, zoom, error_out)) {
        return false;
    }
    if (tile_size <= 0) {
        return report_error(error_out, "tile_size must be positive");
    }
    if (scale_factor <= 0.0) {
        return report_error(error_out, "scale_factor must be positive");
    }
    try {
        std::string const type_string = (type != nullptr && *type != '\0') ? type : "png";
        auto image = render_tile_view(*map->map, tile_x, tile_y, zoom, tile_size, scale_factor);
        return encode_image(*image, type_string, skip_empty, data, size, is_empty, error_out);
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
}

bool mapnik_map_render_tile_to_file(mapnik_map_t* map,
                                    int tile_x,
                                    int tile_y,
                                    int zoom,
                                    int tile_size,
                                    double scale_factor,
                                    const char* type,
                                    const char* output_path,
                                    char** error_out) {
    unsigned char* data = nullptr;
    unsigned long size = 0;
    bool is_empty = false;

    if (!mapnik_map_render_tile_to_buffer(map, tile_x, tile_y, zoom, tile_size, scale_factor,
                                          type, true, &data, &size, &is_empty, error_out)) {
        return false;
    }
    if (data == nullptr) {
        return report_error(error_out, "tile is empty, nothing written");
    }

    bool const result = [&]() -> bool {
        std::FILE* file = std::fopen(output_path, "wb");
        if (file == nullptr) {
            return report_error(error_out, std::string("could not open '") + output_path + "' for writing");
        }
        std::size_t const written = std::fwrite(data, 1, size, file);
        std::fclose(file);
        if (written != size) {
            return report_error(error_out, std::string("short write to '") + output_path + "'");
        }
        return true;
    }();

    mapnik_free_buffer(data);
    return result;
}

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
                                char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (!validate_tile_coordinates(tile_x, tile_y, zoom, error_out)) {
        return false;
    }
    if (tile_size <= 0) {
        return report_error(error_out, "tile_size must be positive");
    }
    if (scale_factor <= 0.0) {
        return report_error(error_out, "scale_factor must be positive");
    }
    if (meta_size <= 0) {
        return report_error(error_out, "meta_size must be positive");
    }
    if (data == nullptr || size == nullptr || out_width == nullptr || out_height == nullptr) {
        return report_error(error_out, "output pointers must not be null");
    }

    try {
        auto image = render_metatile_view(*map->map, tile_x, tile_y, zoom, tile_size, scale_factor, meta_size);
        if (is_empty != nullptr) {
            *is_empty = is_fully_transparent(*image);
        }
        *out_width = static_cast<int>(image->width());
        *out_height = static_cast<int>(image->height());
        return copy_image_to_output_buffer(*image, data, size, error_out);
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
}

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
                              char** error_out) {
    if (src == nullptr) {
        return report_error(error_out, "source buffer must not be null");
    }
    if (data == nullptr || size == nullptr) {
        return report_error(error_out, "output pointers must not be null");
    }
    if (type == nullptr || *type == '\0') {
        return report_error(error_out, "image type must not be empty");
    }
    try {
        return crop_encode(src, src_width, src_height, offset_x, offset_y,
                           crop_width, crop_height, type, skip_empty,
                           data, size, is_empty, error_out);
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
}

bool mapnik_map_render_to_cairo_buffer(mapnik_map_t* map,
                                       double scale_factor,
                                       const char* type,
                                       unsigned char** data,
                                       unsigned long* size,
                                       char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (scale_factor <= 0.0) {
        return report_error(error_out, "scale_factor must be positive");
    }
    std::string const type_string = (type != nullptr && *type != '\0') ? type : "svg";
    if (!is_cairo_type(type_string)) {
        return report_error(error_out, "unsupported cairo type '" + type_string + "' (svg, pdf, ps)");
    }
    try {
        std::string output;
        if (!render_cairo_to_buffer(*map->map, scale_factor, type_string, &output, error_out)) {
            return false;
        }
        if (output.empty()) {
            return report_error(error_out, "cairo produced no output");
        }
        return copy_to_output_buffer(output, data, size, error_out);
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
}

bool mapnik_map_render_to_cairo_file(mapnik_map_t* map,
                                     double scale_factor,
                                     const char* type,
                                     const char* output_path,
                                     char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (output_path == nullptr || *output_path == '\0') {
        return report_error(error_out, "output path must not be empty");
    }
    std::string const type_string = (type != nullptr && *type != '\0') ? type : "svg";
    if (!is_cairo_type(type_string)) {
        return report_error(error_out, "unsupported cairo type '" + type_string + "' (svg, pdf, ps)");
    }
    try {
        mapnik::save_to_cairo_file(*map->map, std::string(output_path), type_string, scale_factor, 0.0);
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
}

/// Transform a WGS 84 (lon/lat degrees) point into the map's SRS.
///
/// Writes the projected coordinates into `*out_x`/`*out_y`. Returns false
/// with details in `*error_out` when the map's SRS is invalid or the point
/// cannot be projected.
bool mapnik_map_project_from_wgs84(mapnik_map_t* map,
                                   double lon,
                                   double lat,
                                   double* out_x,
                                   double* out_y,
                                   char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (out_x == nullptr || out_y == nullptr) {
        return report_error(error_out, "output pointers must not be null");
    }
    try {
        mapnik::projection source("+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs");
        mapnik::projection dest(map->map->srs(), true);
        mapnik::proj_transform transform(source, dest);

        double x = lon;
        double y = lat;
        double z = 0.0;
        if (!transform.forward(x, y, z)) {
            return report_error(error_out, "could not project the point into the map SRS");
        }
        *out_x = x;
        *out_y = y;
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
}

// ---------------------------------------------------------------------------
// Feature queries
// ---------------------------------------------------------------------------
// Datasource inspection
// ---------------------------------------------------------------------------

namespace {

/// JSON-escape a string per RFC 8259.
std::string json_escape(std::string const& value) {
    std::string out;
    out.reserve(value.size() + 8);
    for (unsigned char const c : value) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buffer[8];
                    std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
                    out += buffer;
                }
                else {
                    out.push_back(static_cast<char>(c));
                }
        }
    }
    return out;
}

/// Format a floating point value the way mapnik's value.to_string() does
/// (via ostringstream, default precision).
std::string json_number(double value) {
    std::ostringstream stream;
    stream << value;
    std::string text = stream.str();
    return (text == "-0") ? "0" : text;
}

/// Attribute type name matching mapnik's eAttributeType enum.
char const* attribute_type_name(unsigned type) {
    switch (type) {
        case mapnik::Integer:  return "Integer";
        case mapnik::Float:    return "Float";
        case mapnik::Double:   return "Double";
        case mapnik::String:   return "String";
        case mapnik::Boolean:  return "Boolean";
        case mapnik::Geometry: return "Geometry";
        case mapnik::Object:   return "Object";
        default:               return "Unknown";
    }
}

char const* geometry_type_name(mapnik::datasource_geometry_t type) {
    switch (type) {
        case mapnik::Point:      return "point";
        case mapnik::LineString: return "linestring";
        case mapnik::Polygon:    return "polygon";
        case mapnik::Collection: return "collection";
        default:                 return "unknown";
    }
}

/// Serialize a mapnik value as a typed JSON value (null, bool, number or
/// string — the variant's active alternative decides, not a lossy string
/// conversion).
std::string json_feature_value(mapnik::value const& v) {
    try {
        switch (v.which()) {
            case 0: // value_null
                return "null";
            case 1: // value_bool
                return v.to_bool() ? "true" : "false";
            case 2: // value_integer
                return std::to_string(v.to_int());
            case 3: // value_double
                return json_number(v.to_double());
            default: // value_unicode_string
                return "\"" + json_escape(v.to_string()) + "\"";
        }
    }
    catch (...) {
        return "null";
    }
}

/// Serialize a feature into the shared query JSON schema:
///   {"id":<id>,"wkb":"<hex>","properties":{"name":value-as-string,...}}
/// The geometry is generic little-endian WKB hex; empty geometries (points
/// without coordinates, empty collections) emit `"wkb":null`.
/// The WKB hex string for a feature's geometry, or "null" for empty or
/// unserializable geometries.
std::string json_feature_wkb(mapnik::feature_impl const& feature) {
    mapnik::geometry::geometry<double> const& geometry = feature.get_geometry();
    if (geometry.is<mapnik::geometry::geometry_empty>()) {
        return "null";
    }
    try {
        mapnik::util::wkb_buffer_ptr wkb =
            mapnik::util::to_wkb(geometry, mapnik::wkbNDR);
        if (!wkb || wkb->size() == 0) {
            return "null";
        }
        std::ostringstream json;
        json << "\"";
        for (std::size_t i = 0; i < wkb->size(); ++i) {
            char hex[3];
            std::snprintf(hex, sizeof(hex), "%02x",
                          static_cast<int>(wkb->buffer()[i]) & 0xff);
            json << hex;
        }
        json << "\"";
        return json.str();
    }
    catch (...) {
        return "null";
    }
}

/// Serialize a feature's attributes only: `{"name":value,...}` — the
/// datasource inspection sample schema.
std::string json_feature_properties(mapnik::feature_impl const& feature,
                                    std::set<std::string> const& filter = {}) {
    std::ostringstream json;
    json << "{";
    bool first = true;
    for (auto const& kv : feature) {
        if (!filter.empty() && filter.count(std::get<0>(kv)) == 0) {
            continue;
        }
        if (!first) {
            json << ",";
        }
        first = false;
        json << "\"" << json_escape(std::get<0>(kv)) << "\":"
             << json_feature_value(std::get<1>(kv));
    }
    json << "}";
    return json.str();
}

/// Serialize a feature as `{"id":..[,"wkb":<hex>]...,"properties":{...}}`.
/// With `include_geometry == false` the schema matches the datasource
/// inspection samples (no geometry field). With a non-empty `filter`, only
/// the named attributes are emitted (the plugins themselves do not filter).
std::string json_feature(mapnik::feature_impl const& feature,
                         bool include_geometry,
                         std::set<std::string> const& filter = {}) {
    std::ostringstream json;
    json << "{\"id\":" << feature.id();
    if (include_geometry) {
        json << ",\"wkb\":" << json_feature_wkb(feature);
    }

    json << ",\"properties\":{";
    bool first = true;
    for (auto const& kv : feature) {
        if (!filter.empty() && filter.count(std::get<0>(kv)) == 0) {
            continue;
        }
        if (!first) {
            json << ",";
        }
        first = false;
        json << "\"" << json_escape(std::get<0>(kv)) << "\":"
             << json_feature_value(std::get<1>(kv));
    }
    json << "}}";
    return json.str();
}

/// Iterate a featureset and serialize up to `max_features` features as a
/// JSON array body (without the surrounding braces). Returns false when
/// iteration threw (the caller then reports the error).
bool features_to_json(mapnik::featureset_ptr const& features,
                      int max_features,
                      std::string* output,
                      std::string* error_message,
                      std::set<std::string> const& filter = {}) {
    std::ostringstream json_stream;
    int emitted = 0;
    if (features) {
        // An "invalid" featureset (mapnik's make_invalid_featureset) simply
        // returns a null feature from next() — the loop handles that.
        while (emitted < max_features) {
            mapnik::feature_ptr feature;
            try {
                feature = features->next();
            }
            catch (std::exception const& e) {
                *error_message = e.what();
                return false;
            }
            if (!feature) {
                break;
            }
            if (emitted > 0) {
                json_stream << ",";
            }
            ++emitted;
            json_stream << json_feature(*feature, true, filter);
        }
    }
    *output = json_stream.str();
    return true;
}

/// The lon/lat extent of `box`, transformed from `srs`, clamped to valid
/// geographic bounds like TileMill's datasource inspection.
bool unprojected_extent(mapnik::box2d<double> box,
                        std::string const& srs,
                        mapnik::box2d<double>* output,
                        std::string* message) {
    try {
        mapnik::projection source(srs);
        mapnik::projection dest("+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs");
        mapnik::proj_transform transform(source, dest);
        // Sample the box edges: a plain forward() of the corner box can
        // collapse on skewed projections; 8 points per side is plenty for
        // inspection purposes.
        if (!transform.forward(box, 8)) {
            *message = "could not transform the datasource extent to lon/lat — check the layer SRS";
            return false;
        }
        *output = box;
        return true;
    }
    catch (std::exception const& e) {
        *message = e.what();
        return false;
    }
}

} // namespace

// ---------------------------------------------------------------------------
// Feature queries
// ---------------------------------------------------------------------------

bool mapnik_map_query_point(mapnik_map_t* map,
                            int layer_index,
                            double x,
                            double y,
                            int max_features,
                            char** json_out,
                            char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (json_out == nullptr) {
        return report_error(error_out, "output pointer must not be null");
    }
    if (max_features <= 0) {
        return report_error(error_out, "max_features must be positive");
    }
    try {
        if (layer_index < 0 || static_cast<std::size_t>(layer_index) >= map->map->layer_count()) {
            return report_error(error_out, "layer index out of range");
        }
        // mapnik's query_point ignores the layer's visibility flag (a
        // render would skip hidden layers); apply the same rule here.
        if (!map->map->get_layer(static_cast<std::size_t>(layer_index)).active()) {
            *json_out = allocate_error_message("{\"features\":[]}");
            return *json_out != nullptr;
        }

        mapnik::featureset_ptr features = map->map->query_point(
            static_cast<unsigned>(layer_index), x, y);
        if (!features) {
            *json_out = allocate_error_message("{\"features\":[]}");
            return *json_out != nullptr;
        }

        std::string body;
        std::string iteration_error;
        if (!features_to_json(features, max_features, &body, &iteration_error)) {
            return report_error(error_out, iteration_error);
        }

        std::string result = "{\"features\":[" + body + "]}";
        *json_out = allocate_error_message(result);
        return *json_out != nullptr;
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
    catch (...) {
        return report_error(error_out, "unknown error querying the map layer");
    }
}


mapnik_datasource_t* mapnik_datasource_create(const char* const* keys,
                                              const char* const* values,
                                              int count,
                                              char** error_out) {
    if (count < 0) {
        report_error(error_out, "count must not be negative");
        return nullptr;
    }
    if (count > 0 && (keys == nullptr || values == nullptr)) {
        report_error(error_out, "keys/values arrays must not be null");
        return nullptr;
    }

    try {
        mapnik::parameters params;
        for (int i = 0; i < count; ++i) {
            if (keys[i] == nullptr || values[i] == nullptr) {
                report_error(error_out, "null key or value at index " + std::to_string(i));
                return nullptr;
            }
            params[std::string(keys[i])] = std::string(values[i]);
        }

        std::lock_guard<std::mutex> lock(mapnik_lifecycle_mutex());
        auto datasource = mapnik::datasource_cache::instance().create(params);
        if (!datasource) {
            report_error(error_out, "could not create datasource (missing plugin?)");
            return nullptr;
        }
        return new mapnik_datasource_t{std::move(datasource)};
    }
    catch (std::exception const& e) {
        report_error(error_out, e.what());
        return nullptr;
    }
    catch (...) {
        report_error(error_out, "unknown error creating datasource");
        return nullptr;
    }
}

void mapnik_datasource_destroy(mapnik_datasource_t* datasource) {
    delete datasource;
}

char* mapnik_datasource_inspect(mapnik_datasource_t* datasource,
                                const char* srs,
                                int max_features,
                                const char* const* field_names,
                                int field_count,
                                char** error_out) {
    if (datasource == nullptr || datasource->datasource == nullptr) {
        report_error(error_out, "datasource is not initialized");
        return nullptr;
    }
    std::string const layer_srs = (srs != nullptr && *srs != '\0') ? srs : std::string(mapnik::MAPNIK_WEBMERCATOR_PROJ);
    if (max_features < 0) {
        report_error(error_out, "max_features must not be negative");
        return nullptr;
    }
    if (field_count > 0 && field_names == nullptr) {
        report_error(error_out, "field_names must not be null when field_count > 0");
        return nullptr;
    }

    try {
        mapnik::datasource& source = *datasource->datasource;
        std::ostringstream json;

        bool const is_raster = (source.type() == mapnik::datasource::Raster);
        json << "{\"type\":\"" << (is_raster ? "raster" : "vector") << "\"";

        // Geometry type (null for raster datasources).
        if (!is_raster) {
            char const* geometry = "unknown";
            if (auto const gt = source.get_geometry_type()) {
                geometry = geometry_type_name(*gt);
            }
            json << ",\"geometry_type\":\"" << geometry << "\"";
        }
        else {
            json << ",\"geometry_type\":null";
        }

        // Native extent.
        mapnik::box2d<double> const extent = source.envelope();
        json << ",\"extent\":[" << json_number(extent.minx()) << "," << json_number(extent.miny())
             << "," << json_number(extent.maxx()) << "," << json_number(extent.maxy()) << "]";

        // Geographic (lon/lat) extent, clamped like TileMill did.
        json << ",\"unproj_extent\":";
        mapnik::box2d<double> unproj;
        std::string transform_message;
        if (unprojected_extent(extent, layer_srs, &unproj, &transform_message)) {
            double const minx = unproj.minx() < -180.0 ? -180.0 : unproj.minx();
            double const miny = unproj.miny() < -85.051 ? -85.051 : unproj.miny();
            double const maxx = unproj.maxx() > 180.0 ? 180.0 : unproj.maxx();
            double const maxy = unproj.maxy() > 85.051 ? 85.051 : unproj.maxy();
            json << "[" << json_number(minx) << "," << json_number(miny)
                 << "," << json_number(maxx) << "," << json_number(maxy) << "]";
        }
        else {
            // No usable SRS: report a null extent rather than failing the
            // whole inspection — the field/feature lists are still valuable.
            json << "null";
            transform_message.clear();
        }

        // Field descriptors from the datasource's layer descriptor. With a
        // field filter, only matching names are listed and sampled.
        std::vector<std::pair<std::string, std::string>> fields;
        std::set<std::string> field_filter;
        for (int i = 0; i < field_count; ++i) {
            if (field_names[i] != nullptr) {
                field_filter.insert(std::string(field_names[i]));
            }
        }

        if (!is_raster) {
            mapnik::layer_descriptor const desc = source.get_descriptor();
            fields.reserve(desc.get_descriptors().size());
            json << ",\"fields\":[";
            bool first = true;
            for (auto const& descriptor : desc.get_descriptors()) {
                if (!field_filter.empty() && field_filter.count(descriptor.get_name()) == 0) {
                    continue;
                }
                std::string const name = "\"" + json_escape(descriptor.get_name())
                    + "\",\"" + attribute_type_name(descriptor.get_type()) + "\"";
                fields.emplace_back(descriptor.get_name(), attribute_type_name(descriptor.get_type()));
                if (!first) {
                    json << ",";
                }
                first = false;
                json << "[" << name << "]";
            }
            json << "]";
        }
        else {
            json << ",\"fields\":[]";
        }

        // Feature samples (vector datasources only).
        json << ",\"features\":[";
        int emitted = 0;
        if (!is_raster && max_features > 0) {
            try {
                mapnik::query query(extent);
                for (auto const& field : fields) {
                    query.add_property_name(field.first);
                }
                mapnik::featureset_ptr features = source.features(query);
                if (features) {
                    // Note: an "invalid" featureset (mapnik's
                    // make_invalid_featureset) simply returns a null feature
                    // from next() — the loop below handles that on its own.
                    while (emitted < max_features) {
                        mapnik::feature_ptr feature = features->next();
                        if (!feature) {
                            break;
                        }
                        if (emitted > 0) {
                            json << ",";
                        }
                        ++emitted;
                        // Inspection samples carry the attributes directly
                        // (no id/geometry wrapper, matching the documented
                        // schema).
                        json << json_feature_properties(*feature, field_filter);
                    }
                }
            }
            catch (std::exception const& e) {
                // Feature iteration failures (e.g. a broken SQL query) must
                // not discard the field list; the samples are simply absent
                // and a `feature_error` note carries the message.
                json << "],\"feature_error\":\"" << json_escape(e.what()) << "\"";
                json << "}";
                char* result = allocate_error_message(json.str());
                if (result == nullptr) {
                    report_error(error_out, "out of memory");
                    return nullptr;
                }
                return result;
            }
        }
        json << "]";

        json << "}";
        char* result = allocate_error_message(json.str());
        if (result == nullptr) {
            report_error(error_out, "out of memory");
            return nullptr;
        }
        return result;
    }
    catch (std::exception const& e) {
        report_error(error_out, e.what());
        return nullptr;
    }
    catch (...) {
        report_error(error_out, "unknown error inspecting datasource");
        return nullptr;
    }
}

int mapnik_datasource_ogr_layers(mapnik_datasource_t* datasource,
                                 const char** layers_out,
                                 int buffer_count,
                                 char** error_out) {
    if (datasource == nullptr || datasource->datasource == nullptr) {
        report_error(error_out, "datasource is not initialized");
        return -1;
    }

    // Recreating the datasource surfaces the OGR "missing <layer>" exception
    // that carries the layer list (same trick TileMill used).
    try {
        mapnik::parameters const& params = datasource->datasource->params();
        mapnik::parameters retry = params;
        retry["layer_by_index"] = "0";

        std::lock_guard<std::mutex> lock(mapnik_lifecycle_mutex());
        mapnik::datasource_cache::instance().create(retry);
        // No exception: not an OGR-multi-layer datasource.
        report_error(error_out, "datasource has no sub-layers");
        return -1;
    }
    catch (mapnik::datasource_exception const& e) {
        std::string const message = e.what();
        std::size_t const marker = message.find("are: ");
        if (marker == std::string::npos) {
            report_error(error_out, message);
            return -1;
        }

        std::string const list = message.substr(marker + 5);
        std::vector<std::string> names;
        std::size_t start = 0;
        while (start <= list.size()) {
            std::size_t const comma = list.find(',', start);
            std::string name = list.substr(start, (comma == std::string::npos) ? std::string::npos : comma - start);
            // Trim whitespace and surrounding quotes.
            while (!name.empty() && (name.front() == ' ' || name.front() == '\'')) name.erase(name.begin());
            while (!name.empty() && (name.back() == ' ' || name.back() == '\'')) name.pop_back();
            if (!name.empty()) {
                names.push_back(name);
            }
            if (comma == std::string::npos) {
                break;
            }
            start = comma + 1;
        }

        if (layers_out != nullptr) {
            // The strings handed out must survive until the caller has copied
            // them: keep the names in a call-spanning static buffer whose
            // contents stay valid until the next invocation.
            static std::mutex storage_mutex;
            static std::vector<std::string> storage;
            std::lock_guard<std::mutex> storage_lock(storage_mutex);
            storage = names;
            int const copied = std::min(static_cast<int>(names.size()), buffer_count);
            for (int i = 0; i < copied; ++i) {
                layers_out[i] = storage[static_cast<std::size_t>(i)].c_str();
            }
            return static_cast<int>(names.size());
        }
        return static_cast<int>(names.size());
    }
    catch (std::exception const& e) {
        report_error(error_out, e.what());
        return -1;
    }
}

bool mapnik_datasource_query_box(mapnik_datasource_t* datasource,
                                 double minx,
                                 double miny,
                                 double maxx,
                                 double maxy,
                                 int max_features,
                                 char** json_out,
                                 char** error_out) {
    if (datasource == nullptr || datasource->datasource == nullptr) {
        return report_error(error_out, "datasource is not initialized");
    }
    if (json_out == nullptr) {
        return report_error(error_out, "output pointer must not be null");
    }
    if (max_features <= 0) {
        return report_error(error_out, "max_features must be positive");
    }
    try {
        mapnik::box2d<double> box(minx, miny, maxx, maxy);
        if (!box.valid()) {
            return report_error(error_out, "query box is not valid (min > max)");
        }

        // The query box is in the datasource's native SRS (the same SRS
        // inspect() reports its extent in).
        try {
            mapnik::query query(box, mapnik::query::resolution_type(1.0, 1.0), 0.0);
            mapnik::featureset_ptr features = datasource->datasource->features(query);
            if (!features) {
                *json_out = allocate_error_message("{\"features\":[]}");
                return *json_out != nullptr;
            }

            std::string body;
            std::string iteration_error;
            if (!features_to_json(features, max_features, &body, &iteration_error)) {
                return report_error(error_out, iteration_error);
            }

            std::string result = "{\"features\":[" + body + "]}";
            *json_out = allocate_error_message(result);
            return *json_out != nullptr;
        }
        catch (std::exception const& e) {
            return report_error(error_out, e.what());
        }
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
    catch (...) {
        return report_error(error_out, "unknown error querying the datasource");
    }
}

// ---------------------------------------------------------------------------
// Counting datasource (test instrumentation)
// ---------------------------------------------------------------------------

struct mapnik_counting_datasource {
    // A shared_ptr so the datasource can be attached to a map layer (mapnik
    // layers hold their datasource as shared_ptr<datasource>).
    std::shared_ptr<counting_datasource_impl> datasource;
};

mapnik_counting_datasource_t* mapnik_counting_datasource_create(void) {
    try {
        return new mapnik_counting_datasource_t{std::make_shared<counting_datasource_impl>()};
    }
    catch (...) {
        return nullptr;
    }
}

void mapnik_counting_datasource_destroy(mapnik_counting_datasource_t* datasource) {
    delete datasource;
}

bool mapnik_counting_datasource_push_polygon(mapnik_counting_datasource_t* datasource,
                                             const unsigned char* wkb,
                                             unsigned long wkb_size,
                                             const char* name,
                                             char** error_out) {
    if (datasource == nullptr || datasource->datasource == nullptr) {
        return report_error(error_out, "datasource is not initialized");
    }
    if (wkb == nullptr || wkb_size == 0) {
        return report_error(error_out, "wkb must not be empty");
    }
    try {
        auto ctx = std::make_shared<mapnik::context_type>();
        ctx->push("name");
        auto feature = std::make_shared<mapnik::feature_impl>(ctx, 1);
        auto geometry = mapnik::geometry_utils::from_wkb(
            reinterpret_cast<char const*>(wkb), wkb_size, mapnik::wkbGeneric);
        feature->set_geometry(std::move(geometry));
        feature->put_new("name", mapnik::value_unicode_string(name != nullptr ? name : ""));
        datasource->datasource->push(feature);
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
}

bool mapnik_map_use_counting_datasource(mapnik_map_t* map,
                                        int layer_index,
                                        mapnik_counting_datasource_t* datasource,
                                        char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (datasource == nullptr || datasource->datasource == nullptr) {
        return report_error(error_out, "datasource is not initialized");
    }
    try {
        if (layer_index < 0 || static_cast<std::size_t>(layer_index) >= map->map->layer_count()) {
            return report_error(error_out, "layer index out of range");
        }
        map->map->get_layer(static_cast<std::size_t>(layer_index))
            .set_datasource(datasource->datasource);
        return true;
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
}

int mapnik_counting_datasource_query_count(mapnik_counting_datasource_t* datasource) {
    if (datasource == nullptr || datasource->datasource == nullptr) {
        return -1;
    }
    return datasource->datasource->query_count.load();
}

// ---------------------------------------------------------------------------
// Palettes
// ---------------------------------------------------------------------------

mapnik_palette_t* mapnik_palette_create(const unsigned int* colors,
                                        int color_count,
                                        char** error_out) {
    try {
        if (colors == nullptr || color_count <= 0 || color_count > 256) {
            report_error(error_out, "palette must contain between 1 and 256 colors");
            return nullptr;
        }

        std::string packed;
        packed.reserve(static_cast<std::size_t>(color_count) * 4);
        for (int i = 0; i < color_count; ++i) {
            unsigned const c = colors[i];
            // rgba_palette parses bytes in RGBA order.
            packed.push_back(static_cast<char>((c >> 16) & 0xFF)); // R
            packed.push_back(static_cast<char>((c >> 8) & 0xFF));  // G
            packed.push_back(static_cast<char>(c & 0xFF));         // B
            packed.push_back(static_cast<char>((c >> 24) & 0xFF)); // A
        }

        auto* wrapper = new (std::nothrow) mapnik_palette();
        if (wrapper == nullptr) {
            report_error(error_out, "out of memory");
            return nullptr;
        }
        try {
            wrapper->palette = std::make_unique<mapnik::rgba_palette>(
                packed, mapnik::rgba_palette::PALETTE_RGBA);
        }
        catch (...) {
            delete wrapper;
            throw;
        }
        if (!wrapper->palette->valid()) {
            delete wrapper;
            report_error(error_out, "invalid palette data");
            return nullptr;
        }
        return wrapper;
    }
    catch (std::exception const& e) {
        report_error(error_out, e.what());
        return nullptr;
    }
}

void mapnik_palette_destroy(mapnik_palette_t* palette) {
    delete palette;
}

bool mapnik_map_render_to_buffer_with_palette(mapnik_map_t* map,
                                              mapnik_palette_t* palette,
                                              unsigned char** data,
                                              unsigned long* size,
                                              bool* is_empty,
                                              char** error_out) {
    if (!require_map(map, error_out)) {
        return false;
    }
    if (palette == nullptr || palette->palette == nullptr) {
        return report_error(error_out, "palette is not initialized");
    }
    try {
        auto image = render_view(*map->map, 1.0);
        if (is_fully_transparent(*image)) {
            if (is_empty != nullptr) {
                *is_empty = true;
            }
            *data = nullptr;
            *size = 0;
            return true;
        }
        if (is_empty != nullptr) {
            *is_empty = false;
        }

        std::string buffer;
        std::ostringstream stream(std::ios::out | std::ios::binary);
        mapnik::save_to_stream(*image, stream, "png", *palette->palette);
        buffer = stream.str();
        return copy_to_output_buffer(buffer, data, size, error_out);
    }
    catch (std::exception const& e) {
        return report_error(error_out, e.what());
    }
}

bool mapnik_map_render_to_file_with_palette(mapnik_map_t* map,
                                            mapnik_palette_t* palette,
                                            const char* output_path,
                                            char** error_out) {
    unsigned char* data = nullptr;
    unsigned long size = 0;
    bool is_empty = false;

    if (!mapnik_map_render_to_buffer_with_palette(map, palette, &data, &size, &is_empty, error_out)) {
        return false;
    }
    if (data == nullptr) {
        return report_error(error_out, "image is empty, nothing written");
    }

    bool const result = [&]() -> bool {
        std::FILE* file = std::fopen(output_path, "wb");
        if (file == nullptr) {
            return report_error(error_out, std::string("could not open '") + output_path + "' for writing");
        }
        std::size_t const written = std::fwrite(data, 1, size, file);
        std::fclose(file);
        if (written != size) {
            return report_error(error_out, std::string("short write to '") + output_path + "'");
        }
        return true;
    }();

    mapnik_free_buffer(data);
    return result;
}