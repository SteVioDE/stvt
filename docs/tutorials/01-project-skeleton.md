# Chapter 01: Project Skeleton & Build System

> **Learning objective:** By the end of this chapter, you will have a Zig project that compiles a static library and links it into a macOS executable, with framework linking and a prebuilt C library — all orchestrated by the Zig build system.

## Why This Matters

A terminal emulator on macOS needs three languages working together: Zig for core logic (PTY management, VT parsing, glyph caching), C for bridging to system APIs (Core Text font rasterization), and Objective-C for the GUI shell (AppKit windows, Metal rendering). Before you write a single line of terminal logic, you need a build system that can orchestrate all three.

Most Zig tutorials show you a single `zig build-exe` workflow. This project is different: Zig compiles into a **static library**, and the actual program entry point lives in an Objective-C file that links against that library. Getting this foundation right means every future chapter — from PTY spawning to Metal shaders — just slots into place.

## What We're Building

A build system that produces two artifacts:
1. **A Zig static library** (`stvt-core`) containing all the terminal logic (stubs for now)
2. **A macOS executable** (`stvt`) compiled from Objective-C, linked against the Zig library, a prebuilt VT parser library, and six macOS frameworks

The executable won't do anything visible yet — it just exits cleanly. But the entire multi-language build pipeline will be proven out.

## Step 1: Initialize the Project

Run the Zig project initializer:

```bash
zig init
```

This creates four files. Take a look at what you got:

```
.
├── build.zig        # Build configuration (like a Makefile, but in Zig)
├── build.zig.zon    # Package manifest (name, version, dependencies)
└── src/
    ├── main.zig     # Default executable entry point
    └── root.zig     # Default library root
```

The generated `build.zig` has a sample library and executable. You'll replace it entirely. The `build.zig.zon` has placeholder metadata you'll customize. Delete `src/root.zig` — you won't need it:

```bash
rm src/root.zig
```

## Step 2: Acquire the Ghostty VT Library

