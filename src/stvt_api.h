#ifndef STVT_API_H
#define STVT_API_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <ghostty/vt.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque context handle
typedef void* StvtContext;

// Lifecycle
StvtContext stvt_init(uint16_t cols, uint16_t rows, float content_scale);
void stvt_destroy(StvtContext ctx);

// PTY I/O
// Returns: dirty level (0=clean, 1=partial, 2=full, -1=shell exited)
int32_t stvt_poll(StvtContext ctx);
bool stvt_is_alive(StvtContext ctx);

// Input
// Returns: 0=written, 1=paste, 2=scroll_up, 3=scroll_down, 4=quit, -1=none
int32_t stvt_feed_key(StvtContext ctx, uint16_t keycode, uint32_t ns_mods,
                      const char* utf8, size_t utf8_len);
void stvt_feed_text(StvtContext ctx, const char* text, size_t len);
void stvt_paste(StvtContext ctx, const char* text, size_t len);

// Resize
void stvt_resize(StvtContext ctx, uint16_t cols, uint16_t rows);

// Render state
int32_t stvt_update_render_state(StvtContext ctx);
GhosttyRenderState stvt_get_render_state(StvtContext ctx);
GhosttyTerminal stvt_get_terminal(StvtContext ctx);
void stvt_clear_dirty(StvtContext ctx);
bool stvt_get_dirty_rows(StvtContext ctx, uint16_t *out_min, uint16_t *out_max);

// Font atlas
const uint8_t* stvt_get_atlas_pixels(StvtContext ctx);
uint32_t stvt_get_atlas_size(StvtContext ctx);
bool stvt_is_atlas_dirty(StvtContext ctx);
void stvt_clear_atlas_dirty(StvtContext ctx);
uint32_t stvt_get_cell_width(StvtContext ctx);
uint32_t stvt_get_cell_height(StvtContext ctx);
uint32_t stvt_get_ascent(StvtContext ctx);

typedef struct {
    uint32_t atlas_x;
    uint32_t atlas_y;
    uint32_t width;
    uint32_t height;
    int32_t bearing_x;
    int32_t bearing_y;
    uint32_t advance;
    bool found;
} StvtGlyphInfo;

StvtGlyphInfo stvt_get_glyph(StvtContext ctx, uint32_t codepoint, uint8_t style);

// Colors
uint8_t stvt_get_default_bg_r(StvtContext ctx);
uint8_t stvt_get_default_bg_g(StvtContext ctx);
uint8_t stvt_get_default_bg_b(StvtContext ctx);
uint8_t stvt_get_bg_alpha(StvtContext ctx);
uint8_t stvt_get_default_fg_r(StvtContext ctx);
uint8_t stvt_get_default_fg_g(StvtContext ctx);
uint8_t stvt_get_default_fg_b(StvtContext ctx);

// Grid info
uint16_t stvt_get_cols(StvtContext ctx);
uint16_t stvt_get_rows(StvtContext ctx);

// Title
const uint8_t* stvt_get_title(StvtContext ctx, size_t *out_len);
bool stvt_title_changed(StvtContext ctx);

// PTY fd (for dispatch_source)
int32_t stvt_get_pty_fd(StvtContext ctx);

// Mouse
// action: 0=press, 1=release, 2=motion
// button: 0=unknown, 1=left, 2=right, 3=middle, 4-5=scroll
bool stvt_feed_mouse(StvtContext ctx, uint32_t action, uint32_t button,
                     uint32_t ns_mods, float x, float y);
bool stvt_is_mouse_tracking(StvtContext ctx);

// Selection (pixel coordinates in backing store space)
void stvt_select_start(StvtContext ctx, float px_x, float px_y);
void stvt_select_update(StvtContext ctx, float px_x, float px_y);
void stvt_select_clear(StvtContext ctx);
bool stvt_is_cell_selected(StvtContext ctx, uint16_t col, uint16_t row);
bool stvt_has_selection(StvtContext ctx);
// Copy selected text to buffer. Returns bytes written.
size_t stvt_copy_selection(StvtContext ctx, uint8_t *out_buf, size_t buf_len);

#ifdef __cplusplus
}
#endif

#endif // STVT_API_H
