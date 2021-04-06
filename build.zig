const std = @import("std");
const Pkg = std.build.Pkg;
const Builder = std.build.Builder;

pub const pkgs = struct {
    pub const zap = Pkg{
        .name = "zap",
        .path = "zap/src/zap.zig",
    };

    pub const clap = Pkg{
        .name = "clap",
        .path = "clap/clap.zig",
    };

    pub const hyperia = Pkg{
        .name = "hyperia",
        .path = "hyperia.zig",
        .dependencies = &[_]Pkg{
            zap,
        },
    };
};

pub fn register(step: *std.build.LibExeObjStep) void {
    step.linkLibC();

    step.addPackage(pkgs.zap);
    step.addPackage(pkgs.clap);
    step.addPackage(pkgs.hyperia);

    @import("picohttp/picohttp.zig").addTo(step, "picohttp");
    @import("blake3/blake3.zig").addTo(step, "blake3");
}

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const test_step = b.step("test", "Run library tests.");
    const test_filter = b.option([]const u8, "test-filter", "Test filter");
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;

    const file = b.addTest("hyperia.zig");
    file.sanitize_thread = sanitize_thread;
    file.setTarget(target);
    file.setBuildMode(mode);
    register(file);

    if (test_filter != null) {
        file.setFilter(test_filter.?);
    }

    test_step.dependOn(&file.step);

    inline for (.{
        "example_tcp_client",
        "example_tcp_server",
        "example_http_server",
    }) |example_name| {
        const example_step = b.step(example_name, "Example " ++ example_name ++ ".zig");

        const exe = b.addExecutable(example_name, example_name ++ ".zig");
        exe.sanitize_thread = sanitize_thread;
        exe.setTarget(target);
        exe.setBuildMode(mode);
        register(exe);
        exe.install();

        const exe_run = exe.run();
        if (b.args) |args| exe_run.addArgs(args);

        example_step.dependOn(&exe_run.step);
    }
}
