const std = @import("std");
const hyperia = @import("hyperia.zig");

const os = std.os;
const mem = std.mem;

const AsyncParker = hyperia.AsyncParker;

var parker: AsyncParker = .{};

var last_sigaction: os.Sigaction = .{
    .handler = .{ .handler = null },
    .mask = mem.zeroes(os.sigset_t),
    .flags = 0,
};

pub fn init() void {
    var mask = mem.zeroes(os.sigset_t);
    os.linux.sigaddset(&mask, os.SIGINT);

    const sigaction = os.Sigaction{
        .handler = .{ .handler = handler },
        .mask = mask,
        .flags = os.SA_SIGINFO,
    };

    os.sigaction(os.SIGINT, &sigaction, &last_sigaction);
}

pub fn deinit() void {
    os.sigaction(os.SIGINT, &last_sigaction, null);

    if (parker.close()) |runnable| {
        hyperia.pool.schedule(.{}, runnable);
    }

    parker = .{};
}

pub fn wait() void {
    parker.wait() catch {};
}

fn handler(signal: c_int) callconv(.C) void {
    if (signal != os.SIGINT) return;

    if (parker.notify()) |runnable| {
        hyperia.pool.schedule(.{}, runnable);
    }
}

test "ctrl_c: manually raise ctrl+c event" {
    hyperia.init();
    defer hyperia.deinit();

    init();
    defer deinit();

    var frame = async wait();
    try os.raise(os.SIGINT);
    nosuspend await frame;
}
