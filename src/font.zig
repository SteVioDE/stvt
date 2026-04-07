const std = @import("std");
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
    // Atlas pixel buffer (BGRA8888, Metal-native format)
    pixels: []u8,
    atlas_size: u32,
    cursor_x: u32,
    cursor_y: u32,
    row_height: u32,

    // Track whether atlas has changed since last texture upload
    dirty: bool,
    // Region that needs re-uploading (min bounding rect of changes)
    dirty_min_x: u32,
    dirty_min_y: u32,
    dirty_max_x: u32,
    dirty_max_y: u32,

    // Glyph cache
    glyphs: std.AutoHashMap(GlyphKey, GlyphInfo),

    // Font handles: regular, bold, italic, bold_italic
    font_handles: [4]?*anyopaque,

    // Cell metrics from the regular font
    metrics: CellMetrics,

    // Allocator
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, font_name: [:0]const u8, size: f32, content_scale: f32) !FontAtlas {
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

        // Allocate atlas pixel buffer (BGRA8888)
        const pixel_count = @as(usize, INITIAL_ATLAS_SIZE) * @as(usize, INITIAL_ATLAS_SIZE) * 4;
        const pixels = try allocator.alloc(u8, pixel_count);
        @memset(pixels, 0);

        return .{
            .pixels = pixels,
            .atlas_size = INITIAL_ATLAS_SIZE,
            .cursor_x = 0,
            .cursor_y = 0,
            .row_height = 0,
            .dirty = false,
            .dirty_min_x = 0,
            .dirty_min_y = 0,
            .dirty_max_x = 0,
            .dirty_max_y = 0,
            .glyphs = std.AutoHashMap(GlyphKey, GlyphInfo).init(allocator),
            .font_handles = handles,
            .metrics = .{
                .cell_width = @intCast(m.cell_width),
                .cell_height = @intCast(m.cell_height),
                .ascent = @intCast(m.ascent),
                .descent = @intCast(m.descent),
            },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FontAtlas) void {
        for (&self.font_handles) |h| {
            if (h) |handle| shim.font_deinit(handle);
        }
        self.allocator.free(self.pixels);
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
            if (self.cursor_y + h > self.atlas_size) return null;
        }
        const result = PackResult{ .x = self.cursor_x, .y = self.cursor_y };
        self.cursor_x += w + ATLAS_COL_GAP;
        self.row_height = @max(self.row_height, h);
        return result;
    }

    /// Double the atlas size, copying existing content.
    fn growAtlas(self: *FontAtlas) bool {
        const new_size = self.atlas_size * 2;
        if (new_size > MAX_ATLAS_SIZE) {
            log.err("atlas at maximum size ({d}x{d}), cannot grow", .{ self.atlas_size, self.atlas_size });
            return false;
        }

        const new_pixel_count = @as(usize, new_size) * @as(usize, new_size) * 4;
        const new_pixels = self.allocator.alloc(u8, new_pixel_count) catch {
            log.err("failed to allocate {d}x{d} atlas", .{ new_size, new_size });
            return false;
        };
        @memset(new_pixels, 0);

        // Copy old content row by row
        const old_stride = @as(usize, self.atlas_size) * 4;
        const new_stride = @as(usize, new_size) * 4;
        for (0..self.atlas_size) |row| {
            const src_offset = row * old_stride;
            const dst_offset = row * new_stride;
            @memcpy(new_pixels[dst_offset..][0..old_stride], self.pixels[src_offset..][0..old_stride]);
        }

        self.allocator.free(self.pixels);
        self.pixels = new_pixels;
        self.atlas_size = new_size;

        // Mark entire atlas dirty for re-upload
        self.dirty = true;
        self.dirty_min_x = 0;
        self.dirty_min_y = 0;
        self.dirty_max_x = new_size;
        self.dirty_max_y = new_size;

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

        // Convert alpha-only bitmap to BGRA8888 (Metal native: B, G, R, A in little-endian)
        const src: [*]const u8 = bmp.bitmap orelse return null;
        const stride = @as(usize, self.atlas_size) * 4;
        for (0..h) |row| {
            for (0..w) |col| {
                const alpha = src[row * w + col];
                const px_offset = (pos.y + @as(u32, @intCast(row))) * stride + (pos.x + @as(u32, @intCast(col))) * 4;
                self.pixels[px_offset + 0] = 255; // B
                self.pixels[px_offset + 1] = 255; // G
                self.pixels[px_offset + 2] = 255; // R
                self.pixels[px_offset + 3] = alpha; // A
            }
        }

        // Track dirty region
        if (!self.dirty) {
            self.dirty_min_x = pos.x;
            self.dirty_min_y = pos.y;
            self.dirty_max_x = pos.x + w;
            self.dirty_max_y = pos.y + h;
        } else {
            self.dirty_min_x = @min(self.dirty_min_x, pos.x);
            self.dirty_min_y = @min(self.dirty_min_y, pos.y);
            self.dirty_max_x = @max(self.dirty_max_x, pos.x + w);
            self.dirty_max_y = @max(self.dirty_max_y, pos.y + h);
        }
        self.dirty = true;

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

    /// Clear dirty tracking after texture upload.
    pub fn clearDirty(self: *FontAtlas) void {
        self.dirty = false;
    }
};
