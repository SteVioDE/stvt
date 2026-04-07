// app.m — Minimal native macOS shell for stvt
// Handles: NSApplication, NSWindow, events, rendering via Core Graphics
// All terminal logic lives in Zig (via stvt_api.h)

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include "stvt_api.h"

// ─── Constants ───────────────────────────────────────────────────

static const uint16_t INITIAL_COLS = 80;
static const uint16_t INITIAL_ROWS = 24;

// ─── Forward declarations ────────────────────────────────────────

@class StvtView;

// ─── Application Delegate ────────────────────────────────────────

// Borderless windows need canBecomeKeyWindow to accept keyboard input
@interface StvtWindow : NSWindow
@end
@implementation StvtWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface StvtAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic) NSWindow *window;
@property (nonatomic) StvtView *termView;
@property (nonatomic) StvtContext ctx;
@property (nonatomic) NSTimer *fallbackTimer;
@property (nonatomic) dispatch_source_t ptySource;
@end

// ─── Terminal View ───────────────────────────────────────────────

@interface StvtView : NSView <NSTextInputClient>
@property (nonatomic) StvtContext ctx;
@property (nonatomic) CGFloat contentScale;
@end

@implementation StvtView {
    NSMutableAttributedString *_markedText;
    BOOL _handledByInsertText;
}

- (instancetype)initWithFrame:(NSRect)frame ctx:(StvtContext)ctx scale:(CGFloat)scale {
    self = [super initWithFrame:frame];
    if (self) {
        _ctx = ctx;
        _contentScale = scale;
        _markedText = [[NSMutableAttributedString alloc] init];
        self.wantsLayer = YES;
    }
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }
- (BOOL)isFlipped { return YES; }

// ─── Keyboard Input ──────────────────────────────────────────────

- (void)keyDown:(NSEvent *)event {
    uint16_t keycode = event.keyCode;
    uint32_t mods = (uint32_t)event.modifierFlags;

    // Get characters for the key encoder's utf8 field
    NSString *chars = event.charactersIgnoringModifiers;
    const char *utf8 = chars ? [chars UTF8String] : NULL;
    size_t utf8_len = utf8 ? strlen(utf8) : 0;

    // Feed to Zig key encoder — handles special keys, Ctrl combos, etc.
    int32_t result = stvt_feed_key(_ctx, keycode, mods, utf8, utf8_len);
    switch (result) {
        case 0: // written to PTY by encoder
            stvt_select_clear(_ctx); // clear selection on input
            return;
        case 1: // paste
            [self pasteFromClipboard];
            return;
        case 2: // scroll up
        case 3: // scroll down
            [self setNeedsDisplay:YES];
            return;
        case 4: // quit
            [NSApp terminate:nil];
            return;
        case 5: // copy
            [self copySelectionToClipboard];
            return;
        default:
            break;
    }

    // Encoder produced nothing — use macOS text input system for regular characters
    _handledByInsertText = NO;
    [self interpretKeyEvents:@[event]];
}

- (void)pasteFromClipboard {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *text = [pb stringForType:NSPasteboardTypeString];
    if (text) {
        const char *utf8 = [text UTF8String];
        stvt_paste(_ctx, utf8, strlen(utf8));
    }
}

// ─── NSTextInputClient ──────────────────────────────────────────

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    (void)replacementRange;
    _handledByInsertText = YES;
    NSString *str = [string isKindOfClass:[NSAttributedString class]]
        ? [(NSAttributedString *)string string] : (NSString *)string;
    const char *utf8 = [str UTF8String];
    if (utf8) {
        stvt_feed_text(_ctx, utf8, strlen(utf8));
    }
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    (void)selectedRange;
    (void)replacementRange;
    if ([string isKindOfClass:[NSAttributedString class]]) {
        _markedText = [string mutableCopy];
    } else {
        _markedText = [[NSMutableAttributedString alloc] initWithString:string];
    }
}

- (void)unmarkText {
    _markedText = [[NSMutableAttributedString alloc] init];
}

