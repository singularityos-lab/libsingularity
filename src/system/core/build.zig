const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
        .strip = optimize != .Debug,
    });
    const lib = b.addLibrary(.{
        .name = "sinty-system-core",
        .linkage = .dynamic,
        .root_module = mod,
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
    });
    b.installArtifact(lib);
    b.installFile("include/sinty-system/v1.h", "include/sinty-system/v1.h");
    b.installFile("vapi/sinty-system-core.vapi", "share/vala/vapi/sinty-system-core.vapi");

    const pc = b.addWriteFiles();
    const pc_file = pc.add("sinty-system-1.pc", b.fmt(
        \\prefix={s}
        \\libdir=${{prefix}}/lib
        \\includedir=${{prefix}}/include
        \\
        \\Name: sinty-system
        \\Description: Sinty system core: processes, sensors, power, displays, devices, network and firewall through a flat C API
        \\Version: 1.0
        \\Libs: -L${{libdir}} -lsinty-system-core
        \\Cflags: -I${{includedir}}
        \\
    , .{b.option([]const u8, "pc-prefix", "prefix written into the pkg-config file") orelse "/usr"}));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(pc_file, .lib, "pkgconfig/sinty-system-1.pc").step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/abi_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    tests.root_module.addIncludePath(b.path("include"));
    const run = b.addRunArtifact(tests);
    b.step("test", "Run the core tests").dependOn(&run.step);
}
