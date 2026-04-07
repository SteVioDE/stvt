const std = @import("std");
const ghostty = @import("ghostty");
const FontAtlas = @import("font.zig").FontAtlas;
const FontStyle = @import("font.zig").Style;
const color = @import("color.zig");
const TerminalState = @import("terminal.zig").TerminalState;

const c = @import("sdl.zig").c;

const CURSOR_BLOCK_ALPHA: u8 = 0x80;
const CURSOR_BAR_WIDTH: f32 = 2.0;
const CURSOR_UNDERLINE_HEIGHT: f32 = 2.0;
const CURSOR_HOLLOW_BORDER: f32 = 1.0;

const VERTS_PER_QUAD: usize = 4;
const INDICES_PER_QUAD: usize = 6;

pub const Renderer = struct {
    sdl_renderer: *c.SDL_Renderer,
    atlas: FontAtlas,

    /// Offscreen texture that persists between frames.
    /// Only dirty rows are redrawn on it; clean rows survive across frames.
    grid_texture: *c.SDL_Texture,
    /// Temporary texture used as buffer when shifting grid_texture on scroll.
    scroll_texture: *c.SDL_Texture,
    grid_w: u32,
    grid_h: u32,

    /// Track previous cursor position to redraw the row it was on
    prev_cursor_x: u16 = 0,
    prev_cursor_y: u16 = 0,
    /// Force full redraw on first frame
    force_full_redraw: bool = true,

    /// Viewport tracking for scroll detection.
    /// We compare the viewport top-left pin between frames to detect scrolling.
    prev_viewport_node: ?*anyopaque = null,
    prev_viewport_y: u32 = 0,

    // Batched geometry buffers — pre-allocated for max grid size
    allocator: std.mem.Allocator,
    bg_verts: []c.SDL_Vertex,
    bg_indices: []c_int,
    fg_verts: []c.SDL_Vertex,
    fg_indices: []c_int,
    deco_verts: []c.SDL_Vertex,
    deco_indices: []c_int,
    max_cells: usize,

    pub fn init(allocator: std.mem.Allocator, sdl_renderer: *c.SDL_Renderer, font_name: [:0]const u8, font_size: f32, cols: u16, rows: u16, content_scale: f32) !Renderer {
        const atlas = try FontAtlas.init(allocator, sdl_renderer, font_name, font_size, content_scale);

        const grid_w = @as(u32, cols) * atlas.metrics.cell_width;
        const grid_h = @as(u32, rows) * atlas.metrics.cell_height;

        const grid_texture = c.SDL_CreateTexture(
            sdl_renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_TARGET,
            @intCast(grid_w),
            @intCast(grid_h),
        ) orelse return error.TextureCreateFailed;

        const scroll_texture = c.SDL_CreateTexture(
            sdl_renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_TARGET,
            @intCast(grid_w),
            @intCast(grid_h),
        ) orelse return error.TextureCreateFailed;

        // Set blend mode for alpha compositing (blur transparency)
        _ = c.SDL_SetTextureBlendMode(grid_texture, c.SDL_BLENDMODE_BLEND);

        // Clear to background color
        _ = c.SDL_SetRenderTarget(sdl_renderer, grid_texture);
        _ = c.SDL_SetRenderDrawColor(sdl_renderer, color.default_bg.r, color.default_bg.g, color.default_bg.b, color.BG_ALPHA);
        _ = c.SDL_RenderClear(sdl_renderer);
        _ = c.SDL_SetRenderTarget(sdl_renderer, null);

        const max_cells: usize = @as(usize, cols) * @as(usize, rows);
        const max_verts = max_cells * VERTS_PER_QUAD;
        const max_indices = max_cells * INDICES_PER_QUAD;
        // bg needs extra capacity: one row-clear quad per dirty row
        const bg_extra: usize = @as(usize, rows);
        const bg_verts = try allocator.alloc(c.SDL_Vertex, (max_cells + bg_extra) * VERTS_PER_QUAD);
        const bg_indices = try allocator.alloc(c_int, (max_cells + bg_extra) * INDICES_PER_QUAD);
        const fg_verts = try allocator.alloc(c.SDL_Vertex, max_verts);
        const fg_indices = try allocator.alloc(c_int, max_indices);
        // Decorations: at most 2 per cell (underline + strikethrough)
        const deco_verts = try allocator.alloc(c.SDL_Vertex, max_verts * 2);
        const deco_indices = try allocator.alloc(c_int, max_indices * 2);

        return .{
            .sdl_renderer = sdl_renderer,
            .atlas = atlas,
            .grid_texture = grid_texture,
            .scroll_texture = scroll_texture,
            .grid_w = grid_w,
            .grid_h = grid_h,
            .allocator = allocator,
            .bg_verts = bg_verts,
            .bg_indices = bg_indices,
            .fg_verts = fg_verts,
            .fg_indices = fg_indices,
            .deco_verts = deco_verts,
            .deco_indices = deco_indices,
            .max_cells = max_cells,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.allocator.free(self.bg_verts);
        self.allocator.free(self.bg_indices);
        self.allocator.free(self.fg_verts);
        self.allocator.free(self.fg_indices);
        self.allocator.free(self.deco_verts);
        self.allocator.free(self.deco_indices);
        c.SDL_DestroyTexture(self.grid_texture);
        c.SDL_DestroyTexture(self.scroll_texture);
        self.atlas.deinit();
    }

    pub fn cellWidth(self: *const Renderer) u32 {
        return self.atlas.metrics.cell_width;
    }

    pub fn cellHeight(self: *const Renderer) u32 {
        return self.atlas.metrics.cell_height;
    }

    /// Recreate the offscreen texture for new grid dimensions.
    pub fn resize(self: *Renderer, cols: u16, rows: u16) void {
        const grid_w = @as(u32, cols) * self.atlas.metrics.cell_width;
        const grid_h = @as(u32, rows) * self.atlas.metrics.cell_height;

        c.SDL_DestroyTexture(self.grid_texture);
        self.grid_texture = c.SDL_CreateTexture(
            self.sdl_renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_TARGET,
            @intCast(grid_w),
            @intCast(grid_h),
        ) orelse return;

        c.SDL_DestroyTexture(self.scroll_texture);
        self.scroll_texture = c.SDL_CreateTexture(
            self.sdl_renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_TARGET,
            @intCast(grid_w),
            @intCast(grid_h),
        ) orelse return;

        self.grid_w = grid_w;
        self.grid_h = grid_h;

        // Reset viewport tracking — resize reflows the page list
        self.prev_viewport_node = null;
        self.prev_viewport_y = 0;

        const new_max: usize = @as(usize, cols) * @as(usize, rows);
        if (new_max > self.max_cells) {
            const max_verts = new_max * VERTS_PER_QUAD;
            const max_indices = new_max * INDICES_PER_QUAD;
            const bg_extra: usize = @as(usize, rows);

            self.allocator.free(self.bg_verts);
            self.allocator.free(self.bg_indices);
            self.allocator.free(self.fg_verts);
            self.allocator.free(self.fg_indices);
            self.allocator.free(self.deco_verts);
            self.allocator.free(self.deco_indices);

            self.bg_verts = self.allocator.alloc(c.SDL_Vertex, (new_max + bg_extra) * VERTS_PER_QUAD) catch return;
            self.bg_indices = self.allocator.alloc(c_int, (new_max + bg_extra) * INDICES_PER_QUAD) catch return;
            self.fg_verts = self.allocator.alloc(c.SDL_Vertex, max_verts) catch return;
            self.fg_indices = self.allocator.alloc(c_int, max_indices) catch return;
            self.deco_verts = self.allocator.alloc(c.SDL_Vertex, max_verts * 2) catch return;
            self.deco_indices = self.allocator.alloc(c_int, max_indices * 2) catch return;
            self.max_cells = new_max;
        }

        self.force_full_redraw = true;

        _ = c.SDL_SetTextureBlendMode(self.grid_texture, c.SDL_BLENDMODE_BLEND);

        // Clear to background
        _ = c.SDL_SetRenderTarget(self.sdl_renderer, self.grid_texture);
        _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, color.default_bg.r, color.default_bg.g, color.default_bg.b, color.BG_ALPHA);
        _ = c.SDL_RenderClear(self.sdl_renderer);
        _ = c.SDL_SetRenderTarget(self.sdl_renderer, null);
    }

    /// Render dirty rows to the offscreen texture, then present.
    /// Returns true if anything was actually drawn.
    pub fn renderFrame(self: *Renderer, term: *TerminalState) bool {
        const cw = self.atlas.metrics.cell_width;
        const ch = self.atlas.metrics.cell_height;

        // Check ghostty-vt's renderer dirty flag (set on screen switch, erase, resize)
        if (term.terminal.flags.dirty.clear) {
            self.force_full_redraw = true;
            self.prev_viewport_node = null;
            term.terminal.flags.dirty.clear = false;
        }

        // --- Scroll detection ---
        // Compare viewport top-left between frames to detect scrolling.
        const pages = &term.terminal.screens.active.pages;
        const viewport_tl = pages.getTopLeft(.viewport);
        const cur_vp_node: *anyopaque = @ptrCast(viewport_tl.node);
        const cur_vp_y: u32 = viewport_tl.y;
        var scroll_rows: u32 = 0;

        if (self.prev_viewport_node) |prev_node| {
            if (cur_vp_node == prev_node and cur_vp_y > self.prev_viewport_y) {
                scroll_rows = cur_vp_y - self.prev_viewport_y;
                if (scroll_rows >= @as(u32, pages.rows)) {
                    // Scrolled more than a full screen — just redraw everything
                    self.force_full_redraw = true;
                    scroll_rows = 0;
                }
            } else if (cur_vp_node != prev_node) {
                // Page boundary crossed — can't compute distance cheaply
                self.force_full_redraw = true;
            }
        }
        self.prev_viewport_node = cur_vp_node;
        self.prev_viewport_y = cur_vp_y;

        const full_redraw = self.force_full_redraw;
        self.force_full_redraw = false;

        const cursor = term.getCursor();
        const cursor_moved = cursor.x != self.prev_cursor_x or cursor.y != self.prev_cursor_y;

        var row_it = pages.rowIterator(.right_down, .{ .viewport = .{} }, null);

        var any_dirty = full_redraw or cursor_moved or (scroll_rows > 0);

        // Render to offscreen texture
        _ = c.SDL_SetRenderTarget(self.sdl_renderer, self.grid_texture);

        // Shift texture up when scrolling detected (avoids full redraw)
        if (scroll_rows > 0 and !full_redraw) {
            const scroll_px = scroll_rows * ch;
            const remaining_h = self.grid_h - scroll_px;
            // Copy grid → scroll_texture (raw pixel copy, no alpha blending)
            _ = c.SDL_SetTextureBlendMode(self.grid_texture, c.SDL_BLENDMODE_NONE);
            _ = c.SDL_SetRenderTarget(self.sdl_renderer, self.scroll_texture);
            _ = c.SDL_RenderTexture(self.sdl_renderer, self.grid_texture, null, null);
            // Blit scroll_texture back onto grid_texture, shifted up
            _ = c.SDL_SetTextureBlendMode(self.scroll_texture, c.SDL_BLENDMODE_NONE);
            _ = c.SDL_SetRenderTarget(self.sdl_renderer, self.grid_texture);
            _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, color.default_bg.r, color.default_bg.g, color.default_bg.b, color.BG_ALPHA);
            _ = c.SDL_RenderClear(self.sdl_renderer);
            const src_rect = c.SDL_FRect{ .x = 0, .y = @floatFromInt(scroll_px), .w = @floatFromInt(self.grid_w), .h = @floatFromInt(remaining_h) };
            const dst_rect = c.SDL_FRect{ .x = 0, .y = 0, .w = @floatFromInt(self.grid_w), .h = @floatFromInt(remaining_h) };
            _ = c.SDL_RenderTexture(self.sdl_renderer, self.scroll_texture, &src_rect, &dst_rect);
            // Restore blend mode for normal rendering
            _ = c.SDL_SetTextureBlendMode(self.grid_texture, c.SDL_BLENDMODE_BLEND);
        }

        // Batch counters
        var bg_vc: usize = 0;
        var bg_ic: usize = 0;
        var fg_vc: usize = 0;
        var fg_ic: usize = 0;
        var deco_vc: usize = 0;
        var deco_ic: usize = 0;

        // Rows at or below this index were exposed by the scroll shift and must be redrawn
        const scroll_redraw_from: u32 = if (scroll_rows > 0 and !full_redraw)
            @as(u32, pages.rows) - scroll_rows
        else
            std.math.maxInt(u32);

        var row_idx: u32 = 0;
        while (row_it.next()) |row_pin| {
            const row_dirty = full_redraw or row_pin.isDirty() or
                row_idx == @as(u32, self.prev_cursor_y) or
                row_idx == @as(u32, cursor.y) or
                row_idx >= scroll_redraw_from;

            if (row_dirty) {
                any_dirty = true;
                const y: f32 = @floatFromInt(row_idx * ch);
                const cw_f: f32 = @floatFromInt(cw);
                const ch_f: f32 = @floatFromInt(ch);

                // Clear row background as a single quad
                const bg_clr = colorToFloat(color.default_bg.r, color.default_bg.g, color.default_bg.b, color.BG_ALPHA);
                const row_q = appendQuad(self.bg_verts, self.bg_indices, bg_vc, bg_ic, 0, y, @floatFromInt(self.grid_w), ch_f, bg_clr, 0, 0, 0, 0);
                bg_vc = row_q.verts;
                bg_ic = row_q.indices;

                // Render cells
                const cells = row_pin.cells(.all);
                for (cells, 0..) |*cell_ptr, col_idx| {
                    const x: f32 = @floatFromInt(@as(u32, @intCast(col_idx)) * cw);

                    // --- Background ---
                    const bg = resolveBackgroundColor(row_pin, cell_ptr);
                    if (bg.r != color.default_bg.r or bg.g != color.default_bg.g or bg.b != color.default_bg.b) {
                        const cell_bg = colorToFloat(bg.r, bg.g, bg.b, 0xFF);
                        const q = appendQuad(self.bg_verts, self.bg_indices, bg_vc, bg_ic, x, y, cw_f, ch_f, cell_bg, 0, 0, 0, 0);
                        bg_vc = q.verts;
                        bg_ic = q.indices;
                    }

                    // --- Foreground glyph ---
                    if (!cell_ptr.hasText()) continue;
                    const cp = cell_ptr.codepoint();
                    if (cp == 0) continue;
                    if (cell_ptr.wide == .spacer_tail) continue;

                    const sty = row_pin.style(cell_ptr);
                    const fg = if (sty.flags.inverse)
                        resolveBackgroundColor(row_pin, cell_ptr)
                    else
                        color.resolveColor(sty.fg_color, color.default_fg);
                    const font_style = fontStyleFromStyle(sty);

                    const glyph = self.atlas.getGlyph(cp, font_style) orelse continue;
                    if (glyph.width == 0 or glyph.height == 0) {
                        // Still need to process decorations for whitespace glyphs
                    } else {
                        // Glyph position with bearing offset
                        const gx = x + @as(f32, @floatFromInt(glyph.bearing_x));
                        const gy = y + @as(f32, @floatFromInt(@as(i32, @intCast(self.atlas.metrics.ascent)) - glyph.bearing_y));
                        const gw: f32 = @floatFromInt(glyph.width);
                        const gh: f32 = @floatFromInt(glyph.height);

                        // Normalized UV coordinates into the atlas
                        // Read atlas_size per-glyph: growAtlas() may have doubled it mid-frame
                        const atlas_f: f32 = @floatFromInt(self.atlas.atlas_size);
                        const tex_u0: f32 = @as(f32, @floatFromInt(glyph.atlas_x)) / atlas_f;
                        const tex_v0: f32 = @as(f32, @floatFromInt(glyph.atlas_y)) / atlas_f;
                        const tex_u1: f32 = @as(f32, @floatFromInt(glyph.atlas_x + glyph.width)) / atlas_f;
                        const tex_v1: f32 = @as(f32, @floatFromInt(glyph.atlas_y + glyph.height)) / atlas_f;

                        const fg_clr = colorToFloat(fg.r, fg.g, fg.b, 0xFF);
                        const q = appendQuad(self.fg_verts, self.fg_indices, fg_vc, fg_ic, gx, gy, gw, gh, fg_clr, tex_u0, tex_v0, tex_u1, tex_v1);
                        fg_vc = q.verts;
                        fg_ic = q.indices;
                    }

                    // --- Decorations ---
                    if (sty.flags.underline != .none) {
                        const ul_y = y + @as(f32, @floatFromInt(self.atlas.metrics.ascent + 1));
                        const ul_clr = colorToFloat(fg.r, fg.g, fg.b, 0xFF);
                        const q = appendQuad(self.deco_verts, self.deco_indices, deco_vc, deco_ic, x, ul_y, cw_f, 1.0, ul_clr, 0, 0, 0, 0);
                        deco_vc = q.verts;
                        deco_ic = q.indices;
                    }
                    if (sty.flags.strikethrough) {
                        const st_y = y + @as(f32, @floatFromInt(self.atlas.metrics.ascent / 2));
                        const st_clr = colorToFloat(fg.r, fg.g, fg.b, 0xFF);
                        const q = appendQuad(self.deco_verts, self.deco_indices, deco_vc, deco_ic, x, st_y, cw_f, 1.0, st_clr, 0, 0, 0, 0);
                        deco_vc = q.verts;
                        deco_ic = q.indices;
                    }
                }
            }

            // Clear row dirty flag
            const rc = row_pin.rowAndCell();
            rc.row.dirty = false;

            row_idx += 1;
        }

        // Clear page-level dirty flags for viewport pages only.
        // (pages.clearDirty() traverses ALL pages including scrollback — too expensive)
        {
            var vp_it = pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
            var last_page: ?*anyopaque = null;
            while (vp_it.next()) |pin| {
                const page_ptr: *anyopaque = @ptrCast(pin.node);
                if (page_ptr != last_page) {
                    pin.node.data.dirty = false;
                    last_page = page_ptr;
                }
            }
        }

        // --- Flush batched geometry ---
        // Pass 1: backgrounds (untextured, replace mode — overwrites old content)
        if (bg_ic > 0) {
            _ = c.SDL_SetRenderDrawBlendMode(self.sdl_renderer, c.SDL_BLENDMODE_NONE);
            _ = c.SDL_RenderGeometry(self.sdl_renderer, null, self.bg_verts.ptr, @intCast(bg_vc), self.bg_indices.ptr, @intCast(bg_ic));
        }
        // Pass 2: foreground glyphs (textured from atlas, blend mode)
        if (fg_ic > 0) {
            _ = c.SDL_SetRenderDrawBlendMode(self.sdl_renderer, c.SDL_BLENDMODE_BLEND);
            _ = c.SDL_RenderGeometry(self.sdl_renderer, self.atlas.texture, self.fg_verts.ptr, @intCast(fg_vc), self.fg_indices.ptr, @intCast(fg_ic));
        }
        // Pass 3: decorations (untextured, blend mode)
        if (deco_ic > 0) {
            _ = c.SDL_RenderGeometry(self.sdl_renderer, null, self.deco_verts.ptr, @intCast(deco_vc), self.deco_indices.ptr, @intCast(deco_ic));
        }

        // Draw cursor (few calls, not worth batching)
        const cursor_x: f32 = @floatFromInt(@as(u32, cursor.x) * cw);
        const cursor_y_f: f32 = @floatFromInt(@as(u32, cursor.y) * ch);
        const cw_f: f32 = @floatFromInt(cw);
        const ch_f: f32 = @floatFromInt(ch);

        switch (term.terminal.screens.active.cursor.cursor_style) {
            .block => {
                _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, color.default_fg.r, color.default_fg.g, color.default_fg.b, CURSOR_BLOCK_ALPHA);
                _ = c.SDL_RenderFillRect(self.sdl_renderer, &c.SDL_FRect{
                    .x = cursor_x, .y = cursor_y_f, .w = cw_f, .h = ch_f,
                });
            },
            .block_hollow => {
                _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, color.default_fg.r, color.default_fg.g, color.default_fg.b, 0xFF);
                _ = c.SDL_RenderFillRect(self.sdl_renderer, &c.SDL_FRect{ .x = cursor_x, .y = cursor_y_f, .w = cw_f, .h = CURSOR_HOLLOW_BORDER });
                _ = c.SDL_RenderFillRect(self.sdl_renderer, &c.SDL_FRect{ .x = cursor_x, .y = cursor_y_f + ch_f - CURSOR_HOLLOW_BORDER, .w = cw_f, .h = CURSOR_HOLLOW_BORDER });
                _ = c.SDL_RenderFillRect(self.sdl_renderer, &c.SDL_FRect{ .x = cursor_x, .y = cursor_y_f, .w = CURSOR_HOLLOW_BORDER, .h = ch_f });
                _ = c.SDL_RenderFillRect(self.sdl_renderer, &c.SDL_FRect{ .x = cursor_x + cw_f - CURSOR_HOLLOW_BORDER, .y = cursor_y_f, .w = CURSOR_HOLLOW_BORDER, .h = ch_f });
            },
            .bar => {
                _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, color.default_fg.r, color.default_fg.g, color.default_fg.b, 0xFF);
                _ = c.SDL_RenderFillRect(self.sdl_renderer, &c.SDL_FRect{
                    .x = cursor_x, .y = cursor_y_f, .w = CURSOR_BAR_WIDTH, .h = ch_f,
                });
            },
            .underline => {
                _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, color.default_fg.r, color.default_fg.g, color.default_fg.b, 0xFF);
                _ = c.SDL_RenderFillRect(self.sdl_renderer, &c.SDL_FRect{
                    .x = cursor_x, .y = cursor_y_f + ch_f - CURSOR_UNDERLINE_HEIGHT, .w = cw_f, .h = CURSOR_UNDERLINE_HEIGHT,
                });
            },
        }

        self.prev_cursor_x = cursor.x;
        self.prev_cursor_y = cursor.y;

        // Switch back to screen and blit the grid texture
        _ = c.SDL_SetRenderTarget(self.sdl_renderer, null);

        if (any_dirty) {
            _ = c.SDL_SetRenderDrawColor(self.sdl_renderer, 0, 0, 0, 0);
            _ = c.SDL_RenderClear(self.sdl_renderer);

            _ = c.SDL_RenderTexture(self.sdl_renderer, self.grid_texture, null, null);
            _ = c.SDL_RenderPresent(self.sdl_renderer);
        }

        return any_dirty;
    }
};

