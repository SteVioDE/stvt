# Tutorial: stvt — Build a Terminal Emulator from Scratch

**Goal:** Build a minimal, high-performance macOS terminal emulator using Zig + Objective-C with Metal GPU rendering and libghostty-vt for VT parsing.
**Reference branch:** main
**Language/Stack:** Zig 0.15 + Objective-C, AppKit, Metal, Core Text, libghostty-vt
**Created:** 2026-04-10

## Chapters

- [ ] 01 — Project Setup: Initialize the Zig project with devbox, justfile, and project scaffolding
- [ ] 02 — Build System: Configure build.zig for dual compilation (Zig static lib + ObjC executable) with xcframework and macOS framework linking
- [ ] 03 — PTY Management: Spawn a shell with forkpty, implement non-blocking I/O, resize, and child exit detection
- [ ] 04 — Terminal Core: Integrate libghostty-vt via @cImport, wrap terminal state, VT parsing, and render state snapshots
- [ ] 05 — Colors & Input: Define the Gruvbox 256-color palette and translate macOS keycodes to ghostty key/modifier mappings
- [ ] 06 — Font Rendering: Build a Core Text C shim and Zig glyph atlas with on-demand rasterization and dirty region tracking
- [ ] 07 — C API Bridge: Export ~40 Zig functions with C calling convention and create the public header for ObjC consumption
- [ ] 08 — AppKit Window: Set up NSApplication, borderless window, Metal layer, visual effect blur, and HiDPI support
- [ ] 09 — Metal Rendering: Implement inline shaders and the 3-pass GPU pipeline (backgrounds, glyphs, cursor/decorations)
- [ ] 10 — Events & Interaction: Wire up keyboard, mouse, scroll, text input via NSTextInputClient, and dispatch_source PTY polling
- [ ] 11 — Selection & App Bundle: Add text selection, clipboard, scrollback navigation, window title updates, and .app bundle packaging
