const std = @import("std");
const hyperia = @import("hyperia.zig");

const os = std.os;
const mem = std.mem;

const oneshot = hyperia.oneshot;

var signal: oneshot.Signal = .{};

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
    hyperia.pool.schedule(.{}, signal.close());

    signal = .{};
}

pub fn wait() void {
    signal.wait();
}

pub fn cancel() void {
    hyperia.pool.schedule(.{}, signal.set());
}

fn handler(signum: c_int) callconv(.C) void {
    if (signum != os.SIGINT) return;
    hyperia.pool.schedule(.{}, signal.set());
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
