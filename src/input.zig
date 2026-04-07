const std = @import("std");
const g = @import("ghostty.zig").c;

/// Result of translating a macOS key event into a terminal action.
pub const Action = union(enum) {
    /// Bytes to write to the PTY (escape sequence or raw character).
    write: []const u8,
    /// Cmd+V: paste system clipboard into terminal.
    paste,
    /// Cmd+Up: scroll viewport up by half a page.
    scroll_up,
    /// Cmd+Down: scroll viewport down by half a page.
    scroll_down,
    /// Shift+PageUp: scroll viewport up by one full page.
    scroll_page_up,
    /// Shift+PageDown: scroll viewport down by one full page.
    scroll_page_down,
    /// Cmd+C: copy selection to clipboard.
    copy,
    /// Cmd+Q: quit the application.
    quit,
    /// No action for this event.
    none,
};

/// Map a macOS virtual keycode (from NSEvent.keyCode) to a GhosttyKey.
/// Based on Carbon HIToolbox/Events.h kVK_* constants.
pub fn macVirtualKeyToGhosttyKey(keycode: u16) g.GhosttyKey {
    return switch (keycode) {
        0x00 => g.GHOSTTY_KEY_A,
        0x01 => g.GHOSTTY_KEY_S,
        0x02 => g.GHOSTTY_KEY_D,
        0x03 => g.GHOSTTY_KEY_F,
        0x04 => g.GHOSTTY_KEY_H,
        0x05 => g.GHOSTTY_KEY_G,
        0x06 => g.GHOSTTY_KEY_Z,
        0x07 => g.GHOSTTY_KEY_X,
        0x08 => g.GHOSTTY_KEY_C,
        0x09 => g.GHOSTTY_KEY_V,
        0x0B => g.GHOSTTY_KEY_B,
        0x0C => g.GHOSTTY_KEY_Q,
        0x0D => g.GHOSTTY_KEY_W,
        0x0E => g.GHOSTTY_KEY_E,
        0x0F => g.GHOSTTY_KEY_R,
        0x10 => g.GHOSTTY_KEY_Y,
        0x11 => g.GHOSTTY_KEY_T,
        0x12 => g.GHOSTTY_KEY_DIGIT_1,
        0x13 => g.GHOSTTY_KEY_DIGIT_2,
        0x14 => g.GHOSTTY_KEY_DIGIT_3,
        0x15 => g.GHOSTTY_KEY_DIGIT_4,
        0x16 => g.GHOSTTY_KEY_DIGIT_6,
        0x17 => g.GHOSTTY_KEY_DIGIT_5,
        0x18 => g.GHOSTTY_KEY_EQUAL,
        0x19 => g.GHOSTTY_KEY_DIGIT_9,
        0x1A => g.GHOSTTY_KEY_DIGIT_7,
        0x1B => g.GHOSTTY_KEY_MINUS,
        0x1C => g.GHOSTTY_KEY_DIGIT_8,
        0x1D => g.GHOSTTY_KEY_DIGIT_0,
        0x1E => g.GHOSTTY_KEY_BRACKET_RIGHT,
        0x1F => g.GHOSTTY_KEY_O,
        0x20 => g.GHOSTTY_KEY_U,
        0x21 => g.GHOSTTY_KEY_BRACKET_LEFT,
        0x22 => g.GHOSTTY_KEY_I,
        0x23 => g.GHOSTTY_KEY_P,
        0x24 => g.GHOSTTY_KEY_ENTER,
        0x25 => g.GHOSTTY_KEY_L,
        0x26 => g.GHOSTTY_KEY_J,
        0x27 => g.GHOSTTY_KEY_QUOTE,
        0x28 => g.GHOSTTY_KEY_K,
        0x29 => g.GHOSTTY_KEY_SEMICOLON,
        0x2A => g.GHOSTTY_KEY_BACKSLASH,
        0x2B => g.GHOSTTY_KEY_COMMA,
        0x2C => g.GHOSTTY_KEY_SLASH,
        0x2D => g.GHOSTTY_KEY_N,
        0x2E => g.GHOSTTY_KEY_M,
        0x2F => g.GHOSTTY_KEY_PERIOD,
        0x30 => g.GHOSTTY_KEY_TAB,
        0x31 => g.GHOSTTY_KEY_SPACE,
        0x32 => g.GHOSTTY_KEY_BACKQUOTE,
        0x33 => g.GHOSTTY_KEY_BACKSPACE,
        0x35 => g.GHOSTTY_KEY_ESCAPE,
        0x37 => g.GHOSTTY_KEY_META_LEFT,
        0x38 => g.GHOSTTY_KEY_SHIFT_LEFT,
        0x39 => g.GHOSTTY_KEY_CAPS_LOCK,
        0x3A => g.GHOSTTY_KEY_ALT_LEFT,
        0x3B => g.GHOSTTY_KEY_CONTROL_LEFT,
        0x3C => g.GHOSTTY_KEY_SHIFT_RIGHT,
        0x3D => g.GHOSTTY_KEY_ALT_RIGHT,
        0x3E => g.GHOSTTY_KEY_CONTROL_RIGHT,
        0x36 => g.GHOSTTY_KEY_META_RIGHT,

        // Function keys
        0x7A => g.GHOSTTY_KEY_F1,
        0x78 => g.GHOSTTY_KEY_F2,
        0x63 => g.GHOSTTY_KEY_F3,
        0x76 => g.GHOSTTY_KEY_F4,
        0x60 => g.GHOSTTY_KEY_F5,
        0x61 => g.GHOSTTY_KEY_F6,
        0x62 => g.GHOSTTY_KEY_F7,
        0x64 => g.GHOSTTY_KEY_F8,
        0x65 => g.GHOSTTY_KEY_F9,
        0x6D => g.GHOSTTY_KEY_F10,
        0x67 => g.GHOSTTY_KEY_F11,
        0x6F => g.GHOSTTY_KEY_F12,
        0x69 => g.GHOSTTY_KEY_F13,
        0x6B => g.GHOSTTY_KEY_F14,
        0x71 => g.GHOSTTY_KEY_F15,
        0x6A => g.GHOSTTY_KEY_F16,
        0x40 => g.GHOSTTY_KEY_F17,
        0x4F => g.GHOSTTY_KEY_F18,
        0x50 => g.GHOSTTY_KEY_F19,
        0x5A => g.GHOSTTY_KEY_F20,

        // Arrow keys
        0x7B => g.GHOSTTY_KEY_ARROW_LEFT,
        0x7C => g.GHOSTTY_KEY_ARROW_RIGHT,
        0x7D => g.GHOSTTY_KEY_ARROW_DOWN,
        0x7E => g.GHOSTTY_KEY_ARROW_UP,

        // Navigation
        0x73 => g.GHOSTTY_KEY_HOME,
        0x77 => g.GHOSTTY_KEY_END,
        0x74 => g.GHOSTTY_KEY_PAGE_UP,
        0x79 => g.GHOSTTY_KEY_PAGE_DOWN,
        0x75 => g.GHOSTTY_KEY_DELETE,
        0x72 => g.GHOSTTY_KEY_HELP, // maps to Insert on some keyboards

        // Numpad
        0x52 => g.GHOSTTY_KEY_NUMPAD_0,
        0x53 => g.GHOSTTY_KEY_NUMPAD_1,
        0x54 => g.GHOSTTY_KEY_NUMPAD_2,
        0x55 => g.GHOSTTY_KEY_NUMPAD_3,
        0x56 => g.GHOSTTY_KEY_NUMPAD_4,
        0x57 => g.GHOSTTY_KEY_NUMPAD_5,
        0x58 => g.GHOSTTY_KEY_NUMPAD_6,
        0x59 => g.GHOSTTY_KEY_NUMPAD_7,
        0x5B => g.GHOSTTY_KEY_NUMPAD_8,
        0x5C => g.GHOSTTY_KEY_NUMPAD_9,
        0x41 => g.GHOSTTY_KEY_NUMPAD_DECIMAL,
        0x43 => g.GHOSTTY_KEY_NUMPAD_MULTIPLY,
        0x45 => g.GHOSTTY_KEY_NUMPAD_ADD,
        0x4B => g.GHOSTTY_KEY_NUMPAD_DIVIDE,
        0x4C => g.GHOSTTY_KEY_NUMPAD_ENTER,
        0x4E => g.GHOSTTY_KEY_NUMPAD_SUBTRACT,
        0x51 => g.GHOSTTY_KEY_NUMPAD_EQUAL,
        0x47 => g.GHOSTTY_KEY_NUM_LOCK,

        else => g.GHOSTTY_KEY_UNIDENTIFIED,
    };
}

