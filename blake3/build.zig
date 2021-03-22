const std = @import("std");
const Pkg = std.build.Pkg;
const Builder = std.build.Builder;

pub fn register(step: *std.build.LibExeObjStep) void {
    step.linkLibC();

    step.addPackage(pkgs.zap);
    step.addPackage(pkgs.hyperia);

    @import("picohttp/picohttp.zig").addTo(step, "picohttp");
}

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const test_step = b.step("test", "Run library tests.");
    const test_filter = b.option([]const u8, "test-filter", "Test filter");

    const file = b.addTest("blake3.zig");
    file.setTarget(target);
    file.setBuildMode(mode);

    @import("blake3.zig").addTo(file, ".");

    if (test_filter != null) {
        file.setFilter(test_filter.?);
    }

    test_step.dependOn(&file.step);
}
