#ifndef FONT_SHIM_H
#define FONT_SHIM_H

#include <stdint.h>
#include <stdbool.h>

typedef struct {
    uint8_t *bitmap;   // grayscale pixel data — caller must free() this
    int width;         // bitmap width in pixels
    int height;        // bitmap height in pixels
    int bearing_x;     // left bearing from cell origin (pixels)
    int bearing_y;     // distance from baseline to top of glyph (pixels)
    int advance;       // horizontal advance (pixels)
} GlyphBitmap;

typedef struct {
    int cell_width;    // monospace cell width in pixels
    int cell_height;   // total cell height: ascent + descent + leading
    int ascent;        // baseline to top of cell (pixels)
    int descent;       // baseline to bottom of cell (positive = below baseline)
} FontMetrics;

void *font_init(const char *font_name, float size);
void *font_init_bold(const char *font_name, float size);
void *font_init_italic(const char *font_name, float size);
void *font_init_bold_italic(const char *font_name, float size);
void font_deinit(void *handle);

FontMetrics font_get_metrics(void *handle);
GlyphBitmap font_rasterize(void *handle, uint32_t codepoint);

#endif // FONT_SHIM_H
