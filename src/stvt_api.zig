const std = @import("std");
const Pty = @import("pty.zig").Pty;
const TerminalState = @import("terminal.zig").TerminalState;
const FontAtlas = @import("font.zig").FontAtlas;
const input = @import("input.zig");
const color = @import("color.zig");
const g = @import("ghostty.zig").c;
const shim = @cImport({
    @cInclude("font_shim.h");
});

const log = std.log.scoped(.stvt_api);

const terminal_mod = @import("terminal.zig");

const FONT_NAME: [:0]const u8 = "JetBrainsMonoNL NF";
const FONT_SIZE: f32 = 14.0;
const PTY_READ_BUF_SIZE: usize = 65536;

/// Opaque handle to the terminal context, passed to/from ObjC.
const StvtContext = struct {
    allocator: std.mem.Allocator,
    pty: Pty,
    term: TerminalState,
    atlas: FontAtlas,
    cols: u16,
    rows: u16,
    content_scale: f32,
    pty_buf: [PTY_READ_BUF_SIZE]u8,
    key_encode_buf: [128]u8,

    // Selection state (viewport coordinates)
    sel_active: bool = false,
    sel_start_col: u16 = 0,
    sel_start_row: u16 = 0,
    sel_end_col: u16 = 0,
    sel_end_row: u16 = 0,
    // Grid refs for selection (resolved when selection starts/updates)
    sel_start_ref: g.GhosttyGridRef = .{ .size = @sizeOf(g.GhosttyGridRef), .node = null, .x = 0, .y = 0 },
    sel_end_ref: g.GhosttyGridRef = .{ .size = @sizeOf(g.GhosttyGridRef), .node = null, .x = 0, .y = 0 },
};

// ─── Lifecycle ───────────────────────────────────────────────────

export fn stvt_init(cols: u16, rows: u16, content_scale: f32) callconv(.c) ?*StvtContext {
    // Use libc allocator — simpler for a C-interop library
    const allocator = std.heap.c_allocator;

    const pty = Pty.spawn(cols, rows) catch |err| {
        log.err("PTY spawn failed: {}", .{err});
        return null;
    };

    var term = TerminalState.init(cols, rows, pty.master_fd) catch |err| {
        log.err("terminal init failed: {}", .{err});
        return null;
    };

    // Probe font metrics for initial cell size and set on terminal
    const probe = shim.font_init(FONT_NAME.ptr, FONT_SIZE * content_scale);
    const m = shim.font_get_metrics(probe);
    shim.font_deinit(probe);
    term.resize(cols, rows, @intCast(m.cell_width), @intCast(m.cell_height));

    const atlas = FontAtlas.init(allocator, FONT_NAME, FONT_SIZE, content_scale) catch |err| {
        log.err("font atlas init failed: {}", .{err});
        return null;
    };

    const ctx = allocator.create(StvtContext) catch return null;
    ctx.* = .{
        .allocator = allocator,
        .pty = pty,
        .term = term,
        .atlas = atlas,
        .cols = cols,
        .rows = rows,
        .content_scale = content_scale,
        .pty_buf = undefined,
        .key_encode_buf = undefined,
    };

    // Wire module-level callback state
    terminal_mod.setTitleStatePtr(&ctx.term);
    terminal_mod.setMouseCellSize(atlas.metrics.cell_width, atlas.metrics.cell_height);

    return ctx;
}

export fn stvt_destroy(ctx: ?*StvtContext) callconv(.c) void {
    const c = ctx orelse return;
    c.atlas.deinit();
    c.term.deinit();
    c.pty.deinit();
    // Note: can't easily deinit the GPA here since it was created on stack in init.
    // For a long-lived app this is fine — OS reclaims on exit.
}

// ─── PTY I/O ─────────────────────────────────────────────────────

/// Poll PTY for new data, feed to terminal, update render state.
/// Returns the dirty level: 0=clean, 1=partial, 2=full.
export fn stvt_poll(ctx: ?*StvtContext) callconv(.c) i32 {
    const c = ctx orelse return 0;
    var had_data = false;

    // Drain all available PTY data
    while (true) {
        const data = c.pty.read(&c.pty_buf) catch |err| switch (err) {
            error.EndOfFile => return -1, // shell exited
            else => break,
        };
        if (data.len == 0) break;
        c.term.feed(data);
        had_data = true;
    }

    if (!had_data) return 0;

    // Update render state
    const dirty = c.term.updateRenderState();
    return @intCast(dirty);
}

