const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ghostty-vt xcframework headers path
    const xcfw_headers = b.path("lib/ghostty-vt.xcframework/macos-arm64_x86_64/Headers");

    // Build a static library from Zig sources (exports C-callable functions)
    const lib = b.addLibrary(.{
        .name = "stvt-core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });

    // ghostty-vt headers for Zig @cImport
    lib.root_module.addIncludePath(xcfw_headers);
    lib.root_module.addIncludePath(b.path("src"));

    // Compile Core Text font shim as part of the library
    lib.addCSourceFile(.{
        .file = b.path("src/font_shim.c"),
        .flags = &.{},
    });

    // macOS frameworks for the Zig library
    if (std.process.getEnvVarOwned(b.allocator, "SDKROOT")) |sdk| {
        const fw_path = std.fmt.allocPrint(b.allocator, "{s}/System/Library/Frameworks", .{sdk}) catch unreachable;
        lib.root_module.addFrameworkPath(.{ .cwd_relative = fw_path });
    } else |_| {}
    lib.root_module.linkFramework("CoreFoundation", .{});
    lib.root_module.linkFramework("CoreText", .{});
    lib.root_module.linkFramework("CoreGraphics", .{});

    // Build the ObjC executable
    const exe = b.addExecutable(.{
        .name = "stvt",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    // ObjC source
    exe.addCSourceFile(.{
        .file = b.path("src/app.m"),
        .flags = &.{"-fobjc-arc"},
    });

    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addIncludePath(xcfw_headers);

    // Link Zig static library
    exe.linkLibrary(lib);

    // Link prebuilt ghostty-vt
    exe.addObjectFile(b.path("lib/ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a"));

    // System libraries
    exe.root_module.linkSystemLibrary("c++", .{});
    exe.linkLibC();

    // macOS frameworks
    if (std.process.getEnvVarOwned(b.allocator, "SDKROOT")) |sdk| {
        const fw_path = std.fmt.allocPrint(b.allocator, "{s}/System/Library/Frameworks", .{sdk}) catch unreachable;
        exe.root_module.addFrameworkPath(.{ .cwd_relative = fw_path });
    } else |_| {}
    exe.root_module.linkFramework("CoreFoundation", .{});
    exe.root_module.linkFramework("CoreText", .{});
    exe.root_module.linkFramework("CoreGraphics", .{});
    exe.root_module.linkFramework("AppKit", .{});
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("QuartzCore", .{});

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run stvt");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test step
    _ = b.step("test", "Run tests");
}
