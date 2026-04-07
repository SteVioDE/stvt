const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get ghostty-vt module from vendor/ghostty dependency
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    });

    const exe = b.addExecutable(.{
        .name = "stvt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ghostty", .module = ghostty_dep.module("ghostty-vt") },
            },
        }),
    });

    // Compile Core Text font shim
    exe.addCSourceFile(.{
        .file = b.path("src/font_shim.c"),
        .flags = &.{},
    });

    // Compile window blur shim (Objective-C)
    exe.addCSourceFile(.{
        .file = b.path("src/window_shim.m"),
        .flags = &.{"-fobjc-arc"},
    });


    // Allow Zig code to @cImport the shim header
    exe.root_module.addIncludePath(b.path("src"));

    // SDL3: use env vars set by devbox shell init_hook
    if (std.process.getEnvVarOwned(b.allocator, "SDL3_INCLUDE_PATH")) |sdl3_include| {
        exe.root_module.addSystemIncludePath(.{ .cwd_relative = sdl3_include });
    } else |_| {}

    if (std.process.getEnvVarOwned(b.allocator, "SDL3_LIB_PATH")) |sdl3_lib| {
        exe.root_module.addLibraryPath(.{ .cwd_relative = sdl3_lib });
        exe.root_module.addRPath(.{ .cwd_relative = sdl3_lib });
    } else |_| {}

    exe.root_module.linkSystemLibrary("SDL3", .{});

    // macOS system frameworks — add SDK framework search path for nix environments
    if (std.process.getEnvVarOwned(b.allocator, "SDKROOT")) |sdk| {
        const fw_path = std.fmt.allocPrint(b.allocator, "{s}/System/Library/Frameworks", .{sdk}) catch unreachable;
        exe.root_module.addFrameworkPath(.{ .cwd_relative = fw_path });
    } else |_| {
        // Try xcrun fallback
    }
    exe.root_module.linkFramework("CoreFoundation", .{});
    exe.root_module.linkFramework("CoreText", .{});
    exe.root_module.linkFramework("CoreGraphics", .{});
    exe.root_module.linkFramework("AppKit", .{});

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run stvt");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test step (placeholder — tests will use pty.zig and terminal.zig directly)
    _ = b.step("test", "Run tests");
}
