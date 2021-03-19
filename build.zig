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
};

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const test_step = b.step("test", "Run library tests.");
    const test_filter = b.option([]const u8, "test-filter", "Test filter");

    const file = b.addTest("hyperia.zig");
    file.setTarget(target);
    file.setBuildMode(mode);
    file.addPackage(pkgs.zap);
    file.addPackage(pkgs.hyperia);
    file.linkLibC();

    if (test_filter != null) {
        file.setFilter(test_filter.?);
    }

    test_step.dependOn(&file.step);
}
