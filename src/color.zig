pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// Default Gruvbox dark theme colors
pub const default_fg = RGB{ .r = 0xEB, .g = 0xDB, .b = 0xB2 };
pub const default_bg = RGB{ .r = 0x28, .g = 0x28, .b = 0x28 };
pub const BG_ALPHA: u8 = 0xBF;

/// Standard 256-color terminal palette.
/// Colors 0-7: standard ANSI (dark)
/// Colors 8-15: bright ANSI
/// Colors 16-231: 6x6x6 color cube
/// Colors 232-255: grayscale ramp
pub const palette_256: [256]RGB = init_palette();

/// xterm 256-color palette constants
const CUBE_LEVELS: u8 = 6;
const CUBE_SIZE: usize = 216; // CUBE_LEVELS^3
const CUBE_PLANE: usize = 36; // CUBE_LEVELS^2
const CUBE_BASE: u8 = 55;
const CUBE_STEP: u8 = 40;
const GRAY_RAMP_SIZE: usize = 24;
const GRAY_BASE: u8 = 8;
const GRAY_STEP: u8 = 10;

fn init_palette() [256]RGB {
    var pal: [256]RGB = undefined;

    // 0-7: standard ANSI colors (Gruvbox dark)
    pal[0] = .{ .r = 0x28, .g = 0x28, .b = 0x28 }; // black
    pal[1] = .{ .r = 0xCC, .g = 0x24, .b = 0x1D }; // red
    pal[2] = .{ .r = 0x98, .g = 0x97, .b = 0x1A }; // green
    pal[3] = .{ .r = 0xD7, .g = 0x99, .b = 0x21 }; // yellow
    pal[4] = .{ .r = 0x45, .g = 0x85, .b = 0x88 }; // blue
    pal[5] = .{ .r = 0xB1, .g = 0x62, .b = 0x86 }; // magenta
    pal[6] = .{ .r = 0x68, .g = 0x9D, .b = 0x6A }; // cyan
    pal[7] = .{ .r = 0xA8, .g = 0x99, .b = 0x84 }; // white

    // 8-15: bright ANSI colors (Gruvbox dark)
    pal[8] = .{ .r = 0x92, .g = 0x83, .b = 0x74 };  // bright black
    pal[9] = .{ .r = 0xFB, .g = 0x49, .b = 0x34 };  // bright red
    pal[10] = .{ .r = 0xB8, .g = 0xBB, .b = 0x26 }; // bright green
    pal[11] = .{ .r = 0xFA, .g = 0xBD, .b = 0x2F }; // bright yellow
    pal[12] = .{ .r = 0x83, .g = 0xA5, .b = 0x98 }; // bright blue
    pal[13] = .{ .r = 0xD3, .g = 0x86, .b = 0x9B }; // bright magenta
    pal[14] = .{ .r = 0x8E, .g = 0xC0, .b = 0x7C }; // bright cyan
    pal[15] = .{ .r = 0xEB, .g = 0xDB, .b = 0xB2 }; // bright white

    // 16-231: 6x6x6 color cube
    for (0..CUBE_SIZE) |i| {
        const r_idx: u8 = @intCast(i / CUBE_PLANE);
        const g_idx: u8 = @intCast((i % CUBE_PLANE) / CUBE_LEVELS);
        const b_idx: u8 = @intCast(i % CUBE_LEVELS);
        pal[16 + i] = .{
            .r = if (r_idx == 0) 0 else CUBE_BASE + CUBE_STEP * r_idx,
            .g = if (g_idx == 0) 0 else CUBE_BASE + CUBE_STEP * g_idx,
            .b = if (b_idx == 0) 0 else CUBE_BASE + CUBE_STEP * b_idx,
        };
    }

    // 232-255: grayscale ramp
    for (0..GRAY_RAMP_SIZE) |i| {
        const v: u8 = GRAY_BASE + GRAY_STEP * @as(u8, @intCast(i));
        pal[232 + i] = .{ .r = v, .g = v, .b = v };
    }

    return pal;
}

