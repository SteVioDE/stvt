/// Shared @cImport for the ghostty-vt xcframework C API.
/// All modules that need ghostty types import this instead of duplicating @cImport.
pub const c = @cImport({
    @cInclude("ghostty/vt.h");
});
