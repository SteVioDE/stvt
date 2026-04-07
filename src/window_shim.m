#import "window_shim.h"
#import <Cocoa/Cocoa.h>

void window_enable_blur(void *nswindow_ptr) {
    NSWindow *window = (__bridge NSWindow *)nswindow_ptr;

    // Make window non-opaque so compositor blur shows through
    window.opaque = NO;
    window.backgroundColor = [NSColor clearColor];

    // Create blur effect view behind all content
    NSView *content = window.contentView;
    NSVisualEffectView *blur = [[NSVisualEffectView alloc]
        initWithFrame:content.bounds];
    blur.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    blur.material = NSVisualEffectMaterialHUDWindow;
    blur.state = NSVisualEffectStateActive;
    blur.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [content addSubview:blur positioned:NSWindowBelow relativeTo:nil];
}