// --- Module-level helpers ---

fn resolveBackgroundColor(row_pin: anytype, cell: *const ghostty.Cell) color.RGB {
    if (cell.content_tag == .bg_color_palette) {
        return color.palette_256[cell.content.color_palette];
    }
    if (cell.content_tag == .bg_color_rgb) {
        const rgb = cell.content.color_rgb;
        return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
    }
    const sty = row_pin.style(cell);
    return color.resolveColor(sty.bg_color, color.default_bg);
}

fn fontStyleFromStyle(sty: ghostty.Style) FontStyle {
    if (sty.flags.bold and sty.flags.italic) return .bold_italic;
    if (sty.flags.bold) return .bold;
    if (sty.flags.italic) return .italic;
    return .regular;
}

/// Append a quad (2 triangles) to vertex/index buffers. Returns new count.
fn appendQuad(
    verts: []c.SDL_Vertex,
    indices: []c_int,
    vert_count: usize,
    idx_count: usize,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    clr: c.SDL_FColor,
    s0: f32,
    t0: f32,
    s1: f32,
    t1: f32,
) struct { verts: usize, indices: usize } {
    const vi: c_int = @intCast(vert_count);
    // Top-left, top-right, bottom-right, bottom-left
    verts[vert_count + 0] = .{ .position = .{ .x = x, .y = y }, .color = clr, .tex_coord = .{ .x = s0, .y = t0 } };
    verts[vert_count + 1] = .{ .position = .{ .x = x + w, .y = y }, .color = clr, .tex_coord = .{ .x = s1, .y = t0 } };
    verts[vert_count + 2] = .{ .position = .{ .x = x + w, .y = y + h }, .color = clr, .tex_coord = .{ .x = s1, .y = t1 } };
    verts[vert_count + 3] = .{ .position = .{ .x = x, .y = y + h }, .color = clr, .tex_coord = .{ .x = s0, .y = t1 } };
    // Two triangles: 0-1-2 and 0-2-3
    indices[idx_count + 0] = vi;
    indices[idx_count + 1] = vi + 1;
    indices[idx_count + 2] = vi + 2;
    indices[idx_count + 3] = vi;
    indices[idx_count + 4] = vi + 2;
    indices[idx_count + 5] = vi + 3;
    return .{ .verts = vert_count + VERTS_PER_QUAD, .indices = idx_count + INDICES_PER_QUAD };
}

fn colorToFloat(r: u8, g: u8, b: u8, a: u8) c.SDL_FColor {
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = @as(f32, @floatFromInt(a)) / 255.0,
    };
}
