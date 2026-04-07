const std = @import("std");
const c = @import("sdl.zig").c;

/// Result of translating an SDL key event into a terminal action.
pub const Action = union(enum) {
    /// Bytes to write to the PTY (escape sequence or raw character).
    write: []const u8,
    /// Cmd+V: paste system clipboard into terminal.
    paste,
    /// Cmd+Up: scroll viewport up by half a page.
    scroll_up,
    /// Cmd+Down: scroll viewport down by half a page.
    scroll_down,
    /// Cmd+Q: quit the application.
    quit,
    /// No action for this event (e.g., bare modifier press, unknown Cmd combo).
    none,
};

/// Static buffer for building escape sequences that need runtime assembly
/// (e.g., Alt+key = ESC prefix + char, or modified arrow keys).
/// Safe because we only ever return one sequence per translate() call,
/// and the caller consumes it before the next call.
const SEQ_BUF_SIZE: usize = 16;
var seq_buf: [SEQ_BUF_SIZE]u8 = undefined;

/// Translate an SDL keyboard event into a terminal Action.
///
/// Modifier priority (highest to lowest):
///   1. Cmd (GUI) — intercepted for app commands, never reaches PTY
///   2. Ctrl+letter — generates control byte (0x01–0x1a)
///   3. Modified special keys — xterm-style sequences with modifier parameter
///   4. Alt + printable ASCII — ESC prefix (\x1b) before the character
///   5. Unmodified special keys — standard escape sequences
///
/// Returns .none for keys that should be ignored (bare modifiers, unknown combos).
/// Regular printable characters come through SDL_EVENT_TEXT_INPUT, not here.
pub fn translate(key_event: c.SDL_KeyboardEvent) Action {
    const key = key_event.key;
    const mods = key_event.mod;

    const has_cmd = (mods & c.SDL_KMOD_GUI) != 0;
    const has_ctrl = (mods & c.SDL_KMOD_CTRL) != 0;
    const has_alt = (mods & c.SDL_KMOD_ALT) != 0;
    const has_shift = (mods & c.SDL_KMOD_SHIFT) != 0;

    // Priority 1: Cmd (GUI) — app commands, never sent to PTY
    if (has_cmd) {
        return switch (key) {
            c.SDLK_V => .paste,
            c.SDLK_Q => .quit,
            c.SDLK_UP => .scroll_up,
            c.SDLK_DOWN => .scroll_down,
            else => .none,
        };
    }

    // Priority 2: Ctrl+letter — control bytes (0x01–0x1a)
    if (has_ctrl) {
        if (key >= 'a' and key <= 'z') {
            seq_buf[0] = @intCast(key - 'a' + 1);
            return .{ .write = seq_buf[0..1] };
        }
    }

    // Priority 3: Modified special keys (any combo of Shift/Alt/Ctrl)
    // Modifier value: 1 + shift(1) + alt(2) + ctrl(4), per xterm convention
    {
        const modifier: u8 = 1 +
            @as(u8, if (has_shift) 1 else 0) +
            @as(u8, if (has_alt) 2 else 0) +
            @as(u8, if (has_ctrl) 4 else 0);
        if (modifier > 1) {
            if (modifiedKeySequence(key, modifier)) |seq| {
                return .{ .write = seq };
            }
        }
    }

    // Priority 4: Alt/Option + printable ASCII — ESC prefix
    if (has_alt) {
        if (key >= 0x20 and key <= 0x7e) {
            seq_buf[0] = 0x1b;
            seq_buf[1] = @intCast(key);
            return .{ .write = seq_buf[0..2] };
        }
    }

    // Priority 5: Unmodified special keys
    if (specialKeySequence(key)) |seq| {
        return .{ .write = seq };
    }

    return .none;
}

/// Filter TEXT_INPUT events — returns the text to write to PTY,
/// or null if the event should be suppressed (e.g., Cmd+key fires
/// both KEY_DOWN and TEXT_INPUT on macOS, we only want KEY_DOWN).
pub fn translateTextInput(text: ?[*:0]const u8) ?[]const u8 {
    const t = text orelse return null;
    const len = std.mem.len(t);
    if (len == 0) return null;
    return t[0..len];
}

