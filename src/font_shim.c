#include "font_shim.h"
#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdlib.h>

// Unicode UTF-16 surrogate pair constants
#define HIGH_SURROGATE_BASE  0xD800
#define LOW_SURROGATE_BASE   0xDC00
#define SURROGATE_MASK       0x3FF
#define SUPPLEMENTARY_OFFSET 0x10000

static void *font_init_with_traits(const char *font_name, float size, CTFontSymbolicTraits traits) {
    CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, font_name, kCFStringEncodingUTF8);
    CTFontRef base_font = CTFontCreateWithName(name, (CGFloat)size, NULL);
    CFRelease(name);

    if (traits == 0) {
        return (void *)base_font;
    }

    CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(base_font, 0.0, NULL, traits, traits);
    CFRelease(base_font);

    if (styled == NULL) {
        CFStringRef name2 = CFStringCreateWithCString(kCFAllocatorDefault, font_name, kCFStringEncodingUTF8);
        CTFontRef fallback = CTFontCreateWithName(name2, (CGFloat)size, NULL);
        CFRelease(name2);
        return (void *)fallback;
    }

    return (void *)styled;
}

void *font_init(const char *font_name, float size) {
    return font_init_with_traits(font_name, size, 0);
}

void *font_init_bold(const char *font_name, float size) {
    return font_init_with_traits(font_name, size, kCTFontBoldTrait);
}

void *font_init_italic(const char *font_name, float size) {
    return font_init_with_traits(font_name, size, kCTFontItalicTrait);
}

void *font_init_bold_italic(const char *font_name, float size) {
    return font_init_with_traits(font_name, size, kCTFontBoldTrait | kCTFontItalicTrait);
}

void font_deinit(void *handle) {
    if (handle) {
        CFRelease((CTFontRef)handle);
    }
}

FontMetrics font_get_metrics(void *handle) {
    CTFontRef font = (CTFontRef)handle;

    CGFloat ascent = CTFontGetAscent(font);
    CGFloat descent = CTFontGetDescent(font);
    CGFloat leading = CTFontGetLeading(font);

    int cell_height = (int)ceil(ascent + descent + leading);

    UniChar ch = 'M';
    CGGlyph glyph;
    CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1);
    CGSize advance;
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyph, &advance, 1);
    int cell_width = (int)ceil(advance.width);

    return (FontMetrics){
        .cell_width = cell_width,
        .cell_height = cell_height,
        .ascent = (int)ceil(ascent),
        .descent = (int)ceil(descent),
    };
}

GlyphBitmap font_rasterize(void *handle, uint32_t codepoint) {
    CTFontRef font = (CTFontRef)handle;
    GlyphBitmap result = {0};

    UniChar chars[2];
    int char_count;
    if (codepoint > 0xFFFF) {
        uint32_t cp = codepoint - SUPPLEMENTARY_OFFSET;
        chars[0] = (UniChar)(HIGH_SURROGATE_BASE + (cp >> 10));
        chars[1] = (UniChar)(LOW_SURROGATE_BASE + (cp & SURROGATE_MASK));
        char_count = 2;
    } else {
        chars[0] = (UniChar)codepoint;
        char_count = 1;
    }

    CGGlyph glyphs[2];
    CTFontRef render_font = font;
    bool used_fallback = false;

    if (!CTFontGetGlyphsForCharacters(font, chars, glyphs, char_count)) {
        // Primary font doesn't have this glyph — ask Core Text for a fallback
        CFStringRef str = CFStringCreateWithCharacters(kCFAllocatorDefault, chars, char_count);
        if (!str) return result;
        CTFontRef fallback = CTFontCreateForString(font, str, CFRangeMake(0, CFStringGetLength(str)));
        CFRelease(str);
        if (!fallback) return result;

        if (!CTFontGetGlyphsForCharacters(fallback, chars, glyphs, char_count)) {
            CFRelease(fallback);
            return result;
        }
        render_font = fallback;
        used_fallback = true;
    }

    CGGlyph glyph = glyphs[0];

    CGRect bbox;
    CTFontGetBoundingRectsForGlyphs(render_font, kCTFontOrientationHorizontal, &glyph, &bbox, 1);
    CGSize advance_size;
    CTFontGetAdvancesForGlyphs(render_font, kCTFontOrientationHorizontal, &glyph, &advance_size, 1);

    int bmp_width = (int)ceil(bbox.size.width);
    int bmp_height = (int)ceil(bbox.size.height);

    if (bmp_width <= 0 || bmp_height <= 0) {
        result.advance = (int)ceil(advance_size.width);
        if (used_fallback) CFRelease(render_font);
        return result;
    }

    uint8_t *bitmap = (uint8_t *)calloc(bmp_width * bmp_height, 1);
    if (!bitmap) return result;

    CGColorSpaceRef gray_space = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(
        bitmap,
        bmp_width,
        bmp_height,
        8,
        bmp_width,
        gray_space,
        kCGImageAlphaNone
    );
    CGColorSpaceRelease(gray_space);

    if (!ctx) {
        free(bitmap);
        return result;
    }

    // White fill on black background — pixel values = glyph coverage
    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    CGContextSetGrayStrokeColor(ctx, 1.0, 1.0);

    // Enable font smoothing for crisp antialiased glyphs
    CGContextSetAllowsFontSmoothing(ctx, true);
    CGContextSetShouldSmoothFonts(ctx, true);
    CGContextSetAllowsAntialiasing(ctx, true);
    CGContextSetShouldAntialias(ctx, true);

    CGPoint position = CGPointMake(-bbox.origin.x, -bbox.origin.y);

    CTFontDrawGlyphs(render_font, &glyph, &position, 1, ctx);

    CGContextRelease(ctx);
    if (used_fallback) CFRelease(render_font);

    result.bitmap = bitmap;
    result.width = bmp_width;
    result.height = bmp_height;
    result.bearing_x = (int)floor(bbox.origin.x);
    result.bearing_y = (int)ceil(bbox.origin.y + bbox.size.height);
    result.advance = (int)ceil(advance_size.width);

    return result;
}
