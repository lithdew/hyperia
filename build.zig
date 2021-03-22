const std = @import("std");
const Pkg = std.build.Pkg;
const Builder = std.build.Builder;

pub const pkgs = struct {
    pub const zap = Pkg{
        .name = "zap",
        .path = "zap/src/zap.zig",
    };

    pub const hyperia = Pkg{
        .name = "hyperia",
        .path = "hyperia.zig",
        .dependencies = &[_]Pkg{
            zap,
        },
    };

    pub const picohttp = Pkg{
        .name = "picohttp",
        .path = "picohttp/picohttp.zig",
    };
};

pub fn register(step: *std.build.LibExeObjStep) void {
    step.addCSourceFile("picohttp/lib/picohttpparser.c", &[_][]const u8{});
    step.linkLibC();

    step.addPackage(pkgs.zap);
    step.addPackage(pkgs.hyperia);
    step.addPackage(pkgs.picohttp);
}

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const test_step = b.step("test", "Run library tests.");
    const test_filter = b.option([]const u8, "test-filter", "Test filter");

    const file = b.addTest("hyperia.zig");
    file.setTarget(target);
    file.setBuildMode(mode);
    register(file);

    if (test_filter != null) {
        file.setFilter(test_filter.?);
    }

    test_step.dependOn(&file.step);

    inline for (.{
        "example_tcp_server",
    }) |example_name| {
        const example_step = b.step(example_name, "Example " ++ example_name ++ ".zig");

        const exe = b.addExecutable(example_name, example_name ++ ".zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        register(exe);
        exe.install();

        const exe_run = exe.run();
        if (b.args != null) {
            exe_run.addArgs(b.args.?);
        }

        example_step.dependOn(&exe_run.step);
    }
}