/// Lookup table for unmodified special keys.
/// Returns the escape sequence for a given SDL keycode, or null if not a special key.
fn specialKeySequence(key: c.SDL_Keycode) ?[]const u8 {
    return switch (key) {
        c.SDLK_RETURN => "\r",
        c.SDLK_BACKSPACE => "\x7f",
        c.SDLK_TAB => "\t",
        c.SDLK_ESCAPE => "\x1b",

        // Cursor keys
        c.SDLK_UP => "\x1b[A",
        c.SDLK_DOWN => "\x1b[B",
        c.SDLK_RIGHT => "\x1b[C",
        c.SDLK_LEFT => "\x1b[D",

        // Navigation
        c.SDLK_HOME => "\x1b[H",
        c.SDLK_END => "\x1b[F",
        c.SDLK_PAGEUP => "\x1b[5~",
        c.SDLK_PAGEDOWN => "\x1b[6~",
        c.SDLK_DELETE => "\x1b[3~",
        c.SDLK_INSERT => "\x1b[2~",

        // Function keys F1–F12
        c.SDLK_F1 => "\x1bOP",
        c.SDLK_F2 => "\x1bOQ",
        c.SDLK_F3 => "\x1bOR",
        c.SDLK_F4 => "\x1bOS",
        c.SDLK_F5 => "\x1b[15~",
        c.SDLK_F6 => "\x1b[17~",
        c.SDLK_F7 => "\x1b[18~",
        c.SDLK_F8 => "\x1b[19~",
        c.SDLK_F9 => "\x1b[20~",
        c.SDLK_F10 => "\x1b[21~",
        c.SDLK_F11 => "\x1b[23~",
        c.SDLK_F12 => "\x1b[24~",

        // F13–F24 (traditional "shifted" function keys, used by Hyperkey et al.)
        // Sequences match xterm-256color terminfo kf13–kf24.
        // macOS maps F13/F14/F15 to PrintScreen/ScrollLock/Pause HID codes,
        // so SDL3 reports those keycodes instead of SDLK_F13-F15.
        c.SDLK_F13 => "\x1b[1;2P",
        c.SDLK_F14 => "\x1b[1;2Q",
        c.SDLK_F15 => "\x1b[1;2R",
        // macOS maps F13/F14/F15 to PrintScreen/ScrollLock/Pause HID codes.
        // Remap tools (Hyperkey, Karabiner) sending "F13" arrive as SDLK_PRINTSCREEN.
        // Use VT220 sequences (\x1b[25~, etc.) — this is what other macOS terminals
        // send, and what tmux's built-in key table recognizes.
        c.SDLK_PRINTSCREEN => "\x1b[25~", // F13
        c.SDLK_SCROLLLOCK => "\x1b[26~", // F14
        c.SDLK_PAUSE => "\x1b[28~", // F15 (VT220 skips 27)
        c.SDLK_F16 => "\x1b[1;2S",
        c.SDLK_F17 => "\x1b[15;2~",
        c.SDLK_F18 => "\x1b[17;2~",
        c.SDLK_F19 => "\x1b[18;2~",
        c.SDLK_F20 => "\x1b[19;2~",
        c.SDLK_F21 => "\x1b[20;2~",
        c.SDLK_F22 => "\x1b[21;2~",
        c.SDLK_F23 => "\x1b[23;2~",
        c.SDLK_F24 => "\x1b[24;2~",

        else => null,
    };
}

/// Build a modified special key sequence per xterm conventions.
/// Modifier value: 2=Shift, 3=Alt, 4=Shift+Alt, 5=Ctrl, 6=Ctrl+Shift, 7=Ctrl+Alt, 8=all three
///
/// Two CSI formats:
///   Letter keys (arrows, Home/End, F1–F4): \x1b[1;{mod}{letter}
///   Tilde keys (F5–F12, PgUp/Dn, Del, Ins): \x1b[{num};{mod}~
///
/// Returns the sequence in seq_buf, or null if the key doesn't support modification.
fn modifiedKeySequence(key: c.SDL_Keycode, modifier: u8) ?[]const u8 {
    // Letter-suffix keys: \x1b[1;{mod}{suffix}
    const letter_suffix: ?u8 = switch (key) {
        c.SDLK_UP => 'A',
        c.SDLK_DOWN => 'B',
        c.SDLK_RIGHT => 'C',
        c.SDLK_LEFT => 'D',
        c.SDLK_HOME => 'H',
        c.SDLK_END => 'F',
        c.SDLK_F1, c.SDLK_F13, c.SDLK_PRINTSCREEN => 'P',
        c.SDLK_F2, c.SDLK_F14, c.SDLK_SCROLLLOCK => 'Q',
        c.SDLK_F3, c.SDLK_F15, c.SDLK_PAUSE => 'R',
        c.SDLK_F4, c.SDLK_F16 => 'S',
        else => null,
    };

    if (letter_suffix) |suffix| {
        seq_buf[0] = 0x1b;
        seq_buf[1] = '[';
        seq_buf[2] = '1';
        seq_buf[3] = ';';
        seq_buf[4] = '0' + modifier;
        seq_buf[5] = suffix;
        return seq_buf[0..6];
    }

    // Tilde-suffix keys: \x1b[{num};{mod}~
    const num: ?struct { u8, u8 } = switch (key) {
        c.SDLK_INSERT => .{ '2', 0 },
        c.SDLK_DELETE => .{ '3', 0 },
        c.SDLK_PAGEUP => .{ '5', 0 },
        c.SDLK_PAGEDOWN => .{ '6', 0 },
        c.SDLK_F5, c.SDLK_F17 => .{ '1', '5' },
        c.SDLK_F6, c.SDLK_F18 => .{ '1', '7' },
        c.SDLK_F7, c.SDLK_F19 => .{ '1', '8' },
        c.SDLK_F8, c.SDLK_F20 => .{ '1', '9' },
        c.SDLK_F9, c.SDLK_F21 => .{ '2', '0' },
        c.SDLK_F10, c.SDLK_F22 => .{ '2', '1' },
        c.SDLK_F11, c.SDLK_F23 => .{ '2', '3' },
        c.SDLK_F12, c.SDLK_F24 => .{ '2', '4' },
        else => null,
    };

    if (num) |digits| {
        var i: usize = 0;
        seq_buf[i] = 0x1b;
        i += 1;
        seq_buf[i] = '[';
        i += 1;
        if (digits[1] != 0) {
            seq_buf[i] = digits[0];
            i += 1;
            seq_buf[i] = digits[1];
            i += 1;
        } else {
            seq_buf[i] = digits[0];
            i += 1;
        }
        seq_buf[i] = ';';
        i += 1;
        seq_buf[i] = '0' + modifier;
        i += 1;
        seq_buf[i] = '~';
        i += 1;
        return seq_buf[0..i];
    }

    return null;
}
