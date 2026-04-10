# Tutorial Plan

## Meta
- project: stvt (SteVio Terminal)
- languages: [zig, c, objc]
- reference_branch: main
- total_chapters: 11
- current_chapter: 0
- created: 2026-04-11
- init_command: zig init

## Chapter 01: Project Skeleton & Build System
- status: active
- languages: [zig]
- learning_goals:
  - Initialize a Zig project and understand the package manifest
  - Configure build.zig for a multi-language build (Zig static lib + ObjC executable)
  - Link macOS frameworks (Metal, AppKit, CoreText, etc.) from the Zig build system
- reference_scope: build.zig: [build]
- reference_scope: src/main.zig
- reference_scope: build.zig.zon
- acquire_scope: lib/ghostty-vt.xcframework/
- acquire_scope: devbox.json
- acquire_scope: justfile

## Chapter 02: PTY & Shell Spawn
- status: planned
- languages: [zig]
- learning_goals:
  - Understand pseudo-terminals and POSIX process forking
  - Implement non-blocking PTY I/O with proper environment setup
  - Bridge Zig to C system calls via @cImport
- reference_scope: src/ghostty.zig: [ghostty.c]
- reference_scope: src/pty.zig: [pty.posix, pty.c, DEFAULT_TERM, DEFAULT_COLORTERM, FALLBACK_SHELL, Pty, childExec]
- reference_scope: src/terminal.zig: [terminal.posix, terminal.log]
- reference_scope: src/stvt_api.zig: [log]
- depends_on: ch01: [build]

## Chapter 03: Color Palette
- status: planned
- languages: [zig]
- learning_goals:
  - Design an xterm 256-color palette with ANSI, color cube, and grayscale ramp regions
  - Use Zig compile-time evaluation to generate static data
- reference_scope: src/color.zig: [RGB, default_fg, default_bg, BG_ALPHA, palette_256, CUBE_LEVELS, CUBE_SIZE, CUBE_PLANE, CUBE_BASE, CUBE_STEP, GRAY_RAMP_SIZE, GRAY_BASE, GRAY_STEP, init_palette]
- depends_on: ch01: [build]

## Chapter 04: Font Rasterization (C Shim)
- status: planned
- languages: [c]
- learning_goals:
  - Write a C bridge to macOS Core Text for font loading and glyph rasterization
  - Handle Unicode supplementary plane characters via UTF-16 surrogate pairs
  - Implement font fallback for missing glyphs
- reference_scope: src/font_shim.h: [GlyphBitmap, FontMetrics, src.font_shim.h.font_init, src.font_shim.h.font_init_bold, src.font_shim.h.font_init_italic, src.font_shim.h.font_init_bold_italic, src.font_shim.h.font_deinit, src.font_shim.h.font_get_metrics, src.font_shim.h.font_rasterize]
- reference_scope: src/font_shim.c: [font_init_with_traits, font_shim.font_init, font_shim.font_init_bold, font_shim.font_init_italic, font_shim.font_init_bold_italic, font_shim.font_deinit, font_shim.font_get_metrics, font_shim.font_rasterize]
- depends_on: ch01: [build]

## Chapter 05: Glyph Atlas & Texture Packing
- status: planned
- languages: [zig]
- learning_goals:
  - Implement a glyph cache with on-demand rasterization
  - Build a row-based bin-packing algorithm for a growable BGRA texture atlas
  - Track dirty regions for efficient GPU texture uploads
- reference_scope: src/font.zig: [font.log, font.shim, Style, GlyphKey, GlyphInfo, CellMetrics, INITIAL_ATLAS_SIZE, MAX_ATLAS_SIZE, ATLAS_ROW_GAP, ATLAS_COL_GAP, FontAtlas]
- depends_on: ch01: [build]
- depends_on: ch04: [GlyphBitmap, FontMetrics, font_init_with_traits]

## Chapter 06: Terminal State & VT Parsing
- status: planned
- languages: [zig]
- learning_goals:
  - Wrap the ghostty VT parser C API for terminal state management
  - Implement grid iteration (rows and cells) for rendering
  - Set up PTY write and title-change callbacks between C and Zig
- reference_scope: src/terminal.zig: [TerminalState, CursorInfo, write_pty_fd, title_state, mouse_cell_width, mouse_cell_height, setMouseCellSize, setTitleStatePtr, writePtyCallback, titleChangedCallback]
- depends_on: ch01: [build]
- depends_on: ch02: [ghostty.c, Pty]

## Chapter 07: Keyboard & Mouse Input
- status: planned
- languages: [zig]
- learning_goals:
  - Map macOS virtual keycodes to terminal key events
  - Translate NSEvent modifier flags to terminal modifier bitmasks
  - Intercept app-level keyboard shortcuts (Cmd+Q, Cmd+V, scroll commands)
- reference_scope: src/input.zig: [Action, macVirtualKeyToGhosttyKey, nsModsToGhosttyMods, checkAppCommand]
- depends_on: ch01: [build]
- depends_on: ch02: [ghostty.c]

## Chapter 08: C API Bridge — Core
- status: planned
- languages: [zig]
- learning_goals:
  - Design an opaque context handle that hides Zig internals from C callers
  - Export lifecycle functions (init, destroy, poll) with C calling convention
  - Expose render state, font atlas, color, and grid accessors through the C ABI
