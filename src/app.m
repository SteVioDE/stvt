// app.m — Minimal native macOS shell for stvt
// Handles: NSApplication, NSWindow, events, rendering via Core Graphics
// All terminal logic lives in Zig (via stvt_api.h)

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "stvt_api.h"

// ─── Constants ───────────────────────────────────────────────────

static const uint16_t INITIAL_COLS = 80;
static const uint16_t INITIAL_ROWS = 24;

// ─── Metal Shader Source ────────────────────────────────────────

static NSString *const kShaderSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 position;
    float2 texCoord;
    float4 color;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

struct Uniforms {
    float2 viewportSize;
};

vertex VertexOut vertex_main(uint vid [[vertex_id]],
                             constant Vertex *vertices [[buffer(0)]],
                             constant Uniforms &uniforms [[buffer(1)]]) {
    VertexOut out;
    float2 pos = vertices[vid].position;
    out.position = float4(pos.x / uniforms.viewportSize.x * 2.0 - 1.0,
                          1.0 - pos.y / uniforms.viewportSize.y * 2.0,
                          0.0, 1.0);
    out.texCoord = vertices[vid].texCoord;
    out.color = vertices[vid].color;
    return out;
}

fragment float4 fragment_color(VertexOut in [[stage_in]]) {
    return in.color;
}

fragment float4 fragment_glyph(VertexOut in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(filter::nearest);
    float alpha = atlas.sample(s, in.texCoord).a;
    return float4(in.color.rgb * alpha, in.color.a * alpha);
}
)MSL";

// CPU-side vertex layout (must match shader)
typedef struct {
    float position[2];
    float texCoord[2];
    float color[4];
} MetalVertex;

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
- (void)renderMetal;
@end

// Max quads per pass: 300 cols * 80 rows = 24000 (generous)
static const NSUInteger kMaxQuads = 24000;
static const NSUInteger kVerticesPerQuad = 4;
static const NSUInteger kIndicesPerQuad = 6;
static const NSUInteger kFramesInFlight = 3;

@implementation StvtView {
    NSMutableAttributedString *_markedText;
    BOOL _handledByInsertText;

    // Metal state
    id<MTLDevice>              _device;
    id<MTLCommandQueue>        _commandQueue;
    id<MTLRenderPipelineState> _colorPipeline;
    id<MTLRenderPipelineState> _glyphPipeline;
    id<MTLTexture>             _atlasTexture;
    uint32_t                   _atlasTextureSize;
    CAMetalLayer              *_metalLayer;

    // Triple-buffered vertex storage
    id<MTLBuffer>              _vertexBuffers[kFramesInFlight];
    id<MTLBuffer>              _indexBuffer;
    dispatch_semaphore_t       _frameSemaphore;
    NSUInteger                 _frameIndex;

    // Uniform buffer
    id<MTLBuffer>              _uniformBuffer;

    // Scroll accumulator for trackpad pixel-to-line conversion
    CGFloat                    _scrollAccumulatorY;
}

- (instancetype)initWithFrame:(NSRect)frame ctx:(StvtContext)ctx scale:(CGFloat)scale {
    self = [super initWithFrame:frame];
    if (self) {
        _ctx = ctx;
        _contentScale = scale;
        _markedText = [[NSMutableAttributedString alloc] init];
        [self setupMetal];
    }
    return self;
}

- (CALayer *)makeBackingLayer {
    return _metalLayer;
}