/// Check if shell process is still alive.
export fn stvt_is_alive(ctx: ?*StvtContext) callconv(.c) bool {
    const c = ctx orelse return false;
    return c.pty.isAlive();
}

// ─── Input ───────────────────────────────────────────────────────

/// Feed a key event. Returns: 0=written to PTY, 1=paste, 2=scroll_up, 3=scroll_down, 4=quit, -1=none
export fn stvt_feed_key(ctx: ?*StvtContext, keycode: u16, ns_mods: u32, utf8: ?[*]const u8, utf8_len: usize) callconv(.c) i32 {
    const c = ctx orelse return -1;

    const key = input.macVirtualKeyToGhosttyKey(keycode);
    const mods = input.nsModsToGhosttyMods(ns_mods);

    // Check app commands first (Cmd+Q, Cmd+V, Cmd+C, Shift+PageUp/Down, etc.)
    const app_cmd = input.checkAppCommand(key, mods);
    switch (app_cmd) {
        .copy => {
            if (c.sel_active) return 5;
            // No selection — ignore Cmd+C (not a terminal sequence)
            return -1;
        },
        .paste => return 1,
        .scroll_up => {
            c.term.scrollViewportDelta(-@as(i32, @intCast(c.rows / 2)));
            return 2;
        },
        .scroll_down => {
            c.term.scrollViewportDelta(@as(i32, @intCast(c.rows / 2)));
            return 3;
        },
        .scroll_page_up => {
            c.term.scrollViewportDelta(-@as(i32, @intCast(c.rows)));
            return 2;
        },
        .scroll_page_down => {
            c.term.scrollViewportDelta(@as(i32, @intCast(c.rows)));
            return 3;
        },
        .quit => return 4,
        .none => {},
    }

    // Encode key to VT sequence via ghostty key encoder
    // Filter out macOS private-use function key Unicode (U+F700-U+F7FF).
    // NSEvent.charactersIgnoringModifiers returns these for arrows, F-keys, etc.
    // If passed as utf8, the ghostty encoder outputs them verbatim instead of
    // generating proper VT sequences from the key code.
    const raw_utf8: ?[]const u8 = if (utf8 != null and utf8_len > 0) utf8.?[0..utf8_len] else null;
    const utf8_slice: ?[]const u8 = if (raw_utf8) |text| blk: {
        // U+F700 = EF 9C 80, U+F7FF = EF 9F BF
        if (text.len >= 3 and text[0] == 0xEF and text[1] >= 0x9C and text[1] <= 0x9F)
            break :blk null;
        break :blk text;
    } else null;
    var written = c.term.encodeKey(key, mods, g.GHOSTTY_KEY_ACTION_PRESS, utf8_slice, &c.key_encode_buf);

    // Fallback: ghostty encoder doesn't produce VT sequences for F13-F20.
    // Generate VT220 sequences manually (matches other macOS terminals).
    if (written == 0) {
        if (vt220FKeySequence(key)) |seq| {
            @memcpy(c.key_encode_buf[0..seq.len], seq);
            written = seq.len;
        }
    }

    if (written > 0) {
        // Scroll to bottom on input
        c.term.scrollViewportBottom();
        c.pty.write(c.key_encode_buf[0..written]) catch |err| {
            log.warn("pty write failed: {}", .{err});
        };
    }
    return 0;
}

/// VT220 escape sequences for F13-F20.
/// The ghostty key encoder doesn't produce sequences for these keys.
/// VT220 codes match other macOS terminals (Ghostty, iTerm2, Terminal.app).
fn vt220FKeySequence(key: g.GhosttyKey) ?[]const u8 {
    return switch (key) {
        g.GHOSTTY_KEY_F13 => "\x1b[25~",
        g.GHOSTTY_KEY_F14 => "\x1b[26~",
        g.GHOSTTY_KEY_F15 => "\x1b[28~", // VT220 skips 27
        g.GHOSTTY_KEY_F16 => "\x1b[29~",
        g.GHOSTTY_KEY_F17 => "\x1b[31~", // VT220 skips 30
        g.GHOSTTY_KEY_F18 => "\x1b[32~",
        g.GHOSTTY_KEY_F19 => "\x1b[33~",
        g.GHOSTTY_KEY_F20 => "\x1b[34~",
        else => null,
    };
}