- reference_scope: src/stvt_api.h: [src.stvt_api.h.StvtContext, src.stvt_api.h.StvtAtlasDirtyRegion, src.stvt_api.h.StvtGlyphInfo]
- reference_scope: src/stvt_api.zig: [stvt_api.shim, FONT_NAME, FONT_SIZE, PTY_READ_BUF_SIZE, stvt_api.StvtContext, stvt_api.StvtAtlasDirtyRegion, stvt_api.StvtGlyphInfo, stvt_init, stvt_destroy, stvt_poll, stvt_is_alive, stvt_resize, stvt_update_render_state, stvt_get_render_state, stvt_get_terminal, stvt_get_atlas_pixels, stvt_get_atlas_size, stvt_is_atlas_dirty, stvt_clear_atlas_dirty, stvt_get_atlas_dirty_region, stvt_get_cell_width, stvt_get_cell_height, stvt_get_ascent, stvt_get_glyph, stvt_get_default_bg_r, stvt_get_default_bg_g, stvt_get_default_bg_b, stvt_get_bg_alpha, stvt_get_default_fg_r, stvt_get_default_fg_g, stvt_get_default_fg_b, stvt_get_cols, stvt_get_rows, stvt_clear_dirty, stvt_get_dirty_rows, stvt_get_title, stvt_title_changed, stvt_get_pty_fd]
- depends_on: ch02: [Pty]
- depends_on: ch03: [RGB, default_fg, default_bg, BG_ALPHA, palette_256]
- depends_on: ch05: [FontAtlas]
- depends_on: ch06: [TerminalState]

## Chapter 09: C API Bridge — Input & Selection
- status: planned
- languages: [zig]
- learning_goals:
  - Export keyboard, mouse, and paste input functions through the C ABI
  - Implement pixel-to-grid coordinate conversion for text selection
  - Handle terminal mode queries (mouse tracking, alternate screen, DECCKM)
- reference_scope: src/stvt_api.zig: [stvt_feed_key, vt220FKeySequence, stvt_feed_text, stvt_paste, stvt_scroll_viewport, stvt_feed_mouse, stvt_is_mouse_tracking, stvt_is_decckm, stvt_is_alt_screen, pixelToGrid, resolveGridRef, stvt_select_start, stvt_select_update, stvt_select_clear, stvt_is_cell_selected, stvt_has_selection, stvt_copy_selection]
- depends_on: ch07: [Action, macVirtualKeyToGhosttyKey, nsModsToGhosttyMods, checkAppCommand]
- depends_on: ch08: [stvt_api.StvtContext]

## Chapter 10: Metal Rendering Pipeline
- status: planned
- languages: [objc]
- learning_goals:
  - Set up a Metal device, command queue, and two render pipelines (color + textured)
  - Write vertex and fragment shaders for background fills and glyph rendering
  - Implement 3-pass rendering (backgrounds, glyphs, decorations) with triple-buffered vertices
- reference_scope: src/app.m: [vertex_main, fragment_color, fragment_glyph, StvtView, StvtView.initWithFrame, StvtView.makeBackingLayer, StvtView.setupMetal, StvtView.acceptsFirstResponder, StvtView.canBecomeKeyView, StvtView.isFlipped, StvtView.emitQuad, StvtView.updateAtlasTexture, StvtView.renderMetal]
- depends_on: ch08: [stvt_init, stvt_get_render_state, stvt_get_glyph, stvt_get_atlas_pixels, stvt_update_render_state, src.stvt_api.h.StvtContext, src.stvt_api.h.StvtGlyphInfo, src.stvt_api.h.StvtAtlasDirtyRegion]

## Chapter 11: Application Shell & Event Loop
- status: planned
- languages: [objc]
- learning_goals:
  - Build an NSApplication with dispatch_source-based I/O polling for near-zero idle CPU
  - Handle keyboard input via the NSTextInputClient protocol
  - Implement mouse tracking with text selection, scroll wheel handling, and window resize
- reference_scope: src/app.m: [StvtWindow, StvtWindow.canBecomeKeyWindow, StvtWindow.canBecomeMainWindow, StvtAppDelegate, StvtAppDelegate.applicationDidFinishLaunching, StvtAppDelegate.doPoll, StvtAppDelegate.fallbackTick, StvtAppDelegate.windowDidResize, StvtAppDelegate.applicationWillTerminate, StvtAppDelegate.applicationShouldTerminateAfterLastWindowClosed, main, StvtView.keyDown, StvtView.pasteFromClipboard, StvtView.insertText, StvtView.setMarkedText, StvtView.unmarkText, StvtView.selectedRange, StvtView.markedRange, StvtView.hasMarkedText, StvtView.attributedSubstringForProposedRange, StvtView.validAttributesForMarkedText, StvtView.firstRectForCharacterRange, StvtView.characterIndexForPoint, StvtView.doCommandBySelector, StvtView.mouseDown, StvtView.mouseUp, StvtView.mouseDragged, StvtView.rightMouseDown, StvtView.rightMouseUp, StvtView.scrollWheel, StvtView.copySelectionToClipboard]
- acquire_scope: macos/Info.plist
- acquire_scope: macos/stvt.icns
- depends_on: ch08: [stvt_poll, stvt_resize, stvt_destroy]
- depends_on: ch09: [stvt_feed_key, stvt_paste, stvt_feed_text]
- depends_on: ch09: [stvt_feed_mouse, stvt_scroll_viewport, stvt_is_mouse_tracking, stvt_is_alt_screen, stvt_is_decckm, stvt_select_start, stvt_select_update, stvt_select_clear, stvt_copy_selection, stvt_has_selection, stvt_is_cell_selected]
- depends_on: ch10: [StvtView, StvtView.renderMetal]
