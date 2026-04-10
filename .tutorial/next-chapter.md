# Next Chapter: Project Skeleton & Build System

## Chapter Number
01

## Learning Goals
- Initialize a Zig project and understand the package manifest
- Configure build.zig for a multi-language build (Zig static lib + ObjC executable)
- Link macOS frameworks (Metal, AppKit, CoreText, etc.) from the Zig build system

## Concepts to Teach

This chapter introduces the reader to setting up a Zig project that must interoperate with C and Objective-C code. The key conceptual challenge is that terminal emulators on macOS typically need three languages working together: Zig for core logic, C for system API bridges, and Objective-C for the GUI shell. The build system must orchestrate all three.

The reader needs to understand two core ideas:

1. **Zig as a library, not an executable.** Unlike a typical Zig program with a `pub fn main`, this project compiles Zig code into a static library. The actual program entry point lives in an Objective-C file. The Zig library root uses `comptime` blocks to force compilation of modules that export C-callable functions — without this, the linker would strip them as unreachable.

2. **The Zig build system as a multi-language orchestrator.** The build function creates two artifacts: a static library from Zig sources, and an executable from Objective-C sources. The executable links against the Zig library plus a prebuilt third-party C library. Both artifacts need access to C header search paths, and the executable needs macOS framework linking (AppKit, Metal, CoreText, CoreFoundation, CoreGraphics, QuartzCore).

The package manifest declares the project name, version, minimum Zig version, and which paths are part of the package. It has no external dependencies (the ghostty library is vendored as a prebuilt binary).

## Expected Outcome

After this chapter, the reader should have:
- A Zig project that compiles a static library from a minimal library root file
- A build configuration that compiles an Objective-C source file into an executable, linking the Zig static library
- Framework linking for all required macOS frameworks
- Include paths set up so Zig code can import C headers from the vendored library and from the project's own source directory
- A package manifest declaring the project metadata
- The project should build successfully (even though the ObjC source and Zig modules are stubs at this point)

## Teaching Hints

- Start by having the reader run the init command to generate a fresh project skeleton. Then replace the generated files with the terminal emulator's structure.
- Explain why the Zig code is compiled as a static library rather than an executable. The mental model: "Zig provides the brain, ObjC provides the body."
- The comptime-forced-import pattern is non-obvious — explain that Zig's lazy compilation means unreferenced modules are not compiled, and a comptime block that references a module forces the compiler to include it and emit its exported symbols.
- When teaching framework linking, explain the SDKROOT environment variable: Zig's build system needs to find macOS framework headers, and under some development environments (like Nix/devbox), the default SDK path doesn't work without explicitly resolving it.
- The prebuilt ghostty library is linked as an object file, not via a package manager. This is common for C libraries distributed as static archives.
- Have the reader create a minimal ObjC stub (just a `main` function that returns 0) to verify the build works end-to-end before adding real content.
- Teach the justfile and devbox.json as convenient tooling — the justfile wraps common build commands, and devbox manages the Zig toolchain version.

## Exercises

1. Run the Zig init command and examine the generated project structure. Replace the default source files with the terminal emulator's directory layout.
2. Write the package manifest declaring the project name, version, minimum Zig version, and source paths.
3. Create the library root file that uses comptime to force compilation of the API module.
4. Write the build function: create a static Zig library, compile a C source file into it, set up include paths for both the vendored library headers and the project's own source directory.
5. Add the executable target: compile an Objective-C stub, link the Zig static library, link the prebuilt vendored library, and connect all required macOS frameworks.
6. Verify the full build succeeds by running the build command.

## Carried-Over Exercises
None

## Validation Criteria

- Running the build command completes without errors.
- The build output includes both a static library artifact and an executable artifact.
- The executable can be launched (even if it immediately exits — no GUI expected yet).
- The library root file forces compilation of at least one other module.

## Reference Notes
<!-- INTERNAL — abstracted, never shown to reader -->
- relevant_scope: [build.zig: [build], src/main.zig (whole), build.zig.zon (whole)]
- inventory_symbols: [build (function, pub, build.zig:3, depends_on: [])]
- dependencies: none (first chapter)
- key_structures: The build function creates two artifacts — a Zig static library (stvt-core) and an ObjC executable (stvt). The library compiles src/main.zig as root and includes src/font_shim.c as a C source. The executable compiles src/app.m with -fobjc-arc. Both share include paths for ghostty headers and project sources. The executable links: the Zig library, libghostty-vt.a (prebuilt), libc++, libc, and 6 macOS frameworks. SDKROOT resolution is needed for Nix-based environments.
- expected_patterns: [build function with standardTargetOptions and standardOptimizeOption, addLibrary with static linkage, addCSourceFile for C compilation, addExecutable with addCSourceFile for ObjC, linkLibrary connecting exe to lib, addObjectFile for prebuilt .a, linkFramework calls for macOS frameworks, comptime import in library root]
- hints_for_help: [The SDKROOT block is optional but important for devbox/Nix users — if the reader's build fails on framework headers, suggest they check their SDKROOT. The -fobjc-arc flag enables automatic reference counting for ObjC. linkSystemLibrary("c++") is needed because ghostty-vt is partially compiled from C++. The fingerprint field in build.zig.zon is auto-generated by Zig and the reader can use any value.]