- (NSRange)selectedRange { return NSMakeRange(NSNotFound, 0); }
- (NSRange)markedRange {
    return _markedText.length > 0 ? NSMakeRange(0, _markedText.length) : NSMakeRange(NSNotFound, 0);
}
- (BOOL)hasMarkedText { return _markedText.length > 0; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    (void)range; (void)actualRange;
    return nil;
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    (void)range; (void)actualRange;
    return [self.window convertRectToScreen:[self convertRect:self.bounds toView:nil]];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point { (void)point; return NSNotFound; }
- (void)doCommandBySelector:(SEL)selector {
    // Swallow all commands — prevents system beep for unhandled keys.
    // Special keys (arrows, etc.) are handled by stvt_feed_key before we get here.
    (void)selector;
}

// ─── Mouse Input ────────────────────────────────────────────────

- (void)mouseDown:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    float x = (float)(loc.x * _contentScale);
    float y = (float)(loc.y * _contentScale);
    uint32_t mods = (uint32_t)event.modifierFlags;

    // Option+click forces selection even when program has mouse tracking
    BOOL forceSelect = (mods & (1 << 19)) != 0; // Option key

    if (stvt_is_mouse_tracking(_ctx) && !forceSelect) {
        stvt_feed_mouse(_ctx, 0, 1, mods, x, y);
    } else {
        // Start text selection
        stvt_select_clear(_ctx);
        stvt_select_start(_ctx, x, y);
    }
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    float x = (float)(loc.x * _contentScale);
    float y = (float)(loc.y * _contentScale);
    uint32_t mods = (uint32_t)event.modifierFlags;
    BOOL forceSelect = (mods & (1 << 19)) != 0;

    if (stvt_is_mouse_tracking(_ctx) && !forceSelect) {
        stvt_feed_mouse(_ctx, 1, 1, mods, x, y);
    }
    // Selection stays active until cleared by next click or Escape
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    float x = (float)(loc.x * _contentScale);
    float y = (float)(loc.y * _contentScale);
    uint32_t mods = (uint32_t)event.modifierFlags;
    BOOL forceSelect = (mods & (1 << 19)) != 0;

    if (stvt_is_mouse_tracking(_ctx) && !forceSelect) {
        stvt_feed_mouse(_ctx, 2, 1, mods, x, y);
    } else if (stvt_has_selection(_ctx)) {
        stvt_select_update(_ctx, x, y);
    }
    [self setNeedsDisplay:YES];
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    float x = (float)(loc.x * _contentScale);
    float y = (float)(loc.y * _contentScale);
    uint32_t mods = (uint32_t)event.modifierFlags;
    stvt_feed_mouse(_ctx, 0, 2, mods, x, y);
    [self setNeedsDisplay:YES];
}

- (void)rightMouseUp:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    float x = (float)(loc.x * _contentScale);
    float y = (float)(loc.y * _contentScale);
    uint32_t mods = (uint32_t)event.modifierFlags;
    stvt_feed_mouse(_ctx, 1, 2, mods, x, y);
    [self setNeedsDisplay:YES];
}

- (void)scrollWheel:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    float x = (float)(loc.x * _contentScale);
    float y = (float)(loc.y * _contentScale);
    uint32_t mods = (uint32_t)event.modifierFlags;
    CGFloat deltaY = event.scrollingDeltaY;

    if (stvt_is_mouse_tracking(_ctx)) {
        uint32_t button = (deltaY > 0) ? 4 : 5;
        int ticks = (int)fabs(deltaY);
        if (ticks < 1) ticks = 1;
        for (int i = 0; i < ticks; i++) {
            stvt_feed_mouse(_ctx, 0, button, mods, x, y);
        }
        [self setNeedsDisplay:YES];
    }
}

- (void)copySelectionToClipboard {
    uint8_t buf[65536];
    size_t len = stvt_copy_selection(_ctx, buf, sizeof(buf));
    if (len > 0) {
        NSString *text = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
        if (text) {
            NSPasteboard *pb = [NSPasteboard generalPasteboard];
            [pb clearContents];
            [pb setString:text forType:NSPasteboardTypeString];
        }
        stvt_select_clear(_ctx);
        [self setNeedsDisplay:YES];
    }
}

// ─── Drawing ─────────────────────────────────────────────────────

