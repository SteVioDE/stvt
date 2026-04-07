// Shared SDL3 import — all modules import this to avoid @cImport opaque type mismatches.
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