- (void)setupMetal {
    _device = MTLCreateSystemDefaultDevice();
    _commandQueue = [_device newCommandQueue];

    // Compile shader from embedded source
    NSError *err = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:kShaderSource options:nil error:&err];
    if (!library) {
        NSLog(@"Metal shader compile failed: %@", err);
        return;
    }

    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"vertex_main"];
    id<MTLFunction> colorFragFunc = [library newFunctionWithName:@"fragment_color"];
    id<MTLFunction> glyphFragFunc = [library newFunctionWithName:@"fragment_glyph"];

    // Color pipeline (backgrounds, decorations, cursor)
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vertexFunc;
    desc.fragmentFunction = colorFragFunc;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    _colorPipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!_colorPipeline) NSLog(@"Color pipeline failed: %@", err);

    // Glyph pipeline (textured quads)
    desc.fragmentFunction = glyphFragFunc;
    _glyphPipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
    if (!_glyphPipeline) NSLog(@"Glyph pipeline failed: %@", err);

    // CAMetalLayer
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.opaque = NO;
    _metalLayer.contentsScale = _contentScale;
    CGSize drawSize = CGSizeMake(self.bounds.size.width * _contentScale,
                                  self.bounds.size.height * _contentScale);
    _metalLayer.drawableSize = drawSize;
    self.wantsLayer = YES;
    self.layer = _metalLayer;

    // Vertex buffers (triple-buffered, shared memory)
    NSUInteger vertexBufSize = kMaxQuads * kVerticesPerQuad * sizeof(MetalVertex);
    for (NSUInteger i = 0; i < kFramesInFlight; i++) {
        _vertexBuffers[i] = [_device newBufferWithLength:vertexBufSize
                                                 options:MTLResourceStorageModeShared];
    }

    // Index buffer (pre-computed quad pattern)
    NSUInteger indexBufSize = kMaxQuads * kIndicesPerQuad * sizeof(uint32_t);
    _indexBuffer = [_device newBufferWithLength:indexBufSize options:MTLResourceStorageModeShared];
    uint32_t *indices = (uint32_t *)[_indexBuffer contents];
    for (uint32_t i = 0; i < kMaxQuads; i++) {
        uint32_t base = i * 4;
        indices[i * 6 + 0] = base + 0;
        indices[i * 6 + 1] = base + 1;
        indices[i * 6 + 2] = base + 2;
        indices[i * 6 + 3] = base + 2;
        indices[i * 6 + 4] = base + 1;
        indices[i * 6 + 5] = base + 3;
    }

    // Uniform buffer
    _uniformBuffer = [_device newBufferWithLength:sizeof(float) * 2
                                          options:MTLResourceStorageModeShared];

    // Frame semaphore
    _frameSemaphore = dispatch_semaphore_create(kFramesInFlight);
    _frameIndex = 0;
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
            [self renderMetal];
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
    } else {
        // No text on clipboard (e.g. image-only) — send empty paste
        // so bracketed-paste-aware apps can detect the event and check clipboard
        stvt_paste(_ctx, NULL, 0);
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
    [self renderMetal];
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
    [self renderMetal];
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
    [self renderMetal];
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    float x = (float)(loc.x * _contentScale);
    float y = (float)(loc.y * _contentScale);
    uint32_t mods = (uint32_t)event.modifierFlags;
    stvt_feed_mouse(_ctx, 0, 2, mods, x, y);
    [self renderMetal];
}

- (void)rightMouseUp:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    float x = (float)(loc.x * _contentScale);
    float y = (float)(loc.y * _contentScale);
    uint32_t mods = (uint32_t)event.modifierFlags;
    stvt_feed_mouse(_ctx, 1, 2, mods, x, y);
    [self renderMetal];
}

- (void)scrollWheel:(NSEvent *)event {
    // Discard momentum (inertial) scroll events from trackpad
    if (event.momentumPhase != NSEventPhaseNone) return;

    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    float x = (float)(loc.x * _contentScale);
    float y = (float)(loc.y * _contentScale);
    uint32_t mods = (uint32_t)event.modifierFlags;
    CGFloat deltaY = event.scrollingDeltaY;

    // Convert delta to line-sized ticks
    int ticks;
    BOOL scrollUp = (deltaY > 0);
    if (event.hasPreciseScrollingDeltas) {
        // Trackpad: accumulate pixel deltas, emit ticks per cell height
        uint32_t ch = stvt_get_cell_height(_ctx);
        if (ch == 0) ch = 16;
        _scrollAccumulatorY += deltaY;
        ticks = (int)(_scrollAccumulatorY / (CGFloat)ch);
        if (ticks == 0) return;
        _scrollAccumulatorY -= (CGFloat)ticks * (CGFloat)ch;
        scrollUp = (ticks > 0);
        ticks = abs(ticks);
    } else {
        // Mouse wheel: delta is already in lines
        ticks = (int)fabs(deltaY);
        if (ticks < 1) ticks = 1;
    }

    if (stvt_is_mouse_tracking(_ctx)) {
        // Program has mouse tracking — forward as mouse button 4 (up) / 5 (down)
        uint32_t button = scrollUp ? 4 : 5;
        for (int i = 0; i < ticks; i++) {
            stvt_feed_mouse(_ctx, 0, button, mods, x, y);  // press
            stvt_feed_mouse(_ctx, 1, button, mods, x, y);  // release
        }
    } else if (stvt_is_alt_screen(_ctx)) {
        // Alt screen without mouse tracking — send arrow keys (respect DECCKM)
        const char *seq;
        if (stvt_is_decckm(_ctx)) {
            seq = scrollUp ? "\x1bOA" : "\x1bOB";
        } else {
            seq = scrollUp ? "\x1b[A" : "\x1b[B";
        }
        for (int i = 0; i < ticks; i++) {
            stvt_feed_text(_ctx, seq, 3);
        }
    } else {
        // Normal screen — scroll terminal viewport
        int32_t rows = scrollUp ? -ticks : ticks;
        stvt_scroll_viewport(_ctx, rows);
    }
    [self renderMetal];
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
        [self renderMetal];
    }
}