- (void)drawRect:(NSRect)dirtyRect {
    if (!_ctx) return;

    CGContextRef cgctx = [[NSGraphicsContext currentContext] CGContext];
    if (!cgctx) return;

    uint16_t cols = stvt_get_cols(_ctx);
    uint16_t rows = stvt_get_rows(_ctx);
    uint32_t cw = stvt_get_cell_width(_ctx);
    uint32_t ch = stvt_get_cell_height(_ctx);
    uint32_t ascent = stvt_get_ascent(_ctx);
    CGFloat scale = _contentScale;

    // Cell dimensions in points
    CGFloat cw_pt = (CGFloat)cw / scale;
    CGFloat ch_pt = (CGFloat)ch / scale;

    // Background
    uint8_t bg_r = stvt_get_default_bg_r(_ctx);
    uint8_t bg_g = stvt_get_default_bg_g(_ctx);
    uint8_t bg_b = stvt_get_default_bg_b(_ctx);
    uint8_t bg_a = stvt_get_bg_alpha(_ctx);
    CGContextSetRGBFillColor(cgctx, bg_r/255.0, bg_g/255.0, bg_b/255.0, bg_a/255.0);
    CGContextFillRect(cgctx, dirtyRect);


    // Get render state for iteration
    GhosttyRenderState rs = stvt_get_render_state(_ctx);
    if (!rs) return;

    // Get colors
    GhosttyRenderStateColors rsColors;
    rsColors.size = sizeof(GhosttyRenderStateColors);
    ghostty_render_state_colors_get(rs, &rsColors);

    // Default fg color
    uint8_t def_fg_r = rsColors.foreground.r;
    uint8_t def_fg_g = rsColors.foreground.g;
    uint8_t def_fg_b = rsColors.foreground.b;

    // Create row iterator
    GhosttyRenderStateRowIterator rowIt = NULL;
    ghostty_render_state_row_iterator_new(NULL, &rowIt);
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIt);

    // Create row cells (reusable)
    GhosttyRenderStateRowCells rowCells = NULL;
    ghostty_render_state_row_cells_new(NULL, &rowCells);

    // Atlas info for glyph rendering
    const uint8_t *atlas_pixels = stvt_get_atlas_pixels(_ctx);
    uint32_t atlas_size = stvt_get_atlas_size(_ctx);

    // Compute row range that intersects dirtyRect
    uint16_t dirty_row_min = (uint16_t)(dirtyRect.origin.y / ch_pt);
    uint16_t dirty_row_max = (uint16_t)((dirtyRect.origin.y + dirtyRect.size.height) / ch_pt);
    if (dirty_row_max >= rows) dirty_row_max = rows - 1;

    // Iterate rows
    uint16_t row_idx = 0;
    while (ghostty_render_state_row_iterator_next(rowIt)) {
        CGFloat y = row_idx * ch_pt;

        // Skip rows outside the dirty rect
        if (row_idx < dirty_row_min || row_idx > dirty_row_max) {
            row_idx++;
            continue;
        }

        // Get cells for this row
        ghostty_render_state_row_get(rowIt, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells);

        uint16_t col_idx = 0;
        while (ghostty_render_state_row_cells_next(rowCells)) {
            CGFloat x = col_idx * cw_pt;

            // Get cell bg color
            GhosttyColorRgb cellBg;
            GhosttyResult bgResult = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &cellBg);
            if (bgResult == GHOSTTY_SUCCESS) {
                CGContextSetRGBFillColor(cgctx, cellBg.r/255.0, cellBg.g/255.0, cellBg.b/255.0, 1.0);
                CGContextFillRect(cgctx, CGRectMake(x, y, cw_pt, ch_pt));
            }

            // Selection highlight
            if (stvt_is_cell_selected(_ctx, col_idx, row_idx)) {
                CGContextSetRGBFillColor(cgctx, 1.0, 1.0, 1.0, 0.3);
                CGContextFillRect(cgctx, CGRectMake(x, y, cw_pt, ch_pt));
            }

            // Check if cell has text via grapheme length
            uint32_t grapheme_len = 0;
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &grapheme_len);
            if (grapheme_len == 0) { col_idx++; continue; }

            // Get codepoint(s) via grapheme buffer
            uint32_t codepoints[16];
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, codepoints);
            uint32_t cp = codepoints[0];
            if (cp == 0) { col_idx++; continue; }

            // Get style for bold/italic
            GhosttyStyle style;
            style.size = sizeof(GhosttyStyle);
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);

            uint8_t fontStyle = 0;
            if (style.bold && style.italic) fontStyle = 3;
            else if (style.bold) fontStyle = 1;
            else if (style.italic) fontStyle = 2;

            // Get fg color
            GhosttyColorRgb cellFg;
            GhosttyResult fgResult = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &cellFg);
            uint8_t fg_r = (fgResult == GHOSTTY_SUCCESS) ? cellFg.r : def_fg_r;
            uint8_t fg_g = (fgResult == GHOSTTY_SUCCESS) ? cellFg.g : def_fg_g;
            uint8_t fg_b = (fgResult == GHOSTTY_SUCCESS) ? cellFg.b : def_fg_b;

            // Handle inverse
            if (style.inverse) {
                fg_r = (bgResult == GHOSTTY_SUCCESS) ? cellBg.r : bg_r;
                fg_g = (bgResult == GHOSTTY_SUCCESS) ? cellBg.g : bg_g;
                fg_b = (bgResult == GHOSTTY_SUCCESS) ? cellBg.b : bg_b;
            }

            // Rasterize glyph
            StvtGlyphInfo glyph = stvt_get_glyph(_ctx, cp, fontStyle);
            if (!glyph.found || glyph.width == 0 || glyph.height == 0) { col_idx++; continue; }

            // Create CGImage from atlas region for this glyph
            CGFloat gx = x + (CGFloat)glyph.bearing_x / scale;
            CGFloat gy = y + (CGFloat)((int32_t)ascent - glyph.bearing_y) / scale;
            CGFloat gw = (CGFloat)glyph.width / scale;
            CGFloat gh = (CGFloat)glyph.height / scale;

            // Build an RGBA image where RGB = fg color, A = from atlas
            // Use premultiplied alpha for correct compositing
            uint32_t glyph_pixel_count = glyph.width * glyph.height;
            uint8_t *rgba = (uint8_t *)malloc(glyph_pixel_count * 4);
            if (rgba) {
                uint32_t atlas_stride = atlas_size * 4;
                for (uint32_t py = 0; py < glyph.height; py++) {
                    for (uint32_t px = 0; px < glyph.width; px++) {
                        uint32_t src_offset = (glyph.atlas_y + py) * atlas_stride + (glyph.atlas_x + px) * 4;
                        uint8_t alpha = atlas_pixels[src_offset + 3];
                        uint32_t dst_idx = (py * glyph.width + px) * 4;
                        // Premultiply: component = component * alpha / 255
                        rgba[dst_idx + 0] = (uint8_t)((uint16_t)fg_r * alpha / 255);
                        rgba[dst_idx + 1] = (uint8_t)((uint16_t)fg_g * alpha / 255);
                        rgba[dst_idx + 2] = (uint8_t)((uint16_t)fg_b * alpha / 255);
                        rgba[dst_idx + 3] = alpha;
                    }
                }

                CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                CGContextRef bmp = CGBitmapContextCreate(rgba, glyph.width, glyph.height, 8,
                    glyph.width * 4, cs, kCGImageAlphaPremultipliedLast);
                if (bmp) {
                    CGImageRef img = CGBitmapContextCreateImage(bmp);
                    if (img) {
                        // In a flipped NSView, CGContextDrawImage draws images upside-down.
                        // Save state, flip locally, draw, restore.
                        CGContextSaveGState(cgctx);
                        CGContextTranslateCTM(cgctx, gx, gy + gh);
                        CGContextScaleCTM(cgctx, 1.0, -1.0);
                        CGContextDrawImage(cgctx, CGRectMake(0, 0, gw, gh), img);
                        CGContextRestoreGState(cgctx);

                        CGImageRelease(img);
                    }
                    CGContextRelease(bmp);
                }
                CGColorSpaceRelease(cs);
                free(rgba);
            }

            // Decorations
            if (style.underline != 0) {
                CGFloat ul_y = y + (CGFloat)(ascent + 1) / scale;
                CGContextSetRGBFillColor(cgctx, fg_r/255.0, fg_g/255.0, fg_b/255.0, 1.0);
                CGContextFillRect(cgctx, CGRectMake(x, ul_y, cw_pt, 1.0/scale));
            }
            if (style.strikethrough) {
                CGFloat st_y = y + (CGFloat)(ascent / 2) / scale;
                CGContextSetRGBFillColor(cgctx, fg_r/255.0, fg_g/255.0, fg_b/255.0, 1.0);
                CGContextFillRect(cgctx, CGRectMake(x, st_y, cw_pt, 1.0/scale));
            }

            col_idx++;
        }

        // Clear row dirty
        bool clean = false;
        ghostty_render_state_row_set(rowIt, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean);

        row_idx++;
    }

    // Draw cursor
    bool cursorVisible = false;
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &cursorVisible);
    bool cursorModeVisible = true;
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursorModeVisible);

    if (cursorVisible && cursorModeVisible) {
        uint16_t cx = 0, cy = 0;
        ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx);
        ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy);

        GhosttyRenderStateCursorVisualStyle curStyle = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
        ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &curStyle);

        CGFloat cur_x = cx * cw_pt;
        CGFloat cur_y = cy * ch_pt;
        uint8_t fg_r = stvt_get_default_fg_r(_ctx);
        uint8_t fg_g = stvt_get_default_fg_g(_ctx);
        uint8_t fg_b = stvt_get_default_fg_b(_ctx);

        switch (curStyle) {
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
                CGContextSetRGBFillColor(cgctx, fg_r/255.0, fg_g/255.0, fg_b/255.0, 0.5);
                CGContextFillRect(cgctx, CGRectMake(cur_x, cur_y, cw_pt, ch_pt));
                break;
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
                CGContextSetRGBFillColor(cgctx, fg_r/255.0, fg_g/255.0, fg_b/255.0, 1.0);
                CGContextFillRect(cgctx, CGRectMake(cur_x, cur_y, 2.0/scale, ch_pt));
                break;
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
                CGContextSetRGBFillColor(cgctx, fg_r/255.0, fg_g/255.0, fg_b/255.0, 1.0);
                CGContextFillRect(cgctx, CGRectMake(cur_x, cur_y + ch_pt - 2.0/scale, cw_pt, 2.0/scale));
                break;
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
                CGContextSetRGBStrokeColor(cgctx, fg_r/255.0, fg_g/255.0, fg_b/255.0, 1.0);
                CGContextSetLineWidth(cgctx, 1.0/scale);
                CGContextStrokeRect(cgctx, CGRectMake(cur_x, cur_y, cw_pt, ch_pt));
                break;
        }
    }

    // Cleanup
    ghostty_render_state_row_cells_free(rowCells);
    ghostty_render_state_row_iterator_free(rowIt);

    // Clear global dirty
    GhosttyRenderStateDirty cleanState = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    ghostty_render_state_set(rs, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &cleanState);
}

