# Tutorial: stvt — Build a GPU-Accelerated Terminal Emulator

**Goal:** Build a minimal, fast macOS terminal emulator from scratch using Zig, Objective-C, Metal, and libghostty-vt
**Reference branch:** main
**Language/Stack:** Zig + Objective-C + C, macOS (AppKit, Metal, Core Text), libghostty-vt
**Created:** 2026-04-08

## Chapters

- [ ] 01 — Project Scaffold: Set up zig build, justfile, devbox, and link the ghostty xcframework
- [ ] 02 — Color Palette: Define the 256-color Gruvbox palette
- [ ] 03 — PTY: Fork a pseudo-terminal and spawn the user's shell
- [ ] 04 — Terminal State: Wrap libghostty-vt as the VT parser and screen model
- [ ] 05 — Input Translation: Map macOS keycodes to ghostty key events
- [ ] 06 — Font Rasterization: Rasterize glyphs via Core Text and build a glyph atlas
- [ ] 07 — C API Bridge: Export ~40 functions so ObjC can drive the Zig core
- [ ] 08 — AppKit Window: Create NSApplication, window, view, and Metal layer
- [ ] 09 — Metal Rendering: Implement shaders, vertex buffers, and the GPU render pipeline
- [ ] 10 — Terminal I/O: Wire PTY dispatch sources, feed output to ghostty, trigger redraws
- [ ] 11 — Keyboard & Mouse: Handle keyboard input via NSTextInputClient, mouse tracking, scrolling
- [ ] 12 — Selection, Clipboard & App Bundle: Add text selection, copy/paste, and package as .app
