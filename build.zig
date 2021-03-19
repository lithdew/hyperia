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

    inline for (.{
        "hyperia.zig",
        "object_pool.zig",
        "reactor.zig",
        "socket.zig",
        "async_socket.zig",
        "async_parker.zig",
    }) |file_path| {
        const file = b.addTest(file_path);
        file.setTarget(target);
        file.setBuildMode(mode);
        file.addPackage(pkgs.zap);
        file.addPackage(pkgs.hyperia);
        file.linkLibC();

        test_step.dependOn(&file.step);
    }
}