@end

// ─── App Delegate ────────────────────────────────────────────────

@implementation StvtAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    // Get content scale from main screen
    CGFloat scale = [NSScreen mainScreen].backingScaleFactor;

    // Init terminal context
    _ctx = stvt_init(INITIAL_COLS, INITIAL_ROWS, (float)scale);
    if (!_ctx) {
        NSLog(@"stvt_init failed");
        [NSApp terminate:nil];
        return;
    }

    uint32_t cw = stvt_get_cell_width(_ctx);
    uint32_t ch = stvt_get_cell_height(_ctx);

    // Window size in points
    CGFloat win_w = (CGFloat)(INITIAL_COLS * cw) / scale;
    CGFloat win_h = (CGFloat)(INITIAL_ROWS * ch) / scale;

    NSRect frame = NSMakeRect(200, 200, win_w, win_h);

    _window = [[StvtWindow alloc]
        initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                   NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered
        defer:NO];

    _window.opaque = NO;
    _window.backgroundColor = [NSColor clearColor];
    _window.hasShadow = YES;
    _window.title = @"stvt";
    // Hide title bar visually but keep standard window behavior for tiling WMs
    _window.titlebarAppearsTransparent = YES;
    _window.titleVisibility = NSWindowTitleHidden;
    [_window setStyleMask:_window.styleMask | NSWindowStyleMaskFullSizeContentView];
    // Hide traffic light buttons
    [[_window standardWindowButton:NSWindowCloseButton] setHidden:YES];
    [[_window standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
    [[_window standardWindowButton:NSWindowZoomButton] setHidden:YES];

    NSRect contentRect = NSMakeRect(0, 0, win_w, win_h);

    // Container view holds blur + terminal
    NSView *container = [[NSView alloc] initWithFrame:contentRect];

    // Background blur layer (behind terminal content)
    NSVisualEffectView *blur = [[NSVisualEffectView alloc] initWithFrame:contentRect];
    blur.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    blur.material = NSVisualEffectMaterialHUDWindow;
    blur.state = NSVisualEffectStateActive;
    blur.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:blur];

    // Terminal view (on top of blur, draws with transparent background)
    _termView = [[StvtView alloc] initWithFrame:contentRect ctx:_ctx scale:scale];
    _termView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:_termView];

    _window.contentView = container;

    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_termView];
    [NSApp activateIgnoringOtherApps:YES];

    // I/O-driven polling: dispatch_source on PTY fd wakes us when data arrives
    int pty_fd = stvt_get_pty_fd(_ctx);
    _ptySource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, pty_fd, 0, dispatch_get_main_queue());
    __weak StvtAppDelegate *weakSelf = self;
    dispatch_source_set_event_handler(_ptySource, ^{
        StvtAppDelegate *s = weakSelf;
        if (!s || !s->_ctx) return;
        [s doPoll];
    });
    dispatch_resume(_ptySource);

    // Fallback timer: 1-second interval for cursor blink + child exit detection
    _fallbackTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                     target:self
                                                   selector:@selector(fallbackTick:)
                                                   userInfo:nil
                                                    repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_fallbackTimer forMode:NSEventTrackingRunLoopMode];

    // Force initial render after a short delay (shell needs time to emit prompt)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        StvtAppDelegate *s = weakSelf;
        if (!s || !s->_ctx) return;
        [s doPoll];
    });

    // Listen for window resize
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowDidResize:)
                                                 name:NSWindowDidResizeNotification
                                               object:_window];
}