// ─── Metal Rendering ────────────────────────────────────────────

// Helper: emit a colored quad into vertex buffer
static inline NSUInteger emitQuad(MetalVertex *verts, NSUInteger quadIdx,
                                   float x, float y, float w, float h,
                                   float u0, float v0, float u1, float v1,
                                   float r, float g, float b, float a) {
    if (quadIdx >= kMaxQuads) return quadIdx;
    NSUInteger base = quadIdx * 4;
    // Top-left
    verts[base + 0] = (MetalVertex){{x, y}, {u0, v0}, {r, g, b, a}};
    // Top-right
    verts[base + 1] = (MetalVertex){{x + w, y}, {u1, v0}, {r, g, b, a}};
    // Bottom-left
    verts[base + 2] = (MetalVertex){{x, y + h}, {u0, v1}, {r, g, b, a}};
    // Bottom-right
    verts[base + 3] = (MetalVertex){{x + w, y + h}, {u1, v1}, {r, g, b, a}};
    return quadIdx + 1;
}

- (void)updateAtlasTexture {
    uint32_t atlasSize = stvt_get_atlas_size(_ctx);

    // Atlas grew — recreate texture
    if (_atlasTexture && atlasSize != _atlasTextureSize) {
        _atlasTexture = nil;
    }

    // Create texture if needed
    if (!_atlasTexture) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                        width:atlasSize
                                       height:atlasSize
                                    mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        _atlasTexture = [_device newTextureWithDescriptor:desc];
        _atlasTextureSize = atlasSize;

        // Full upload
        const uint8_t *pixels = stvt_get_atlas_pixels(_ctx);
        [_atlasTexture replaceRegion:MTLRegionMake2D(0, 0, atlasSize, atlasSize)
                         mipmapLevel:0
                           withBytes:pixels
                         bytesPerRow:atlasSize * 4];
        stvt_clear_atlas_dirty(_ctx);
        return;
    }

    // Partial upload if dirty
    if (stvt_is_atlas_dirty(_ctx)) {
        StvtAtlasDirtyRegion rgn = stvt_get_atlas_dirty_region(_ctx);
        uint32_t w = rgn.max_x - rgn.min_x;
        uint32_t h = rgn.max_y - rgn.min_y;
        if (w > 0 && h > 0) {
            const uint8_t *pixels = stvt_get_atlas_pixels(_ctx);
            NSUInteger stride = atlasSize * 4;
            const uint8_t *regionStart = pixels + rgn.min_y * stride + rgn.min_x * 4;
            [_atlasTexture replaceRegion:MTLRegionMake2D(rgn.min_x, rgn.min_y, w, h)
                             mipmapLevel:0
                               withBytes:regionStart
                             bytesPerRow:stride];
        }
        stvt_clear_atlas_dirty(_ctx);
    }
}

