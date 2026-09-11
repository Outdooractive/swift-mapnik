# TODO — swift-mapnik roadmap

Ideas for functionality to add.
Shim-only additions = the C wrapper already exists and only the Swift
façade is missing.

## Larger efforts, deferred until requested

- [ ] **UTFGrid rendering** — mapnik's grid renderer for interactive
      (hover/tooltip) tiles; common tile-server output format.
- [ ] **Programmatic map building** — construct styles/layers/datasources
      in code (or via swift-carto output) without a stylesheet string;
      needs a large shim surface (`symbolizer`, `style`, `layer` setters).
- [ ] **Image utilities** — raw RGBA buffer access, `image_view` crops,
      compositing/filter operators, and loading PNG/JPEG/TIFF images for
      re-encoding (raster re-projection pipelines).