- (void)doPoll {
    if (!_ctx) return;

    int32_t dirty = stvt_poll(_ctx);
    if (dirty < 0) {
        [NSApp terminate:nil];
        return;
    }

    if (dirty == 2) {
        // Full dirty (scroll, resize) — redraw everything
        [_termView setNeedsDisplay:YES];
    } else if (dirty == 1) {
        // Partial dirty — only invalidate dirty row regions
        uint16_t min_row = 0, max_row = 0;
        if (stvt_get_dirty_rows(_ctx, &min_row, &max_row)) {
            CGFloat scale = _termView.contentScale;
            uint32_t ch = stvt_get_cell_height(_ctx);
            CGFloat ch_pt = (CGFloat)ch / scale;
            CGFloat y = min_row * ch_pt;
            CGFloat h = (max_row - min_row + 1) * ch_pt;
            NSRect rowRect = NSMakeRect(0, y, _termView.bounds.size.width, h);
            [_termView setNeedsDisplayInRect:rowRect];
        }
    }

    // Update window title if changed
    if (stvt_title_changed(_ctx)) {
        size_t title_len = 0;
        const uint8_t *title_ptr = stvt_get_title(_ctx, &title_len);
        if (title_ptr && title_len > 0) {
            NSString *title = [[NSString alloc] initWithBytes:title_ptr length:title_len encoding:NSUTF8StringEncoding];
            if (title) _window.title = title;
        } else {
            _window.title = @"stvt";
        }
    }
}