/// Convert NSEvent modifier flags to GhosttyMods bitmask.
/// NSEvent.modifierFlags bit positions:
///   bit 16 = Caps Lock
///   bit 17 = Shift
///   bit 18 = Control
///   bit 19 = Option/Alt
///   bit 20 = Command/Super
pub fn nsModsToGhosttyMods(ns_mods: u32) g.GhosttyMods {
    var mods: g.GhosttyMods = 0;
    if (ns_mods & (1 << 17) != 0) mods |= g.GHOSTTY_MODS_SHIFT;
    if (ns_mods & (1 << 18) != 0) mods |= g.GHOSTTY_MODS_CTRL;
    if (ns_mods & (1 << 19) != 0) mods |= g.GHOSTTY_MODS_ALT;
    if (ns_mods & (1 << 20) != 0) mods |= g.GHOSTTY_MODS_SUPER;
    if (ns_mods & (1 << 16) != 0) mods |= g.GHOSTTY_MODS_CAPS_LOCK;
    return mods;
}

/// Check if a key event is an app-level command (Cmd+Q, Cmd+V, etc.)
/// These are intercepted before being sent to the key encoder.
pub fn checkAppCommand(key: g.GhosttyKey, mods: g.GhosttyMods) Action {
    const has_cmd = (mods & g.GHOSTTY_MODS_SUPER) != 0;
    const has_shift = (mods & g.GHOSTTY_MODS_SHIFT) != 0;

    // Shift+PageUp/Down for scrollback (no Cmd required)
    if (has_shift and !has_cmd) {
        return switch (key) {
            g.GHOSTTY_KEY_PAGE_UP => .scroll_page_up,
            g.GHOSTTY_KEY_PAGE_DOWN => .scroll_page_down,
            else => .none,
        };
    }

    if (!has_cmd) return .none;

    return switch (key) {
        g.GHOSTTY_KEY_C => .copy,
        g.GHOSTTY_KEY_V => .paste,
        g.GHOSTTY_KEY_Q => .quit,
        g.GHOSTTY_KEY_ARROW_UP => .scroll_up,
        g.GHOSTTY_KEY_ARROW_DOWN => .scroll_down,
        else => .none,
    };
}
