// stvt — SteVio Terminal
// This file serves as the Zig library root. The actual entry point is in app.m (ObjC).
// All public symbols are exported from stvt_api.zig via C-callable functions.

// Force these modules to be compiled and their `export fn` symbols emitted.
comptime {
    _ = @import("stvt_api.zig");
}
