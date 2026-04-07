const std = @import("std");
const Pty = @import("pty.zig").Pty;
const TerminalState = @import("terminal.zig").TerminalState;
const Renderer = @import("renderer.zig").Renderer;
const input = @import("input.zig");

const c = @import("sdl.zig").c;
const shim = @cImport({
    @cInclude("font_shim.h");
});
const window_shim = @cImport({
    @cInclude("window_shim.h");
});

const log = std.log.scoped(.stvt);

const FONT_NAME: [:0]const u8 = "JetBrainsMonoNL NF";
const FONT_SIZE: f32 = 14.0;
const INITIAL_COLS: u16 = 80;
const INITIAL_ROWS: u16 = 24;
const PTY_READ_BUF_SIZE: usize = 65536;
const IDLE_SLEEP_MS: u32 = 16;
const ACTIVE_SLEEP_MS: u32 = 1;
const COOLDOWN_ITERS: u32 = 10; // ~10ms of 1ms sleeps after PTY activity

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cols: u16 = INITIAL_COLS;
    var rows: u16 = INITIAL_ROWS;

    // Initialize PTY
    var pty = try Pty.spawn(cols, rows);
    defer pty.deinit();

    // Initialize ghostty-vt terminal state
    var term = try TerminalState.init(allocator, cols, rows, pty.master_fd);
    term.initStream();
    defer term.deinit();

    // Initialize SDL3
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    // Get cell metrics before creating window
    const probe_font = shim.font_init(FONT_NAME.ptr, FONT_SIZE);
    const metrics = shim.font_get_metrics(probe_font);
    shim.font_deinit(probe_font);
    const win_w: c_int = @intCast(@as(c_int, cols) * metrics.cell_width);
    const win_h: c_int = @intCast(@as(c_int, rows) * metrics.cell_height);

    const window = c.SDL_CreateWindow("stvt", win_w, win_h, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_TRANSPARENT | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLWindowFailed;
    };
    defer c.SDL_DestroyWindow(window);

    // Query display content scale for Retina/HiDPI rendering
    const content_scale = c.SDL_GetWindowDisplayScale(window);

    // Enable background blur via macOS compositor
    const win_props = c.SDL_GetWindowProperties(window);
    const nswindow = c.SDL_GetPointerProperty(win_props, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
    if (nswindow) |nswin| {
        window_shim.window_enable_blur(nswin);
    }

    _ = c.SDL_SetHint(c.SDL_HINT_RENDER_VSYNC, "0");
    const sdl_renderer = c.SDL_CreateRenderer(window, null) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLRendererFailed;
    };
    defer c.SDL_DestroyRenderer(sdl_renderer);

    // Initialize font atlas and renderer (font rasterized at scaled size for Retina)
    var renderer = try Renderer.init(allocator, sdl_renderer, FONT_NAME, FONT_SIZE, cols, rows, content_scale);
    defer renderer.deinit();

    // Wire up terminal callbacks that need renderer/window info
    term.setWindowAndMetrics(window, cols, rows, renderer.cellWidth(), renderer.cellHeight());

    // Enable text input events
    _ = c.SDL_StartTextInput(window);

    var running = true;
    var pty_buf: [PTY_READ_BUF_SIZE]u8 = undefined;
    var needs_redraw = true;

    // Cooldown: after PTY activity, use short sleep before falling back to long sleep
    var idle_count: u32 = 0;

    // Burst tracking for debug logging
    var burst_bytes: usize = 0;
    var burst_frames: u32 = 0;
    var burst_start: ?std.time.Instant = null;

    while (running) {
        // 1. Poll SDL events
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => {
                    running = false;
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    if (input.translateTextInput(event.text.text)) |text| {
                        term.terminal.scrollViewport(.bottom);
                        pty.write(text) catch |err| log.warn("pty write failed (text input): {}", .{err});
                    }
                },
                c.SDL_EVENT_KEY_DOWN => {
                    switch (input.translate(event.key)) {
                        .write => |seq| {
                            term.terminal.scrollViewport(.bottom);
                            pty.write(seq) catch |err| log.warn("pty write failed (key): {}", .{err});
                        },
                        .paste => {
                            const clip = c.SDL_GetClipboardText();
                            if (clip) |text| {
                                defer c.SDL_free(text);
                                const len = std.mem.len(text);
                                if (len > 0) {
                                    term.terminal.scrollViewport(.bottom);
                                    pty.write(text[0..len]) catch |err| log.warn("pty write failed (paste): {}", .{err});
                                }
                            }
                        },
                        .scroll_up => {
                            term.terminal.scrollViewport(.{ .delta = -@as(isize, @intCast(rows / 2)) });
                            renderer.force_full_redraw = true;
                            needs_redraw = true;
                        },
                        .scroll_down => {
                            term.terminal.scrollViewport(.{ .delta = @as(isize, @intCast(rows / 2)) });
                            renderer.force_full_redraw = true;
                            needs_redraw = true;
                        },
                        .quit => {
                            running = false;
                        },
                        .none => {},
                    }
                },
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
                    const new_pw: u32 = @intCast(event.window.data1);
                    const new_ph: u32 = @intCast(event.window.data2);
                    const new_cols: u16 = @intCast(@max(1, new_pw / renderer.cellWidth()));
                    const new_rows: u16 = @intCast(@max(1, new_ph / renderer.cellHeight()));

                    if (new_cols != cols or new_rows != rows) {
                        cols = new_cols;
                        rows = new_rows;

                        // Resize terminal grid
                        term.terminal.resize(allocator, cols, rows) catch |err| log.warn("terminal resize failed: {}", .{err});

                        // Notify PTY of new size
                        pty.notifyResize(cols, rows) catch |err| log.warn("pty resize notify failed: {}", .{err});

                        // Recreate offscreen texture and update size callbacks
                        renderer.resize(cols, rows);
                        term.setWindowAndMetrics(window, cols, rows, renderer.cellWidth(), renderer.cellHeight());
                        needs_redraw = true;
                    }
                },
                else => {},
            }
        }

        // 2. Read PTY output and feed to ghostty-vt
        //    Drain all available data before rendering — kernel PTY buffer limits read size
        var had_pty_data = false;
        var iter_bytes: usize = 0;
        while (true) {
            const data = pty.read(&pty_buf) catch |err| switch (err) {
                error.EndOfFile => {
                    running = false;
                    break;
                },
                else => break,
            };
            if (data.len == 0) break;
            term.feed(data);
            needs_redraw = true;
            had_pty_data = true;
            iter_bytes += data.len;
        }

        // 3. Render (dirty rows only, with offscreen texture)
        if (needs_redraw) {
            _ = renderer.renderFrame(&term);
            needs_redraw = false;
        }

        // Burst logging: track PTY activity and log summary when burst ends
        if (had_pty_data) {
            if (burst_start == null) burst_start = std.time.Instant.now() catch null;
            burst_bytes += iter_bytes;
            burst_frames += 1;
            idle_count = 0;
        } else {
            if (burst_start) |start| {
                const elapsed_ms = if (std.time.Instant.now()) |now|
                    now.since(start) / std.time.ns_per_ms
                else |_|
                    0;
                log.info("burst: {} bytes, {} frames, {}ms", .{ burst_bytes, burst_frames, elapsed_ms });
                burst_bytes = 0;
                burst_frames = 0;
                burst_start = null;
            }
            idle_count += 1;
        }

        // Check if shell exited
        if (!pty.isAlive()) {
            running = false;
        }

        // Sleep: short cooldown after PTY activity, then fall back to normal idle sleep
        if (!had_pty_data) {
            if (idle_count <= COOLDOWN_ITERS) {
                c.SDL_Delay(ACTIVE_SLEEP_MS);
            } else {
                c.SDL_Delay(IDLE_SLEEP_MS);
            }
        }
    }
}

