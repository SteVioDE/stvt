const std = @import("std");
const posix = std.posix;
const g = @import("ghostty.zig").c;

const log = std.log.scoped(.terminal);

pub const TerminalState = struct {
    terminal: g.GhosttyTerminal,
    render_state: g.GhosttyRenderState,
    row_iterator: g.GhosttyRenderStateRowIterator,
    row_cells: g.GhosttyRenderStateRowCells,
    key_encoder: g.GhosttyKeyEncoder,
    key_event: g.GhosttyKeyEvent,
    pty_fd: posix.fd_t,
    cols: u16,
    rows: u16,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    title_changed: bool = false,
    mouse_encoder: g.GhosttyMouseEncoder = null,
    mouse_event: g.GhosttyMouseEvent = null,

    pub fn init(cols: u16, rows: u16, pty_fd: posix.fd_t) !TerminalState {
        // Create terminal
        var terminal: g.GhosttyTerminal = null;
        const opts: g.GhosttyTerminalOptions = .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = 10_000,
        };
        if (g.ghostty_terminal_new(null, &terminal, opts) != g.GHOSTTY_SUCCESS) {
            return error.TerminalCreateFailed;
        }

        // Set write_pty callback — ghostty_terminal_set takes the function pointer cast to void*
        write_pty_fd = pty_fd;
        const write_fn: g.GhosttyTerminalWritePtyFn = &writePtyCallback;
        _ = g.ghostty_terminal_set(terminal, g.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @as(?*const anyopaque, @ptrCast(write_fn)));

        // Create render state
        var render_state: g.GhosttyRenderState = null;
        if (g.ghostty_render_state_new(null, &render_state) != g.GHOSTTY_SUCCESS) {
            g.ghostty_terminal_free(terminal);
            return error.RenderStateCreateFailed;
        }

        // Create row iterator (reusable)
        var row_iterator: g.GhosttyRenderStateRowIterator = null;
        if (g.ghostty_render_state_row_iterator_new(null, &row_iterator) != g.GHOSTTY_SUCCESS) {
            g.ghostty_render_state_free(render_state);
            g.ghostty_terminal_free(terminal);
            return error.RowIteratorCreateFailed;
        }

        // Create row cells (reusable)
        var row_cells: g.GhosttyRenderStateRowCells = null;
        if (g.ghostty_render_state_row_cells_new(null, &row_cells) != g.GHOSTTY_SUCCESS) {
            g.ghostty_render_state_row_iterator_free(row_iterator);
            g.ghostty_render_state_free(render_state);
            g.ghostty_terminal_free(terminal);
            return error.RowCellsCreateFailed;
        }

        // Create key encoder
        var key_encoder: g.GhosttyKeyEncoder = null;
        if (g.ghostty_key_encoder_new(null, &key_encoder) != g.GHOSTTY_SUCCESS) {
            g.ghostty_render_state_row_cells_free(row_cells);
            g.ghostty_render_state_row_iterator_free(row_iterator);
            g.ghostty_render_state_free(render_state);
            g.ghostty_terminal_free(terminal);
            return error.KeyEncoderCreateFailed;
        }

        // Create reusable key event
        var key_event: g.GhosttyKeyEvent = null;
        if (g.ghostty_key_event_new(null, &key_event) != g.GHOSTTY_SUCCESS) {
            g.ghostty_key_encoder_free(key_encoder);
            g.ghostty_render_state_row_cells_free(row_cells);
            g.ghostty_render_state_row_iterator_free(row_iterator);
            g.ghostty_render_state_free(render_state);
            g.ghostty_terminal_free(terminal);
            return error.KeyEventCreateFailed;
        }

        // Set macOS option-as-alt to true
        const opt_as_alt = g.GHOSTTY_OPTION_AS_ALT_TRUE;
        g.ghostty_key_encoder_setopt(key_encoder, g.GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &opt_as_alt);

        // Create mouse encoder
        var mouse_encoder: g.GhosttyMouseEncoder = null;
        if (g.ghostty_mouse_encoder_new(null, &mouse_encoder) != g.GHOSTTY_SUCCESS) {
            g.ghostty_key_event_free(key_event);
            g.ghostty_key_encoder_free(key_encoder);
            g.ghostty_render_state_row_cells_free(row_cells);
            g.ghostty_render_state_row_iterator_free(row_iterator);
            g.ghostty_render_state_free(render_state);
            g.ghostty_terminal_free(terminal);
            return error.MouseEncoderCreateFailed;
        }

        // Create reusable mouse event
        var mouse_event: g.GhosttyMouseEvent = null;
        if (g.ghostty_mouse_event_new(null, &mouse_event) != g.GHOSTTY_SUCCESS) {
            g.ghostty_mouse_encoder_free(mouse_encoder);
            g.ghostty_key_event_free(key_event);
            g.ghostty_key_encoder_free(key_encoder);
            g.ghostty_render_state_row_cells_free(row_cells);
            g.ghostty_render_state_row_iterator_free(row_iterator);
            g.ghostty_render_state_free(render_state);
            g.ghostty_terminal_free(terminal);
            return error.MouseEventCreateFailed;
        }

        // Set title_changed callback
        const title_fn: g.GhosttyTerminalTitleChangedFn = &titleChangedCallback;
        _ = g.ghostty_terminal_set(terminal, g.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, @as(?*const anyopaque, @ptrCast(title_fn)));

        return .{
            .terminal = terminal,
            .render_state = render_state,
            .row_iterator = row_iterator,
            .row_cells = row_cells,
            .key_encoder = key_encoder,
            .key_event = key_event,
            .pty_fd = pty_fd,
            .cols = cols,
            .rows = rows,
            .mouse_encoder = mouse_encoder,
            .mouse_event = mouse_event,
        };
    }

    pub fn deinit(self: *TerminalState) void {
        g.ghostty_mouse_event_free(self.mouse_event);
        g.ghostty_mouse_encoder_free(self.mouse_encoder);
        g.ghostty_key_event_free(self.key_event);
        g.ghostty_key_encoder_free(self.key_encoder);
        g.ghostty_render_state_row_cells_free(self.row_cells);
        g.ghostty_render_state_row_iterator_free(self.row_iterator);
        g.ghostty_render_state_free(self.render_state);
        g.ghostty_terminal_free(self.terminal);
    }

    /// Feed raw bytes from the PTY into the VT parser.
    pub fn feed(self: *TerminalState, bytes: []const u8) void {
        g.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
    }

    /// Update render state from terminal. Returns dirty level (0=clean, 1=partial, 2=full).
    pub fn updateRenderState(self: *TerminalState) u32 {
        _ = g.ghostty_render_state_update(self.render_state, self.terminal);
        var dirty: c_uint = g.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        _ = g.ghostty_render_state_get(self.render_state, g.GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
        return dirty;
    }

    /// Clear dirty state after rendering.
    pub fn clearDirty(self: *TerminalState) void {
        const clean = g.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        _ = g.ghostty_render_state_set(self.render_state, g.GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean);
    }

    /// Get render state colors.
    pub fn getColors(self: *TerminalState) g.GhosttyRenderStateColors {
        var colors: g.GhosttyRenderStateColors = .{ .size = @sizeOf(g.GhosttyRenderStateColors) };
        _ = g.ghostty_render_state_colors_get(self.render_state, &colors);
        return colors;
    }

    /// Populate the row iterator from render state.
    pub fn beginRowIteration(self: *TerminalState) void {
        _ = g.ghostty_render_state_get(self.render_state, g.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @as(?*anyopaque, @ptrCast(&self.row_iterator)));
    }

    /// Advance to next row. Returns false when done.
    pub fn nextRow(self: *TerminalState) bool {
        return g.ghostty_render_state_row_iterator_next(self.row_iterator);
    }

    /// Check if current row is dirty.
    pub fn isRowDirty(self: *TerminalState) bool {
        var dirty: bool = false;
        _ = g.ghostty_render_state_row_get(self.row_iterator, g.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &dirty);
        return dirty;
    }

    /// Clear dirty flag on current row.
    pub fn clearRowDirty(self: *TerminalState) void {
        const clean = false;
        _ = g.ghostty_render_state_row_set(self.row_iterator, g.GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean);
    }

    /// Populate row cells for the current row.
    pub fn beginCellIteration(self: *TerminalState) void {
        _ = g.ghostty_render_state_row_get(self.row_iterator, g.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &self.row_cells);
    }

    /// Advance to next cell. Returns false when done.
    pub fn nextCell(self: *TerminalState) bool {
        return g.ghostty_render_state_row_cells_next(self.row_cells);
    }

    /// Get raw cell value.
    pub fn getCell(self: *TerminalState) g.GhosttyCell {
        var cell: g.GhosttyCell = 0;
        _ = g.ghostty_render_state_row_cells_get(self.row_cells, g.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &cell);
        return cell;
    }

    /// Get cell codepoint.
    pub fn getCellCodepoint(cell: g.GhosttyCell) u32 {
        var cp: u32 = 0;
        _ = g.ghostty_cell_get(cell, g.GHOSTTY_CELL_DATA_CODEPOINT, &cp);
        return cp;
    }

    /// Check if cell has text.
    pub fn cellHasText(cell: g.GhosttyCell) bool {
        var has_text: bool = false;
        _ = g.ghostty_cell_get(cell, g.GHOSTTY_CELL_DATA_HAS_TEXT, &has_text);
        return has_text;
    }

    /// Get cell wide property.
    pub fn getCellWide(cell: g.GhosttyCell) g.GhosttyCellWide {
        var wide: g.GhosttyCellWide = g.GHOSTTY_CELL_WIDE_NARROW;
        _ = g.ghostty_cell_get(cell, g.GHOSTTY_CELL_DATA_WIDE, &wide);
        return wide;
    }

    /// Get cell style.
    pub fn getCellStyle(self: *TerminalState) g.GhosttyStyle {
        var style: g.GhosttyStyle = .{ .size = @sizeOf(g.GhosttyStyle) };
        _ = g.ghostty_render_state_row_cells_get(self.row_cells, g.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
        return style;
    }

    /// Get resolved background color for current cell. Returns null if default.
    pub fn getCellBgColor(self: *TerminalState) ?g.GhosttyColorRgb {
        var color: g.GhosttyColorRgb = undefined;
        const result = g.ghostty_render_state_row_cells_get(self.row_cells, g.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &color);
        if (result != g.GHOSTTY_SUCCESS) return null;
        return color;
    }

    /// Get resolved foreground color for current cell. Returns null if default.
    pub fn getCellFgColor(self: *TerminalState) ?g.GhosttyColorRgb {
        var color: g.GhosttyColorRgb = undefined;
        const result = g.ghostty_render_state_row_cells_get(self.row_cells, g.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &color);
        if (result != g.GHOSTTY_SUCCESS) return null;
        return color;
    }

    /// Get cursor info from render state.
    pub fn getCursor(self: *TerminalState) CursorInfo {
        var info = CursorInfo{};

        _ = g.ghostty_render_state_get(self.render_state, g.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &info.visible);
        if (info.visible) {
            _ = g.ghostty_render_state_get(self.render_state, g.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &info.x);
            _ = g.ghostty_render_state_get(self.render_state, g.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &info.y);
            _ = g.ghostty_render_state_get(self.render_state, g.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &info.style);
        }
        // Also check cursor visibility mode
        var mode_visible: bool = true;
        _ = g.ghostty_render_state_get(self.render_state, g.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &mode_visible);
        info.visible = info.visible and mode_visible;

        return info;
    }

    /// Resize terminal and update grid dimensions.
    pub fn resize(self: *TerminalState, new_cols: u16, new_rows: u16, cell_w: u32, cell_h: u32) void {
        _ = g.ghostty_terminal_resize(self.terminal, new_cols, new_rows, cell_w, cell_h);
        self.cols = new_cols;
        self.rows = new_rows;
    }

    /// Scroll viewport by delta (negative = up).
    pub fn scrollViewportDelta(self: *TerminalState, delta: i32) void {
        const scroll = g.GhosttyTerminalScrollViewport{
            .tag = g.GHOSTTY_SCROLL_VIEWPORT_DELTA,
            .value = .{ .delta = @intCast(delta) },
        };
        g.ghostty_terminal_scroll_viewport(self.terminal, scroll);
    }

    /// Scroll viewport to bottom.
    pub fn scrollViewportBottom(self: *TerminalState) void {
        const scroll = g.GhosttyTerminalScrollViewport{
            .tag = g.GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
            .value = .{ .delta = 0 },
        };
        g.ghostty_terminal_scroll_viewport(self.terminal, scroll);
    }

    /// Encode a key event and return the VT sequence to write to PTY.
    /// Returns the number of bytes written to out_buf.
    pub fn encodeKey(self: *TerminalState, key: g.GhosttyKey, mods: g.GhosttyMods, action: g.GhosttyKeyAction, utf8: ?[]const u8, out_buf: []u8) usize {
        // Sync encoder state from terminal (DECCKM, Kitty flags, etc.)
        g.ghostty_key_encoder_setopt_from_terminal(self.key_encoder, self.terminal);
        // Re-apply option-as-alt (reset by setopt_from_terminal)
        const opt_as_alt = g.GHOSTTY_OPTION_AS_ALT_TRUE;
        g.ghostty_key_encoder_setopt(self.key_encoder, g.GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &opt_as_alt);

        g.ghostty_key_event_set_action(self.key_event, action);
        g.ghostty_key_event_set_key(self.key_event, key);
        g.ghostty_key_event_set_mods(self.key_event, mods);

        if (utf8) |text| {
            g.ghostty_key_event_set_utf8(self.key_event, text.ptr, text.len);
        } else {
            g.ghostty_key_event_set_utf8(self.key_event, null, 0);
        }

        var written: usize = 0;
        const result = g.ghostty_key_encoder_encode(self.key_encoder, self.key_event, out_buf.ptr, out_buf.len, &written);
        if (result != g.GHOSTTY_SUCCESS) return 0;

        // Debug: log DECCKM state for arrow keys to verify application cursor mode
        if (written > 0 and key >= g.GHOSTTY_KEY_ARROW_DOWN and key <= g.GHOSTTY_KEY_ARROW_UP) {
            log.debug("arrow key: DECCKM={}, encoded={x}", .{ self.isDecckm(), out_buf[0..written] });
        }

        return written;
    }

    /// Encode a mouse event and write to PTY. Returns true if data was written.
    pub fn feedMouse(self: *TerminalState, action: g.GhosttyMouseAction, button: g.GhosttyMouseButton, mods: g.GhosttyMods, x: f32, y: f32) bool {
        // Sync encoder from terminal state (tracking mode, format)
        g.ghostty_mouse_encoder_setopt_from_terminal(self.mouse_encoder, self.terminal);

        // Set size context
        const size = g.GhosttyMouseEncoderSize{
            .size = @sizeOf(g.GhosttyMouseEncoderSize),
            .screen_width = @as(u32, self.cols) * self.getCellWidth(),
            .screen_height = @as(u32, self.rows) * self.getCellHeight(),
            .cell_width = self.getCellWidth(),
            .cell_height = self.getCellHeight(),
            .padding_top = 0,
            .padding_bottom = 0,
            .padding_left = 0,
            .padding_right = 0,
        };
        g.ghostty_mouse_encoder_setopt(self.mouse_encoder, g.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);

        // Set event properties
        g.ghostty_mouse_event_set_action(self.mouse_event, action);
        if (button == g.GHOSTTY_MOUSE_BUTTON_UNKNOWN) {
            g.ghostty_mouse_event_clear_button(self.mouse_event);
        } else {
            g.ghostty_mouse_event_set_button(self.mouse_event, button);
        }
        g.ghostty_mouse_event_set_mods(self.mouse_event, mods);
        g.ghostty_mouse_event_set_position(self.mouse_event, .{ .x = x, .y = y });

        // Encode
        var buf: [128]u8 = undefined;
        var written: usize = 0;
        const result = g.ghostty_mouse_encoder_encode(self.mouse_encoder, self.mouse_event, &buf, buf.len, &written);
        if (result != g.GHOSTTY_SUCCESS or written == 0) return false;

        // Write to PTY
        const pty_fd = write_pty_fd;
        if (pty_fd < 0) return false;
        _ = posix.write(pty_fd, buf[0..written]) catch return false;
        return true;
    }

    /// Check if the terminal has mouse tracking enabled.
    pub fn isMouseTracking(self: *TerminalState) bool {
        var tracking: bool = false;
        _ = g.ghostty_terminal_get(self.terminal, g.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking);
        return tracking;
    }

    /// Pack a GhosttyMode value in Zig. ghostty_mode_new is a static inline C
    /// function which Zig's @cImport cannot link — reimplement the bit-packing.
    /// DEC private mode (ansi=false): value & 0x7FFF. ANSI mode: value | 0x8000.
    fn modeNew(value: u16, ansi: bool) g.GhosttyMode {
        return (value & 0x7FFF) | (@as(u16, @intFromBool(ansi)) << 15);
    }

    fn isModeSet(self: *TerminalState, mode: g.GhosttyMode) bool {
        var mode_set: bool = false;
        _ = g.ghostty_terminal_mode_get(self.terminal, mode, &mode_set);
        return mode_set;
    }

    /// Check if DECCKM (application cursor mode) is set.
    pub fn isDecckm(self: *TerminalState) bool {
        return self.isModeSet(modeNew(1, false));
    }

    /// Check if alternate screen is active (mode 1049, 1047, or 47).
    pub fn isAltScreen(self: *TerminalState) bool {
        return self.isModeSet(modeNew(1049, false)) or
            self.isModeSet(modeNew(1047, false)) or
            self.isModeSet(modeNew(47, false));
    }

    /// Check if bracketed paste mode is active (mode 2004).
    pub fn isBracketedPaste(self: *TerminalState) bool {
        return self.isModeSet(modeNew(2004, false));
    }

    fn getCellWidth(self: *TerminalState) u32 {
        // We don't store cell dimensions directly — get from render state
        // This is used only for mouse encoding size context
        _ = self;
        return mouse_cell_width;
    }

    fn getCellHeight(self: *TerminalState) u32 {
        _ = self;
        return mouse_cell_height;
    }
};

pub const CursorInfo = struct {
    visible: bool = false,
    x: u16 = 0,
    y: u16 = 0,
    style: g.GhosttyRenderStateCursorVisualStyle = g.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK,
};

/// Module-level state for callbacks.
var write_pty_fd: posix.fd_t = -1;
var title_state: ?*TerminalState = null;
var mouse_cell_width: u32 = 8;
var mouse_cell_height: u32 = 16;

pub fn setMouseCellSize(cw: u32, ch: u32) void {
    mouse_cell_width = cw;
    mouse_cell_height = ch;
}

pub fn setTitleStatePtr(state: *TerminalState) void {
    title_state = state;
}

fn writePtyCallback(_: g.GhosttyTerminal, _: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    if (write_pty_fd < 0) return;
    if (data == null or len == 0) return;
    _ = posix.write(write_pty_fd, data[0..len]) catch |err| {
        log.warn("pty write callback failed: {}", .{err});
    };
}

fn titleChangedCallback(terminal: g.GhosttyTerminal, _: ?*anyopaque) callconv(.c) void {
    const state = title_state orelse return;
    var title_str: g.GhosttyString = .{ .ptr = null, .len = 0 };
    if (g.ghostty_terminal_get(terminal, g.GHOSTTY_TERMINAL_DATA_TITLE, &title_str) != g.GHOSTTY_SUCCESS) return;
    if (title_str.ptr == null or title_str.len == 0) {
        state.title_len = 0;
        state.title_changed = true;
        return;
    }
    const copy_len = @min(title_str.len, state.title_buf.len);
    @memcpy(state.title_buf[0..copy_len], title_str.ptr[0..copy_len]);
    state.title_len = copy_len;
    state.title_changed = true;
}