- (void)renderMetal {
    if (!_ctx || !_device) return;

    // Sync render state from terminal (picks up viewport scrolls, new content, etc.)
    stvt_update_render_state(_ctx);

    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);

    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (!drawable) {
        dispatch_semaphore_signal(_frameSemaphore);
        return;
    }

    // Update drawable size to match current bounds
    CGSize drawSize = CGSizeMake(self.bounds.size.width * _contentScale,
                                  self.bounds.size.height * _contentScale);
    _metalLayer.drawableSize = drawSize;

    // Set uniforms (viewport in pixels)
    float *uniforms = (float *)[_uniformBuffer contents];
    uniforms[0] = (float)drawSize.width;
    uniforms[1] = (float)drawSize.height;

    // Get terminal state
    uint16_t cols = stvt_get_cols(_ctx);
    uint16_t rows = stvt_get_rows(_ctx);
    uint32_t cw = stvt_get_cell_width(_ctx);
    uint32_t ch = stvt_get_cell_height(_ctx);
    uint32_t ascent = stvt_get_ascent(_ctx);
    uint32_t atlasSize = stvt_get_atlas_size(_ctx);
    float invAtlas = 1.0f / (float)atlasSize;

    // Default colors
    uint8_t bg_r = stvt_get_default_bg_r(_ctx);
    uint8_t bg_g = stvt_get_default_bg_g(_ctx);
    uint8_t bg_b = stvt_get_default_bg_b(_ctx);
    uint8_t bg_a = stvt_get_bg_alpha(_ctx);

    // Get render state
    GhosttyRenderState rs = stvt_get_render_state(_ctx);
    if (!rs) {
        dispatch_semaphore_signal(_frameSemaphore);
        return;
    }

    GhosttyRenderStateColors rsColors;
    rsColors.size = sizeof(GhosttyRenderStateColors);
    ghostty_render_state_colors_get(rs, &rsColors);
    uint8_t def_fg_r = rsColors.foreground.r;
    uint8_t def_fg_g = rsColors.foreground.g;
    uint8_t def_fg_b = rsColors.foreground.b;

    // Current vertex buffer
    id<MTLBuffer> vertexBuf = _vertexBuffers[_frameIndex % kFramesInFlight];
    MetalVertex *verts = (MetalVertex *)[vertexBuf contents];

    // Build geometry in three segments: backgrounds, glyphs, decorations
    // Each segment starts at a fixed offset in the vertex/index buffer
    NSUInteger bgBase = 0;
    NSUInteger glyphBase = kMaxQuads / 3;
    NSUInteger decoBase = 2 * kMaxQuads / 3;

    // Absolute quad indices (start at their base, increment as quads are emitted)
    NSUInteger bgIdx = bgBase;
    NSUInteger glyphIdx = glyphBase;
    NSUInteger decoIdx = decoBase;

    // Create row iterator
    GhosttyRenderStateRowIterator rowIt = NULL;
    ghostty_render_state_row_iterator_new(NULL, &rowIt);
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIt);

    GhosttyRenderStateRowCells rowCells = NULL;
    ghostty_render_state_row_cells_new(NULL, &rowCells);

    uint16_t row_idx = 0;
    while (ghostty_render_state_row_iterator_next(rowIt)) {
        float y = (float)(row_idx * ch);

        ghostty_render_state_row_get(rowIt, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells);

        uint16_t col_idx = 0;
        while (ghostty_render_state_row_cells_next(rowCells)) {
            float x = (float)(col_idx * cw);
            float fcw = (float)cw;
            float fch = (float)ch;

            // Cell background + style (read style early for inverse video)
            GhosttyColorRgb cellBg;
            GhosttyResult bgResult = ghostty_render_state_row_cells_get(
                rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &cellBg);

            GhosttyStyle style;
            style.size = sizeof(GhosttyStyle);
            ghostty_render_state_row_cells_get(rowCells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);

            GhosttyColorRgb cellFg;
            GhosttyResult fgResult = ghostty_render_state_row_cells_get(
                rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &cellFg);

            if (style.inverse) {
                // Inverse: background becomes fg color, fg becomes bg color
                float inv_r = (fgResult == GHOSTTY_SUCCESS) ? cellFg.r / 255.0f : def_fg_r / 255.0f;
                float inv_g = (fgResult == GHOSTTY_SUCCESS) ? cellFg.g / 255.0f : def_fg_g / 255.0f;
                float inv_b = (fgResult == GHOSTTY_SUCCESS) ? cellFg.b / 255.0f : def_fg_b / 255.0f;
                bgIdx = emitQuad(verts, bgIdx,
                    x, y, fcw, fch, 0, 0, 0, 0,
                    inv_r, inv_g, inv_b, 1.0f);
            } else if (bgResult == GHOSTTY_SUCCESS) {
                bgIdx = emitQuad(verts, bgIdx,
                    x, y, fcw, fch, 0, 0, 0, 0,
                    cellBg.r / 255.0f, cellBg.g / 255.0f, cellBg.b / 255.0f, 1.0f);
            }

            // Selection highlight
            if (stvt_is_cell_selected(_ctx, col_idx, row_idx)) {
                bgIdx = emitQuad(verts, bgIdx,
                    x, y, fcw, fch, 0, 0, 0, 0,
                    1.0f, 1.0f, 1.0f, 0.3f);
            }

            // Check for text
            uint32_t grapheme_len = 0;
            ghostty_render_state_row_cells_get(rowCells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &grapheme_len);
            if (grapheme_len == 0) { col_idx++; continue; }

            uint32_t codepoints[16];
            ghostty_render_state_row_cells_get(rowCells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, codepoints);
            uint32_t cp = codepoints[0];
            if (cp == 0) { col_idx++; continue; }

            uint8_t fontStyle = 0;
            if (style.bold && style.italic) fontStyle = 3;
            else if (style.bold) fontStyle = 1;
            else if (style.italic) fontStyle = 2;

            // Fg color (inverse swaps fg ↔ bg)
            uint8_t fg_r, fg_g, fg_b;
            if (style.inverse) {
                fg_r = (bgResult == GHOSTTY_SUCCESS) ? cellBg.r : bg_r;
                fg_g = (bgResult == GHOSTTY_SUCCESS) ? cellBg.g : bg_g;
                fg_b = (bgResult == GHOSTTY_SUCCESS) ? cellBg.b : bg_b;
            } else {
                fg_r = (fgResult == GHOSTTY_SUCCESS) ? cellFg.r : def_fg_r;
                fg_g = (fgResult == GHOSTTY_SUCCESS) ? cellFg.g : def_fg_g;
                fg_b = (fgResult == GHOSTTY_SUCCESS) ? cellFg.b : def_fg_b;
            }

            // Rasterize glyph (may update atlas)
            StvtGlyphInfo glyph = stvt_get_glyph(_ctx, cp, fontStyle);
            if (!glyph.found || glyph.width == 0 || glyph.height == 0) { col_idx++; continue; }

            // Glyph quad position (in pixels)
            float gx = x + (float)glyph.bearing_x;
            float gy = y + (float)((int32_t)ascent - glyph.bearing_y);
            float gw = (float)glyph.width;
            float gh = (float)glyph.height;

            // Atlas UVs
            float u0 = (float)glyph.atlas_x * invAtlas;
            float v0 = (float)glyph.atlas_y * invAtlas;
            float u1 = (float)(glyph.atlas_x + glyph.width) * invAtlas;
            float v1 = (float)(glyph.atlas_y + glyph.height) * invAtlas;

            glyphIdx = emitQuad(verts, glyphIdx,
                gx, gy, gw, gh, u0, v0, u1, v1,
                fg_r / 255.0f, fg_g / 255.0f, fg_b / 255.0f, 1.0f);

            // Decorations
            if (style.underline != 0) {
                float ul_y = y + (float)(ascent + 1);
                decoIdx = emitQuad(verts, decoIdx,
                    x, ul_y, fcw, 1.0f, 0, 0, 0, 0,
                    fg_r / 255.0f, fg_g / 255.0f, fg_b / 255.0f, 1.0f);
            }
            if (style.strikethrough) {
                float st_y = y + (float)(ascent / 2);
                decoIdx = emitQuad(verts, decoIdx,
                    x, st_y, fcw, 1.0f, 0, 0, 0, 0,
                    fg_r / 255.0f, fg_g / 255.0f, fg_b / 255.0f, 1.0f);
            }

            col_idx++;
        }

        // Clear row dirty
        bool clean = false;
        ghostty_render_state_row_set(rowIt, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean);
        row_idx++;
    }

    // Cursor
    bool cursorVisible = false;
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &cursorVisible);
    bool cursorModeVisible = true;
    ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursorModeVisible);

    if (cursorVisible && cursorModeVisible) {
        uint16_t cx = 0, cy = 0;
        ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx);
        ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy);

        // Clamp to grid bounds (cursor can be transiently out of range during resize)
        if (cx >= cols) cx = (cols > 0) ? cols - 1 : 0;
        if (cy >= rows) cy = (rows > 0) ? rows - 1 : 0;

        GhosttyRenderStateCursorVisualStyle curStyle = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
        ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &curStyle);

        float cur_x = (float)(cx * cw);
        float cur_y = (float)(cy * ch);
        float cfr = def_fg_r / 255.0f;
        float cfg = def_fg_g / 255.0f;
        float cfb = def_fg_b / 255.0f;

        switch (curStyle) {
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
                decoIdx = emitQuad(verts, decoIdx,
                    cur_x, cur_y, (float)cw, (float)ch, 0, 0, 0, 0,
                    cfr, cfg, cfb, 0.5f);
                break;
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
                decoIdx = emitQuad(verts, decoIdx,
                    cur_x, cur_y, 2.0f, (float)ch, 0, 0, 0, 0,
                    cfr, cfg, cfb, 1.0f);
                break;
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
                decoIdx = emitQuad(verts, decoIdx,
                    cur_x, cur_y + (float)ch - 2.0f, (float)cw, 2.0f, 0, 0, 0, 0,
                    cfr, cfg, cfb, 1.0f);
                break;
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: {
                // Four thin rects for hollow cursor outline
                float lw = 1.0f;
                decoIdx = emitQuad(verts, decoIdx,
                    cur_x, cur_y, (float)cw, lw, 0, 0, 0, 0, cfr, cfg, cfb, 1.0f); // top
                decoIdx = emitQuad(verts, decoIdx,
                    cur_x, cur_y + (float)ch - lw, (float)cw, lw, 0, 0, 0, 0, cfr, cfg, cfb, 1.0f); // bottom
                decoIdx = emitQuad(verts, decoIdx,
                    cur_x, cur_y, lw, (float)ch, 0, 0, 0, 0, cfr, cfg, cfb, 1.0f); // left
                decoIdx = emitQuad(verts, decoIdx,
                    cur_x + (float)cw - lw, cur_y, lw, (float)ch, 0, 0, 0, 0, cfr, cfg, cfb, 1.0f); // right
                break;
            }
        }
    }

    // Free iterators
    ghostty_render_state_row_cells_free(rowCells);
    ghostty_render_state_row_iterator_free(rowIt);

    // Clear global dirty
    GhosttyRenderStateDirty cleanState = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    ghostty_render_state_set(rs, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &cleanState);

    // Upload atlas texture (after all stvt_get_glyph calls)
    [self updateAtlasTexture];

    // Create render pass
    MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
    passDesc.colorAttachments[0].texture = drawable.texture;
    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
    // Clear to default bg (premultiplied)
    float ba = bg_a / 255.0f;
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(
        (bg_r / 255.0f) * ba, (bg_g / 255.0f) * ba, (bg_b / 255.0f) * ba, ba);

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:passDesc];

    [enc setVertexBuffer:vertexBuf offset:0 atIndex:0];
    [enc setVertexBuffer:_uniformBuffer offset:0 atIndex:1];

    // Pass 1: Backgrounds + selection
    NSUInteger bgCount = bgIdx - bgBase;
    if (bgCount > 0) {
        [enc setRenderPipelineState:_colorPipeline];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:bgCount * kIndicesPerQuad
                         indexType:MTLIndexTypeUInt32
                       indexBuffer:_indexBuffer
                 indexBufferOffset:bgBase * kIndicesPerQuad * sizeof(uint32_t)];
    }

    // Pass 2: Glyphs
    NSUInteger glyphCount = glyphIdx - glyphBase;
    if (glyphCount > 0 && _atlasTexture) {
        [enc setRenderPipelineState:_glyphPipeline];
        [enc setFragmentTexture:_atlasTexture atIndex:0];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:glyphCount * kIndicesPerQuad
                         indexType:MTLIndexTypeUInt32
                       indexBuffer:_indexBuffer
                 indexBufferOffset:glyphBase * kIndicesPerQuad * sizeof(uint32_t)];
    }

    // Pass 3: Decorations + cursor
    NSUInteger decoCount = decoIdx - decoBase;
    if (decoCount > 0) {
        [enc setRenderPipelineState:_colorPipeline];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:decoCount * kIndicesPerQuad
                         indexType:MTLIndexTypeUInt32
                       indexBuffer:_indexBuffer
                 indexBufferOffset:decoBase * kIndicesPerQuad * sizeof(uint32_t)];
    }

    [enc endEncoding];
    [cmdBuf presentDrawable:drawable];

    dispatch_semaphore_t sema = _frameSemaphore;
    [cmdBuf addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull buf) {
        (void)buf;
        dispatch_semaphore_signal(sema);
    }];
    [cmdBuf commit];

    _frameIndex++;
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

    // Listen for window resize (including fullscreen transitions)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowDidResize:)
                                                 name:NSWindowDidResizeNotification
                                               object:_window];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowDidResize:)
                                                 name:NSWindowDidEnterFullScreenNotification
                                               object:_window];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowDidResize:)
                                                 name:NSWindowDidExitFullScreenNotification
                                               object:_window];
}

- (void)doPoll {
    if (!_ctx) return;

    int32_t dirty = stvt_poll(_ctx);
    if (dirty < 0) {
        [NSApp terminate:nil];
        return;
    }

    if (dirty > 0) {
        [_termView renderMetal];
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
    [_termView renderMetal];
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