- (void)fallbackTick:(NSTimer *)timer {
    (void)timer;
    if (!_ctx) return;

    // Check if shell is still alive
    if (!stvt_is_alive(_ctx)) {
        [NSApp terminate:nil];
        return;
    }

    // Poll for any data that dispatch_source might have missed
    [self doPoll];
}

- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    if (!_ctx) return;

    CGFloat scale = _termView.contentScale;
    uint32_t cw = stvt_get_cell_width(_ctx);
    uint32_t ch = stvt_get_cell_height(_ctx);

    NSSize size = _termView.bounds.size;
    uint32_t pw = (uint32_t)(size.width * scale);
    uint32_t ph = (uint32_t)(size.height * scale);

    uint16_t new_cols = (uint16_t)(pw / cw);
    uint16_t new_rows = (uint16_t)(ph / ch);
    if (new_cols < 1) new_cols = 1;
    if (new_rows < 1) new_rows = 1;

    stvt_resize(_ctx, new_cols, new_rows);
    [_termView setNeedsDisplay:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    if (_ptySource) {
        dispatch_source_cancel(_ptySource);
        _ptySource = nil;
    }
    [_fallbackTimer invalidate];
    stvt_destroy(_ctx);
    _ctx = NULL;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

@end

// ─── Main ────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        StvtAppDelegate *delegate = [[StvtAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