/// Write raw text to PTY (for insertText: / text input events).
export fn stvt_feed_text(ctx: ?*StvtContext, text: ?[*]const u8, len: usize) callconv(.c) void {
    const c = ctx orelse return;
    if (text == null or len == 0) return;
    c.term.scrollViewportBottom();
    c.pty.write(text.?[0..len]) catch |err| {
        log.warn("pty write failed (text): {}", .{err});
    };
}

/// Paste text to PTY with bracketed paste encoding.
/// When len=0 and bracketed paste is active, sends empty bracket markers
/// so the application can detect the paste event (e.g. for image clipboard).
export fn stvt_paste(ctx: ?*StvtContext, text: ?[*]const u8, len: usize) callconv(.c) void {
    const c = ctx orelse return;
    c.term.scrollViewportBottom();

    const bracketed = c.term.isBracketedPaste();

    // Empty paste: only useful in bracketed mode (signals paste event to app)
    if (text == null or len == 0) {
        if (bracketed) {
            c.pty.write("\x1b[200~\x1b[201~") catch |err| {
                log.warn("pty write failed (empty paste): {}", .{err});
            };
        }
        return;
    }

    // ghostty_paste_encode modifies data in-place — make a mutable copy
    const alloc = std.heap.c_allocator;
    const data_copy = alloc.alloc(u8, len) catch {
        log.warn("paste alloc failed", .{});
        return;
    };
    defer alloc.free(data_copy);
    @memcpy(data_copy, text.?[0..len]);

    // Output buffer: input + room for bracket sequences (~12 bytes)
    const initial_size = len + 20;
    var out_buf = alloc.alloc(u8, initial_size) catch {
        log.warn("paste out alloc failed", .{});
        return;
    };

    var written: usize = 0;
    var result = g.ghostty_paste_encode(
        @ptrCast(data_copy.ptr),
        len,
        bracketed,
        @ptrCast(out_buf.ptr),
        out_buf.len,
        &written,
    );

    // Retry with larger buffer if needed
    if (result == g.GHOSTTY_OUT_OF_SPACE) {
        alloc.free(out_buf);
        out_buf = alloc.alloc(u8, written) catch {
            log.warn("paste realloc failed", .{});
            return;
        };
        // Fresh copy since first call modified data_copy in place
        @memcpy(data_copy, text.?[0..len]);
        result = g.ghostty_paste_encode(
            @ptrCast(data_copy.ptr),
            len,
            bracketed,
            @ptrCast(out_buf.ptr),
            out_buf.len,
            &written,
        );
    }
    defer alloc.free(out_buf);

    if (result == g.GHOSTTY_SUCCESS and written > 0) {
        c.pty.write(out_buf[0..written]) catch |err| {
            log.warn("pty write failed (paste): {}", .{err});
        };
    }
}

// ─── Resize ──────────────────────────────────────────────────────

export fn stvt_resize(ctx: ?*StvtContext, new_cols: u16, new_rows: u16) callconv(.c) void {
    const c = ctx orelse return;
    if (new_cols == c.cols and new_rows == c.rows) return;
    c.cols = new_cols;
    c.rows = new_rows;
    c.term.resize(new_cols, new_rows, c.atlas.metrics.cell_width, c.atlas.metrics.cell_height);
    const pw: u16 = @intCast(@as(u32, new_cols) * c.atlas.metrics.cell_width);
    const ph: u16 = @intCast(@as(u32, new_rows) * c.atlas.metrics.cell_height);
    c.pty.notifyResize(new_cols, new_rows, pw, ph) catch |err| {
        log.warn("pty resize failed: {}", .{err});
    };
}

// ─── Render State Access ─────────────────────────────────────────

/// Update render state and return dirty level.
export fn stvt_update_render_state(ctx: ?*StvtContext) callconv(.c) i32 {
    const c = ctx orelse return 0;
    return @intCast(c.term.updateRenderState());
}

/// Get the underlying ghostty render state handle (for direct C API access from ObjC).
export fn stvt_get_render_state(ctx: ?*StvtContext) callconv(.c) g.GhosttyRenderState {
    const c = ctx orelse return null;
    return c.term.render_state;
}

/// Get the ghostty terminal handle.
export fn stvt_get_terminal(ctx: ?*StvtContext) callconv(.c) g.GhosttyTerminal {
    const c = ctx orelse return null;
    return c.term.terminal;
}

// ─── Font Atlas Access ───────────────────────────────────────────

