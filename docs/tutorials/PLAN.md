# Tutorial: stvt — Build a Terminal Emulator from Scratch

**Goal:** Build a minimal, GPU-accelerated macOS terminal emulator using Zig, Objective-C, and Metal — from an empty directory to a fully working app.
**Reference branch:** main
**Language/Stack:** Zig + Objective-C + Metal + libghostty-vt
**Created:** 2026-04-09

## Chapters

- [ ] 01 — Project Setup & Build: Initialize with `zig init`, configure build.zig, justfile, and devbox. Verify the project builds and runs a hello world.
- [ ] 02 — PTY: Spawn a shell with `forkpty`, implement non-blocking read/write. Verify by dumping raw shell output to stdout.
- [ ] 03 — VT Parser Integration: Link libghostty-vt, create ghostty.zig and terminal.zig to parse escape sequences. Verify by feeding PTY data through the parser.
- [ ] 04 — Color Palette: Build color.zig with the Gruvbox dark 256-color palette. Verify colors are indexed correctly.
- [ ] 05 — Font Rasterization: Create the Core Text C bridge (font_shim.c/h) and glyph atlas (font.zig) for on-demand glyph rasterization.
- [ ] 06 — C API Bridge: Build stvt_api.zig, stvt_api.h, and main.zig to expose ~40 C-callable functions connecting Zig logic to the ObjC shell.
- [ ] 07 — Native Window: Create app.m with NSApplication, StvtWindow, NSVisualEffectView, and CAMetalLayer. Verify an empty translucent window appears.
- [ ] 08 — Metal Rendering: Implement shaders, pipeline states, triple-buffered vertices, and 3-pass rendering. Verify by drawing colored rectangles.
- [ ] 09 — Text Rendering: Wire the glyph atlas to Metal, emit glyph quads, and render the terminal grid. Verify by seeing actual terminal text on screen.
- [ ] 10 — Keyboard Input: Build input.zig for key mapping and implement keyDown/NSTextInputClient in app.m. Verify by typing commands and seeing output.
- [ ] 11 — Mouse, Selection & Scrollback: Add mouse tracking, text selection, and scroll viewport navigation. Verify by selecting text and scrolling history.
- [ ] 12 — Polish & App Bundle: Add paste support, window title, resize handling, cursor styles, Info.plist, icon, and `just bundle`. Verify the full .app bundle works.