The terminal emulator uses [ghostty](https://github.com/ghostty-org/ghostty)'s VT parser — a zero-dependency C library that handles escape sequence parsing and terminal state management (cursor position, styles, scrollback, text reflow). Rather than writing a VT parser from scratch, you'll link against a prebuilt static library.

Download the prebuilt xcframework from the ghostty releases:

```bash
mkdir -p lib
curl -sL -o /tmp/ghostty-vt.xcframework.zip \
  https://github.com/ghostty-org/ghostty/releases/download/tip/ghostty-vt.xcframework.zip
unzip -q /tmp/ghostty-vt.xcframework.zip -d lib/
```

You should now have `lib/ghostty-vt.xcframework/`. Inspect its structure:

```bash
find lib/ghostty-vt.xcframework -type f | head -20
```

Inside, you'll find a directory for macOS containing two things you'll need:
- A static library file (`.a`) — the compiled VT parser
- A `Headers/` directory — the C API headers your Zig code will import

Note the exact directory name inside the xcframework (e.g., `macos-arm64_x86_64/`) — you'll reference it in your build configuration.

## Step 3: Set Up Tooling

You already have `devbox.json` managing the Zig toolchain. Let's add a `justfile` for convenient build commands. Install `just` if you don't have it:

```bash
brew install just
```

Create a `justfile` at the project root:

```just
# justfile

# Build the project
build:
    zig build

# Build and run
run:
    zig build && ./zig-out/bin/stvt

# Clean build artifacts
clean:
    rm -rf zig-out .zig-cache
```

## Step 4: Write the Package Manifest

The `build.zig.zon` file is Zig's package manifest — it declares your project's identity, version, and which files belong to the package. The init command created one with placeholders.

**Exercise 1:** Replace the contents of `build.zig.zon` with a manifest for the stvt project. It should declare:
- The project name as `"stvt"`
- A version of `0.0.0`
- A minimum Zig version (use `.zig_version = "0.14.0"`)
- The paths that belong to the package: `"build.zig"`, `"build.zig.zon"`, and `"src"`

```zig
// build.zig.zon
.{
    .name = .{ .buffer = "stvt" },
    // EXERCISE: Declare the version, minimum Zig version, and paths array.
    // The version should be 0.0.0, minimum Zig version 0.14.0,
    // and paths should include "build.zig", "build.zig.zon", and "src".
    .fingerprint = 0x0,
}
```

*Hint: The `.version` and `.minimum_zig_version` fields both use the same format as `.name` — a `.buffer` containing a string. The `.paths` field is a tuple of string literals.*

## Step 5: Create the Library Root

Here's where things get interesting. In a normal Zig program, `main.zig` has a `pub fn main`. In this project, `src/main.zig` is the **library root** — the entry point for the static library, not for an executable.

The Zig compiler is lazy: it only compiles code that's reachable from the root. If you have a module that exports C-callable functions (like `stvt_init`, `stvt_destroy`) but nothing in the library root references it, the compiler won't compile it and the linker won't see those symbols.

The solution is a `comptime` block that forces the compiler to analyze a module even though nothing calls it at runtime.

First, create the stub module that the library root will reference. Create `src/stvt_api.zig`:

```zig
// src/stvt_api.zig
const std = @import("std");

pub const log = std.log.scoped(.stvt);
```

This is just a placeholder — future chapters will fill it with the actual C API. The important thing is that it exists so the library root can reference it.

**Exercise 2:** Write `src/main.zig` as a library root that forces compilation of the `stvt_api` module. The file should:
- Import `stvt_api` as a module
- Use a `comptime` block to reference it so the compiler doesn't skip it
- The standard pattern is: `comptime { _ = module; }`

```zig
// src/main.zig

// EXERCISE: Import the stvt_api module and force the compiler to compile it.
// You need two things:
// 1. A const that imports "stvt_api.zig"
// 2. A comptime block that references that const so the compiler includes it.
```

*Hint: `@import` returns a struct type. A `comptime` block with `_ = some_import;` tells the compiler "I know this looks unused — analyze it anyway."*

## Step 6: Create Stub Source Files

The build system will reference a C source file and an Objective-C source file. Create minimal stubs so the build succeeds.

Create `src/font_shim.c` — an empty C file that will eventually contain the Core Text font bridge:

```c
// src/font_shim.c
// Font rasterization bridge — implemented in Chapter 04
```

Create `src/app.m` — a minimal Objective-C file with a `main` function:

```objc
// src/app.m
#import <Foundation/Foundation.h>

int main(int argc, const char *argv[]) {
    return 0;
}
```

This is the actual program entry point. In later chapters, it will create an NSApplication, open a window, and start the Metal render loop. For now, it just exits.

## Step 7: Write the Build Function

This is the core of the chapter. The `build.zig` file defines a `pub fn build` that the Zig build system calls. You need to create two artifacts and wire them together.

Here's the overall structure. Replace the entire contents of `build.zig`:

```zig
// build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Part 1: The Zig static library ---
    // (Exercise 3)

    // --- Part 2: The macOS executable ---
    // (Exercise 4)
}
```

The `standardTargetOptions` and `standardOptimizeOption` calls let the user pass `-Dtarget` and `-Doptimize` on the command line. They default to the host platform and debug mode.

**Exercise 3:** Add the static library. Between the Part 1 comments, create a static library artifact that:
- Is named `"stvt-core"`
- Uses `src/main.zig` as its root source file
- Uses the `target` and `optimize` from above
- Adds `src/font_shim.c` as a C source file (with no extra flags)
- Adds two include paths: one for the ghostty headers inside the xcframework, and one for `"src"` (so C code can find project headers)
- Installs the artifact (so `zig build` produces output)

```zig
    // --- Part 1: The Zig static library ---

    // EXERCISE: Create a static library named "stvt-core" with root_module from
    // src/main.zig, using target and optimize. Then:
    // - Add src/font_shim.c as a C source file
    // - Add include paths for ghostty headers and "src"
    // - Install the artifact
    //
    // Functions you'll need:
    //   b.addStaticLibrary(.{ ... })
    //   lib.addCSourceFile(.{ .file = b.path(...) })
    //   lib.addIncludePath(b.path(...))
    //   b.installArtifact(lib)
```

*Hint: `addStaticLibrary` takes a struct with `.name`, `.root_module`. The root module is created with `.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }`. The ghostty headers path is relative to the xcframework directory you inspected earlier — something like `"lib/ghostty-vt.xcframework/<platform-dir>/Headers"`.*

**Exercise 4:** Add the executable. Between the Part 2 comments, create an executable that:
- Is named `"stvt"`
- Has no Zig root source (the entry point is in Objective-C)
- Adds `src/app.m` as a C source file with the flag `"-fobjc-arc"` (enables automatic reference counting)
- Adds the same include paths as the library
- Links against the Zig static library from Exercise 3
- Adds the prebuilt ghostty `.a` file as an object (use `addObjectFile`)
- Links system libraries: `"c++"` and `"c"`
- Links these macOS frameworks: `Metal`, `AppKit`, `CoreText`, `CoreFoundation`, `CoreGraphics`, `QuartzCore`
- Installs the artifact

```zig
    // --- Part 2: The macOS executable ---

    // EXERCISE: Create an executable named "stvt" with no root source file.
    // Wire it up with:
    // - src/app.m as a C source with "-fobjc-arc" flag
    // - Same include paths as the library
    // - Link the Zig static library (lib) from Part 1
    // - Link the prebuilt ghostty .a file via addObjectFile
    // - Link system libraries: c++, c
    // - Link 6 macOS frameworks: Metal, AppKit, CoreText,
    //   CoreFoundation, CoreGraphics, QuartzCore
    // - Install the artifact
    //
    // Functions you'll need:
    //   b.addExecutable(.{ ... })
    //   exe.addCSourceFile(.{ .file = b.path(...), .flags = &.{...} })
    //   exe.addIncludePath(b.path(...))
    //   exe.linkLibrary(lib)
    //   exe.addObjectFile(b.path(...))
    //   exe.linkSystemLibrary("...")
    //   exe.linkFramework("...")
    //   b.installArtifact(exe)
```

*Hint: For the executable root module, pass `.target = target, .optimize = optimize` but no `.root_source_file`. The `-fobjc-arc` flag goes in `.flags = &.{"-fobjc-arc"}`. The prebuilt `.a` file path is inside the xcframework, next to the Headers directory.*

### SDKROOT for Nix/Devbox Users

If you're using devbox (which you are — it's managing your Zig version), the Nix-provided Zig may not find macOS framework headers by default. If `zig build` fails with "unable to find framework" or missing header errors, set `SDKROOT` before building:

```bash
export SDKROOT=$(xcrun --show-sdk-path)
zig build
```

You can add this to your `.envrc` so it's set automatically when you enter the project directory:

```bash
echo 'export SDKROOT=$(xcrun --show-sdk-path)' >> .envrc
direnv allow
```

## Verification

Run the following to verify your work:

```bash
just build
```

Or equivalently:

```bash
zig build
```

**Expected output:**

No errors. The command should complete silently. Then confirm both artifacts exist:

```bash
ls zig-out/lib/libstvt-core.a zig-out/bin/stvt
```

**Expected output:**
```
zig-out/lib/libstvt-core.a  zig-out/bin/stvt
```

Finally, run the executable to confirm it exits cleanly:

```bash
./zig-out/bin/stvt; echo "Exit code: $?"
```

**Expected output:**
```
Exit code: 0
```

If you get stuck on any exercise, run `/stevio-help E1.N` (replacing N with the exercise number) for guidance.