export fn stvt_get_atlas_pixels(ctx: ?*StvtContext) callconv(.c) ?[*]const u8 {
    const c = ctx orelse return null;
    return c.atlas.pixels.ptr;
}

export fn stvt_get_atlas_size(ctx: ?*StvtContext) callconv(.c) u32 {
    const c = ctx orelse return 0;
    return c.atlas.atlas_size;
}

export fn stvt_is_atlas_dirty(ctx: ?*StvtContext) callconv(.c) bool {
    const c = ctx orelse return false;
    return c.atlas.dirty;
}

export fn stvt_clear_atlas_dirty(ctx: ?*StvtContext) callconv(.c) void {
    const c = ctx orelse return;
    c.atlas.clearDirty();
}

const StvtAtlasDirtyRegion = extern struct {
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,
};

export fn stvt_get_atlas_dirty_region(ctx: ?*StvtContext) callconv(.c) StvtAtlasDirtyRegion {
    const c = ctx orelse return .{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 };
    return .{
        .min_x = c.atlas.dirty_min_x,
        .min_y = c.atlas.dirty_min_y,
        .max_x = c.atlas.dirty_max_x,
        .max_y = c.atlas.dirty_max_y,
    };
}

export fn stvt_get_cell_width(ctx: ?*StvtContext) callconv(.c) u32 {
    const c = ctx orelse return 0;
    return c.atlas.metrics.cell_width;
}

export fn stvt_get_cell_height(ctx: ?*StvtContext) callconv(.c) u32 {
    const c = ctx orelse return 0;
    return c.atlas.metrics.cell_height;
}

export fn stvt_get_ascent(ctx: ?*StvtContext) callconv(.c) u32 {
    const c = ctx orelse return 0;
    return c.atlas.metrics.ascent;
}

/// C-exported glyph info for ObjC consumption.
const StvtGlyphInfo = extern struct {
    atlas_x: u32,
    atlas_y: u32,
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
    advance: u32,
    found: bool,
};

/// Rasterize a glyph and return its atlas info.
export fn stvt_get_glyph(ctx: ?*StvtContext, codepoint: u32, style: u8) callconv(.c) StvtGlyphInfo {
    const c = ctx orelse return .{ .atlas_x = 0, .atlas_y = 0, .width = 0, .height = 0, .bearing_x = 0, .bearing_y = 0, .advance = 0, .found = false };
    const font_style: @import("font.zig").Style = @enumFromInt(@as(u2, @truncate(style)));
    if (c.atlas.getGlyph(codepoint, font_style)) |glyph| {
        return .{
            .atlas_x = glyph.atlas_x,
            .atlas_y = glyph.atlas_y,
            .width = glyph.width,
            .height = glyph.height,
            .bearing_x = glyph.bearing_x,
            .bearing_y = glyph.bearing_y,
            .advance = glyph.advance,
            .found = true,
        };
    }
    return .{ .atlas_x = 0, .atlas_y = 0, .width = 0, .height = 0, .bearing_x = 0, .bearing_y = 0, .advance = 0, .found = false };
}

// ─── Colors ──────────────────────────────────────────────────────

export fn stvt_get_default_bg_r(_: ?*StvtContext) callconv(.c) u8 { return color.default_bg.r; }
export fn stvt_get_default_bg_g(_: ?*StvtContext) callconv(.c) u8 { return color.default_bg.g; }
export fn stvt_get_default_bg_b(_: ?*StvtContext) callconv(.c) u8 { return color.default_bg.b; }
export fn stvt_get_bg_alpha(_: ?*StvtContext) callconv(.c) u8 { return color.BG_ALPHA; }
export fn stvt_get_default_fg_r(_: ?*StvtContext) callconv(.c) u8 { return color.default_fg.r; }
export fn stvt_get_default_fg_g(_: ?*StvtContext) callconv(.c) u8 { return color.default_fg.g; }
export fn stvt_get_default_fg_b(_: ?*StvtContext) callconv(.c) u8 { return color.default_fg.b; }

// ─── Grid Info ───────────────────────────────────────────────────

export fn stvt_get_cols(ctx: ?*StvtContext) callconv(.c) u16 {
    const c = ctx orelse return 0;
    return c.cols;
}

export fn stvt_get_rows(ctx: ?*StvtContext) callconv(.c) u16 {
    const c = ctx orelse return 0;
    return c.rows;
}

