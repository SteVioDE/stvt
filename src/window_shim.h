#pragma once

/// Enable background blur on macOS by making the window transparent
/// and inserting an NSVisualEffectView behind the content.
void window_enable_blur(void *nswindow_ptr);
