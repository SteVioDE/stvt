const std = @import("std");
const c = @import("sdl.zig").c;
const shim = @cImport({
    @cInclude("font_shim.h");
});

const log = std.log.scoped(.font);

pub const Style = enum(u2) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
};

const GlyphKey = struct {
    codepoint: u32,
    style: Style,
};

pub const GlyphInfo = struct {
    atlas_x: u32,
    atlas_y: u32,
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
    advance: u32,
};

pub const CellMetrics = struct {
    cell_width: u32,
    cell_height: u32,
    ascent: u32,
    descent: u32,
};

const INITIAL_ATLAS_SIZE: u32 = 1024;
const MAX_ATLAS_SIZE: u32 = 4096;
const ATLAS_ROW_GAP: u32 = 1;
const ATLAS_COL_GAP: u32 = 1;
const MAX_GLYPH_STACK_BYTES: usize = 262_144; // 256 * 256 * 4

pub const FontAtlas = struct {
    // Atlas texture state
    texture: *c.SDL_Texture,
    atlas_size: u32,
    cursor_x: u32,
    cursor_y: u32,
    row_height: u32,

    // Glyph cache
    glyphs: std.AutoHashMap(GlyphKey, GlyphInfo),

    // Font handles: regular, bold, italic, bold_italic
    font_handles: [4]?*anyopaque,

    // Cell metrics from the regular font
    metrics: CellMetrics,

    // SDL renderer reference (for texture operations)
    sdl_renderer: *c.SDL_Renderer,

    // Allocator for dynamic buffer when glyphs exceed stack buffer
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, sdl_renderer: *c.SDL_Renderer, font_name: [:0]const u8, size: f32, content_scale: f32) !FontAtlas {
        // Scale font size for HiDPI: rasterize at physical pixel size
        const scaled_size = size * content_scale;

        // Load four font variants at scaled size
        const handles = [4]?*anyopaque{
            shim.font_init(font_name.ptr, scaled_size),
            shim.font_init_bold(font_name.ptr, scaled_size),
            shim.font_init_italic(font_name.ptr, scaled_size),
            shim.font_init_bold_italic(font_name.ptr, scaled_size),
        };

        if (handles[0] == null) return error.FontLoadFailed;

        // Get cell metrics from regular font
        const m = shim.font_get_metrics(handles[0]);

        // Create atlas texture: RGBA with blend mode
        const texture = c.SDL_CreateTexture(
            sdl_renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_STREAMING,
            @intCast(INITIAL_ATLAS_SIZE),
            @intCast(INITIAL_ATLAS_SIZE),
        ) orelse return error.TextureCreateFailed;

        _ = c.SDL_SetTextureBlendMode(texture, c.SDL_BLENDMODE_BLEND);

        // Clear texture to transparent
        var pixels: ?*anyopaque = null;
        var pitch: c_int = 0;
        if (c.SDL_LockTexture(texture, null, &pixels, &pitch)) {
            const pixel_data: [*]u8 = @ptrCast(pixels.?);
            const total_bytes: usize = @intCast(pitch * @as(c_int, @intCast(INITIAL_ATLAS_SIZE)));
            @memset(pixel_data[0..total_bytes], 0);
            c.SDL_UnlockTexture(texture);
        }

        return .{
            .texture = texture,
            .atlas_size = INITIAL_ATLAS_SIZE,
            .cursor_x = 0,
            .cursor_y = 0,
            .row_height = 0,
            .glyphs = std.AutoHashMap(GlyphKey, GlyphInfo).init(allocator),
            .font_handles = handles,
            .metrics = .{
                .cell_width = @intCast(m.cell_width),
                .cell_height = @intCast(m.cell_height),
                .ascent = @intCast(m.ascent),
                .descent = @intCast(m.descent),
            },
            .sdl_renderer = sdl_renderer,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FontAtlas) void {
        for (&self.font_handles) |h| {
            if (h) |handle| shim.font_deinit(handle);
        }
        c.SDL_DestroyTexture(self.texture);
        self.glyphs.deinit();
    }

    const PackResult = struct { x: u32, y: u32 };

    /// Row packing: place a glyph of (w, h) in the atlas.
    fn pack(self: *FontAtlas, w: u32, h: u32) ?PackResult {
        if (self.cursor_x + w > self.atlas_size) {
            self.cursor_x = 0;
            self.cursor_y += self.row_height + ATLAS_ROW_GAP;
            self.row_height = 0;
        }
        if (self.cursor_y + h > self.atlas_size) {
            if (!self.growAtlas()) return null;
            // After growing, the current position is still valid — retry
            if (self.cursor_y + h > self.atlas_size) return null;
        }
        const result = PackResult{ .x = self.cursor_x, .y = self.cursor_y };
        self.cursor_x += w + ATLAS_COL_GAP;
        self.row_height = @max(self.row_height, h);
        return result;
    }

    /// Double the atlas texture size, copying existing content to the new texture.
    /// Returns true on success, false if at MAX_ATLAS_SIZE or texture creation fails.
    fn growAtlas(self: *FontAtlas) bool {
        const new_size = self.atlas_size * 2;
        if (new_size > MAX_ATLAS_SIZE) {
            log.err("atlas at maximum size ({d}x{d}), cannot grow", .{ self.atlas_size, self.atlas_size });
            return false;
        }

        // Create new larger texture
        const new_texture = c.SDL_CreateTexture(
            self.sdl_renderer,
            c.SDL_PIXELFORMAT_ARGB8888,
            c.SDL_TEXTUREACCESS_STREAMING,
            @intCast(new_size),
            @intCast(new_size),
        ) orelse {
            log.err("failed to create {d}x{d} atlas texture", .{ new_size, new_size });
            return false;
        };

        _ = c.SDL_SetTextureBlendMode(new_texture, c.SDL_BLENDMODE_BLEND);

        // Clear new texture to transparent, then copy old content — single lock
        var new_pixels: ?*anyopaque = null;
        var new_pitch: c_int = 0;
        if (c.SDL_LockTexture(new_texture, null, &new_pixels, &new_pitch)) {
            const dst: [*]u8 = @ptrCast(new_pixels.?);
            const total_bytes: usize = @intCast(new_pitch * @as(c_int, @intCast(new_size)));
            @memset(dst[0..total_bytes], 0);

            // Copy old texture content row by row
            var old_pixels: ?*anyopaque = null;
            var old_pitch: c_int = 0;
            const old_rect = c.SDL_Rect{ .x = 0, .y = 0, .w = @intCast(self.atlas_size), .h = @intCast(self.atlas_size) };

            if (c.SDL_LockTexture(self.texture, &old_rect, &old_pixels, &old_pitch)) {
                const src: [*]const u8 = @ptrCast(old_pixels.?);
                const row_bytes: usize = @intCast(self.atlas_size * 4);

                for (0..self.atlas_size) |row| {
                    const src_offset = row * @as(usize, @intCast(old_pitch));
                    const dst_offset = row * @as(usize, @intCast(new_pitch));
                    @memcpy(dst[dst_offset..][0..row_bytes], src[src_offset..][0..row_bytes]);
                }

                c.SDL_UnlockTexture(self.texture);
            } else {
                log.warn("failed to lock old atlas during resize, content lost", .{});
            }

            c.SDL_UnlockTexture(new_texture);
        } else {
            log.warn("failed to lock new atlas during resize", .{});
        }

        c.SDL_DestroyTexture(self.texture);
        self.texture = new_texture;
        self.atlas_size = new_size;

        log.info("atlas grown to {d}x{d}", .{ new_size, new_size });
        return true;
    }

    /// Get glyph info, rasterizing on cache miss.
    pub fn getGlyph(self: *FontAtlas, codepoint: u32, style: Style) ?GlyphInfo {
        const key = GlyphKey{ .codepoint = codepoint, .style = style };

        if (self.glyphs.get(key)) |info| {
            return info;
        }

        // Cache miss — rasterize via C shim
        const handle = self.font_handles[@intFromEnum(style)] orelse
            self.font_handles[0] orelse return null;

        const bmp = shim.font_rasterize(handle, codepoint);
        defer if (bmp.bitmap) |b| std.c.free(b);

        if (bmp.width <= 0 or bmp.height <= 0) {
            // Whitespace or zero-size glyph — cache with zero dimensions
            const info = GlyphInfo{
                .atlas_x = 0,
                .atlas_y = 0,
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = if (bmp.advance > 0) @intCast(bmp.advance) else self.metrics.cell_width,
            };
            self.glyphs.put(key, info) catch |err| log.warn("glyph cache insert failed: {}", .{err});
            return info;
        }

        const w: u32 = @intCast(bmp.width);
        const h: u32 = @intCast(bmp.height);

        // Pack into atlas
        const pos = self.pack(w, h) orelse return null;

        // Convert alpha-only bitmap to ARGB8888: white (0xFFFFFF) with alpha from bitmap
        const pixel_count = w * h;
        const argb_size = pixel_count * 4;

        // Use stack buffer for typical glyphs, heap for large ones
        var stack_buf: [MAX_GLYPH_STACK_BYTES]u8 = undefined;
        const argb_buf = if (argb_size <= stack_buf.len)
            stack_buf[0..argb_size]
        else
            self.allocator.alloc(u8, argb_size) catch return null;
        defer if (argb_size > stack_buf.len) self.allocator.free(argb_buf);

        const src: [*]const u8 = bmp.bitmap orelse return null;
        for (0..pixel_count) |i| {
            const alpha = src[i];
            // ARGB8888: [B, G, R, A] in little-endian memory
            argb_buf[i * 4 + 0] = 255; // B
            argb_buf[i * 4 + 1] = 255; // G
            argb_buf[i * 4 + 2] = 255; // R
            argb_buf[i * 4 + 3] = alpha; // A
        }

        const dst_rect = c.SDL_Rect{
            .x = @intCast(pos.x),
            .y = @intCast(pos.y),
            .w = @intCast(w),
            .h = @intCast(h),
        };
        _ = c.SDL_UpdateTexture(self.texture, &dst_rect, argb_buf.ptr, @intCast(w * 4));

        const info = GlyphInfo{
            .atlas_x = pos.x,
            .atlas_y = pos.y,
            .width = w,
            .height = h,
            .bearing_x = bmp.bearing_x,
            .bearing_y = bmp.bearing_y,
            .advance = @intCast(bmp.advance),
        };
        self.glyphs.put(key, info) catch |err| log.warn("glyph cache insert failed: {}", .{err});
        return info;
    }

};
