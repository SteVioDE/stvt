const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty = @import("ghostty");
const posix = std.posix;

const Terminal = ghostty.Terminal;
const Screen = ghostty.Screen;
const PageList = ghostty.PageList;
const Cell = ghostty.Cell;
const Style = ghostty.Style;

const c = @import("sdl.zig").c;

const log = std.log.scoped(.terminal);

// Extract callback return types from the Effects function pointer signatures.
// These types aren't exported from lib_vt, so we recover them at comptime.
const Handler = ghostty.TerminalStream.Handler;

fn effectReturnType(comptime field_name: []const u8) type {
    for (@typeInfo(Handler.Effects).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, field_name)) {
            const ptr_type = @typeInfo(f.type).optional.child;
            const fn_type = @typeInfo(ptr_type).pointer.child;
            return @typeInfo(fn_type).@"fn".return_type.?;
        }
    }
    unreachable;
}

const DeviceAttributes = effectReturnType("device_attributes");
const SizeReport = effectReturnType("size");

pub const TerminalState = struct {
    allocator: Allocator,
    terminal: Terminal,
    stream: ghostty.TerminalStream,
    pty_fd: posix.fd_t,

    /// Two-phase init: create the struct first, then call initStream()
    /// to wire up the stream with a stable pointer to the terminal.
    pub fn init(allocator: Allocator, init_cols: u16, init_rows: u16, pty_fd: posix.fd_t) !TerminalState {
        return .{
            .allocator = allocator,
            .terminal = try Terminal.init(allocator, .{
                .cols = init_cols,
                .rows = init_rows,
                .max_scrollback = 10_000,
            }),
            .stream = undefined,
            .pty_fd = pty_fd,
        };
    }

    /// Must be called after init, once the TerminalState is at its final
    /// memory location (not moved). This wires the stream handler to
    /// point at our terminal field.
    pub fn initStream(self: *TerminalState) void {
        // Store fd in module-level var so the callback can access it
        write_pty_fd = self.pty_fd;

        self.stream = ghostty.TerminalStream.initAlloc(self.allocator, .{
            .terminal = &self.terminal,
            .effects = .{
                .write_pty = &writePtyCallback,
                .bell = null,
                .color_scheme = null,
                .device_attributes = &deviceAttributesCallback,
                .enquiry = null,
                .size = &sizeCallback,
                .title_changed = &titleChangedCallback,
                .xtversion = null,
            },
        });
    }

    /// Set the SDL window reference and grid metrics for callbacks.
    pub fn setWindowAndMetrics(
        self: *const TerminalState,
        sdl_window: *c.SDL_Window,
        new_cols: u16,
        new_rows: u16,
        cell_width: u32,
        cell_height: u32,
    ) void {
        _ = self;
        sdl_window_ptr = sdl_window;
        grid_cols = new_cols;
        grid_rows = new_rows;
        cell_w = cell_width;
        cell_h = cell_height;
    }

    /// Feed raw bytes from the PTY into the VT parser.
    pub fn feed(self: *TerminalState, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    /// Get cursor position.
    pub fn getCursor(self: *const TerminalState) struct { x: u16, y: u16 } {
        const cursor = self.terminal.screens.active.cursor;
        return .{ .x = cursor.x, .y = cursor.y };
    }

    pub fn deinit(self: *TerminalState) void {
        self.stream.deinit();
        self.terminal.deinit(self.allocator);
    }
};

/// Module-level state for callbacks. Works because stvt has one terminal instance.
var write_pty_fd: posix.fd_t = -1;
var sdl_window_ptr: ?*c.SDL_Window = null;
var grid_cols: u16 = 0;
var grid_rows: u16 = 0;
var cell_w: u32 = 0;
var cell_h: u32 = 0;

fn writePtyCallback(_: *Handler, data: [:0]const u8) void {
    if (write_pty_fd < 0) return;
    _ = posix.write(write_pty_fd, data) catch |err| log.warn("pty write callback failed: {}", .{err});
}

fn deviceAttributesCallback(_: *Handler) DeviceAttributes {
    return .{};
}

fn sizeCallback(_: *Handler) SizeReport {
    if (cell_w == 0 or cell_h == 0) return null;
    return .{
        .rows = grid_rows,
        .columns = grid_cols,
        .cell_width = cell_w,
        .cell_height = cell_h,
    };
}

fn titleChangedCallback(handler: *Handler) void {
    const win = sdl_window_ptr orelse return;
    const title = handler.terminal.getTitle() orelse "stvt";
    _ = c.SDL_SetWindowTitle(win, title.ptr);
}