/// Clear render state dirty flags after rendering.
export fn stvt_clear_dirty(ctx: ?*StvtContext) callconv(.c) void {
    const c = ctx orelse return;
    c.term.clearDirty();
}

/// Get the range of dirty rows (min_row, max_row inclusive). Returns false if no dirty rows.
export fn stvt_get_dirty_rows(ctx: ?*StvtContext, out_min: ?*u16, out_max: ?*u16) callconv(.c) bool {
    const c = ctx orelse return false;
    var min_row: u16 = c.rows;
    var max_row: u16 = 0;
    var found = false;

    c.term.beginRowIteration();
    var row_idx: u16 = 0;
    while (c.term.nextRow()) : (row_idx += 1) {
        if (c.term.isRowDirty()) {
            if (!found) {
                min_row = row_idx;
                found = true;
            }
            max_row = row_idx;
        }
    }

    if (found) {
        if (out_min) |p| p.* = min_row;
        if (out_max) |p| p.* = max_row;
    }
    return found;
}

// ─── Title ──────────────────────────────────────────────────────

/// Get the current terminal title. Returns pointer and length.
export fn stvt_get_title(ctx: ?*StvtContext, out_len: ?*usize) callconv(.c) ?[*]const u8 {
    const c = ctx orelse return null;
    if (out_len) |len_ptr| len_ptr.* = c.term.title_len;
    if (c.term.title_len == 0) return null;
    return &c.term.title_buf;
}

/// Check and clear the title_changed flag.
export fn stvt_title_changed(ctx: ?*StvtContext) callconv(.c) bool {
    const c = ctx orelse return false;
    if (c.term.title_changed) {
        c.term.title_changed = false;
        return true;
    }
    return false;
}

// ─── PTY fd ─────────────────────────────────────────────────────

/// Get the PTY master file descriptor (for dispatch_source).
export fn stvt_get_pty_fd(ctx: ?*StvtContext) callconv(.c) i32 {
    const c = ctx orelse return -1;
    return c.pty.master_fd;
}

// ─── Scrollback ────────────────────────────────────────────────

/// Scroll viewport by delta rows (negative = up, positive = down).
export fn stvt_scroll_viewport(ctx: ?*StvtContext, delta: i32) callconv(.c) void {
    const c = ctx orelse return;
    c.term.scrollViewportDelta(delta);
}

// ─── Mouse ──────────────────────────────────────────────────────

/// Feed a mouse event. Returns true if data was written to PTY.
export fn stvt_feed_mouse(ctx: ?*StvtContext, action: u32, button: u32, ns_mods: u32, x: f32, y: f32) callconv(.c) bool {
    const c = ctx orelse return false;
    const mods = input.nsModsToGhosttyMods(ns_mods);
    return c.term.feedMouse(@intCast(action), @intCast(button), mods, x, y);
}

/// Check if the terminal has mouse tracking enabled.
export fn stvt_is_mouse_tracking(ctx: ?*StvtContext) callconv(.c) bool {
    const c = ctx orelse return false;
    return c.term.isMouseTracking();
}

/// Check if DECCKM (application cursor mode) is set.
export fn stvt_is_decckm(ctx: ?*StvtContext) callconv(.c) bool {
    const c = ctx orelse return false;
    return c.term.isDecckm();
}

/// Check if alternate screen is active (tmux, vim, less, etc.).
export fn stvt_is_alt_screen(ctx: ?*StvtContext) callconv(.c) bool {
    const c = ctx orelse return false;
    return c.term.isAltScreen();
}

// ─── Selection ──────────────────────────────────────────────────

fn pixelToGrid(c: *StvtContext, px_x: f32, px_y: f32) struct { col: u16, row: u16 } {
    const cw: f32 = @floatFromInt(c.atlas.metrics.cell_width);
    const ch: f32 = @floatFromInt(c.atlas.metrics.cell_height);
    var col: u16 = @intFromFloat(@max(0, px_x / cw));
    var row: u16 = @intFromFloat(@max(0, px_y / ch));
    if (col >= c.cols) col = c.cols -| 1;
    if (row >= c.rows) row = c.rows -| 1;
    return .{ .col = col, .row = row };
}

fn resolveGridRef(c: *StvtContext, col: u16, row: u16) g.GhosttyGridRef {
    const point = g.GhosttyPoint{
        .tag = g.GHOSTTY_POINT_TAG_VIEWPORT,
        .value = .{ .coordinate = .{ .x = col, .y = row } },
    };
    var ref = g.GhosttyGridRef{ .size = @sizeOf(g.GhosttyGridRef), .node = null, .x = 0, .y = 0 };
    _ = g.ghostty_terminal_grid_ref(c.term.terminal, point, &ref);
    return ref;
}

