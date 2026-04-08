const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("util.h"); // forkpty on macOS
    @cInclude("sys/ioctl.h"); // TIOCSWINSZ
    @cInclude("stdlib.h"); // setenv, getenv
    @cInclude("unistd.h"); // execvp
});

const DEFAULT_TERM: [*:0]const u8 = "xterm-256color";
const DEFAULT_COLORTERM: [*:0]const u8 = "truecolor";
const FALLBACK_SHELL: [*:0]const u8 = "/bin/zsh";

pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,

    /// Create a PTY pair, fork a child process, and exec the user's shell.
    /// The child gets stdin/stdout/stderr connected to the slave side.
    /// The master fd is set to non-blocking for polling in the event loop.
    pub fn spawn(cols: u16, rows: u16) !Pty {
        var ws: c.struct_winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        var master_fd: posix.fd_t = undefined;
        const pid = c.forkpty(&master_fd, null, null, &ws);

        if (pid < 0) return error.ForkPtyFailed;

        if (pid == 0) {
            // Child process — exec the shell
            childExec();
        }

        // Parent process — set master fd to non-blocking
        const flags = try posix.fcntl(master_fd, posix.F.GETFL, 0);
        const o_nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
        _ = try posix.fcntl(master_fd, posix.F.SETFL, flags | @as(usize, o_nonblock));

        return .{
            .master_fd = master_fd,
            .child_pid = pid,
        };
    }

    /// Non-blocking read from the master fd.
    /// Returns a slice of bytes read, or empty slice if nothing available.
    pub fn read(self: *Pty, buf: []u8) ![]u8 {
        const n = posix.read(self.master_fd, buf) catch |err| switch (err) {
            error.WouldBlock => return buf[0..0],
            else => return err,
        };
        if (n == 0) return error.EndOfFile;
        return buf[0..n];
    }

    /// Write bytes to the master fd (sends input to the shell).
    pub fn write(self: *Pty, data: []const u8) !void {
        var total: usize = 0;
        while (total < data.len) {
            const n = posix.write(self.master_fd, data[total..]) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            total += n;
        }
    }

    /// Notify the child process of a terminal resize via TIOCSWINSZ ioctl.
    pub fn notifyResize(self: *Pty, cols: u16, rows: u16, pw: u16, ph: u16) !void {
        var ws: c.struct_winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = pw,
            .ws_ypixel = ph,
        };
        const ret = c.ioctl(self.master_fd, c.TIOCSWINSZ, &ws);
        if (ret < 0) return error.IoctlFailed;
    }

    /// Check if the child process has exited.
    pub fn isAlive(self: *Pty) bool {
        const result = posix.waitpid(self.child_pid, posix.W.NOHANG);
        return result.pid == 0; // 0 means child still running
    }

    /// Clean up: close the master fd.
    pub fn deinit(self: *Pty) void {
        posix.close(self.master_fd);
    }
};

/// Called in the child process after fork. Sets up environment and execs the shell.
/// This function never returns — it either execs or exits.
fn childExec() noreturn {
    // Set terminal environment
    _ = c.setenv("TERM", DEFAULT_TERM, 1);
    _ = c.setenv("COLORTERM", DEFAULT_COLORTERM, 1);

    // Ensure UTF-8 locale — .app bundles launched from Finder/Spotlight
    // often lack LANG, defaulting to "C" locale. Programs like tmux/ncurses
    // check LANG to decide UTF-8 support; without it they replace Unicode
    // characters with ASCII fallbacks (typically '_').
    if (c.getenv("LANG") == null) {
        _ = c.setenv("LANG", "en_US.UTF-8", 0);
    }

    // Change to user's home directory (app bundles start at /)
    const home = c.getenv("HOME");
    if (home != null) {
        _ = c.chdir(home);
    }

    // Get the user's shell
    const shell: [*:0]const u8 = c.getenv("SHELL") orelse FALLBACK_SHELL;

    // Build login shell argv[0]: "-zsh" from "/bin/zsh"
    // Shells check if argv[0] starts with '-' to enable login mode
    var login_name: [256:0]u8 = undefined;
    login_name[0] = '-';
    const shell_span = std.mem.span(shell);
    const base = if (std.mem.lastIndexOfScalar(u8, shell_span, '/')) |i| shell_span[i + 1 ..] else shell_span;
    @memcpy(login_name[1 .. 1 + base.len], base);
    login_name[1 + base.len] = 0;

    const argv = [_:null]?[*:0]const u8{ &login_name, null };
    _ = c.execvp(shell, @ptrCast(&argv));

    // If exec failed, exit
    std.c.exit(1);
}
