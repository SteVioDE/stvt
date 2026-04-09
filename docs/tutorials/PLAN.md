# Tutorial: stvt — Build a Terminal Emulator from Scratch

**Goal:** Build a minimal, GPU-accelerated macOS terminal emulator using Zig, Objective-C, and Metal
**Reference branch:** main
**Language/Stack:** Zig + Objective-C + Metal + libghostty-vt
**Created:** 2026-04-09

## Chapters

- [ ] 01 — Project Setup & Build: Initialize with zig init, configure build.zig, justfile, and devbox
- [ ] 02 — PTY: Spawn a shell with forkpty, non-blocking read/write
- [ ] 03 — VT Parser Integration: Link libghostty-vt, create ghostty.zig and terminal.zig
- [ ] 04 — Color Palette: Build Gruvbox dark 256-color palette (color.zig)
- [ ] 05 — Font Rasterization: Core Text C bridge (font_shim) and glyph atlas (font.zig)
- [ ] 06 — C API Bridge: stvt_api.zig/h, main.zig with ~40 C-callable exports
- [ ] 07 — Native Window: app.m with NSApplication, translucent window, CAMetalLayer
- [ ] 08 — Metal Rendering: Shaders, pipeline states, triple-buffer, 3-pass rendering
- [ ] 09 — Text Rendering: Wire glyph atlas to Metal, render terminal grid
- [ ] 10 — Keyboard Input: input.zig key mapping, keyDown, NSTextInputClient
- [ ] 11 — Mouse, Selection & Scrollback: Mouse tracking, text selection, scroll viewport
- [ ] 12 — Polish & App Bundle: Paste, window title, resize, cursor styles, Info.plist, icon