/// Start a selection at pixel coordinates.
export fn stvt_select_start(ctx: ?*StvtContext, px_x: f32, px_y: f32) callconv(.c) void {
    const c = ctx orelse return;
    const grid = pixelToGrid(c, px_x, px_y);
    c.sel_start_col = grid.col;
    c.sel_start_row = grid.row;
    c.sel_end_col = grid.col;
    c.sel_end_row = grid.row;
    c.sel_active = true;
    c.sel_start_ref = resolveGridRef(c, grid.col, grid.row);
    c.sel_end_ref = c.sel_start_ref;
}

/// Update the selection end point at pixel coordinates.
export fn stvt_select_update(ctx: ?*StvtContext, px_x: f32, px_y: f32) callconv(.c) void {
    const c = ctx orelse return;
    if (!c.sel_active) return;
    const grid = pixelToGrid(c, px_x, px_y);
    c.sel_end_col = grid.col;
    c.sel_end_row = grid.row;
    c.sel_end_ref = resolveGridRef(c, grid.col, grid.row);
}

/// Clear any active selection.
export fn stvt_select_clear(ctx: ?*StvtContext) callconv(.c) void {
    const c = ctx orelse return;
    c.sel_active = false;
}

/// Check if a cell at viewport (col, row) is within the current selection.
export fn stvt_is_cell_selected(ctx: ?*StvtContext, col: u16, row: u16) callconv(.c) bool {
    const c = ctx orelse return false;
    if (!c.sel_active) return false;

    // Normalize so start <= end
    var sr = c.sel_start_row;
    var sc = c.sel_start_col;
    var er = c.sel_end_row;
    var ec = c.sel_end_col;
    if (sr > er or (sr == er and sc > ec)) {
        sr = c.sel_end_row;
        sc = c.sel_end_col;
        er = c.sel_start_row;
        ec = c.sel_start_col;
    }

    // Check if (row, col) is within the selection range
    if (row < sr or row > er) return false;
    if (sr == er) return col >= sc and col <= ec;
    if (row == sr) return col >= sc;
    if (row == er) return col <= ec;
    return true;
}

/// Check if there is an active selection.
export fn stvt_has_selection(ctx: ?*StvtContext) callconv(.c) bool {
    const c = ctx orelse return false;
    return c.sel_active;
}

/// Copy selected text to the provided buffer. Returns bytes written.
export fn stvt_copy_selection(ctx: ?*StvtContext, out_buf: ?[*]u8, buf_len: usize) callconv(.c) usize {
    const c = ctx orelse return 0;
    if (!c.sel_active) return 0;
    if (out_buf == null or buf_len == 0) return 0;

    // Normalize start/end refs
    var start_ref = c.sel_start_ref;
    var end_ref = c.sel_end_ref;
    const sr = c.sel_start_row;
    const sc = c.sel_start_col;
    const er = c.sel_end_row;
    const ec = c.sel_end_col;
    if (sr > er or (sr == er and sc > ec)) {
        start_ref = c.sel_end_ref;
        end_ref = c.sel_start_ref;
    }

    // Build selection
    const selection = g.GhosttySelection{
        .size = @sizeOf(g.GhosttySelection),
        .start = start_ref,
        .end = end_ref,
        .rectangle = false,
    };

    // Create formatter with selection
    var opts: g.GhosttyFormatterTerminalOptions = std.mem.zeroes(g.GhosttyFormatterTerminalOptions);
    opts.size = @sizeOf(g.GhosttyFormatterTerminalOptions);
    opts.emit = g.GHOSTTY_FORMATTER_FORMAT_PLAIN;
    opts.trim = true;
    opts.unwrap = true;
    opts.selection = &selection;

    var formatter: g.GhosttyFormatter = null;
    if (g.ghostty_formatter_terminal_new(null, &formatter, c.term.terminal, opts) != g.GHOSTTY_SUCCESS) {
        return 0;
    }
    defer g.ghostty_formatter_free(formatter);

    // Format into caller's buffer
    var written: usize = 0;
    if (g.ghostty_formatter_format_buf(formatter, out_buf.?, buf_len, &written) == g.GHOSTTY_SUCCESS) {
        return written;
    }
    return 0;
}
