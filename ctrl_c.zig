const std = @import("std");
const hyperia = @import("hyperia.zig");

const os = std.os;
const mem = std.mem;
const mpmc = hyperia.mpmc;

var event: mpmc.AsyncAutoResetEvent = .{};

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
        .flags = 0,
    };

    os.sigaction(os.SIGINT, &sigaction, &last_sigaction);
}

pub fn deinit() void {
    os.sigaction(os.SIGINT, &last_sigaction, null);
    cancel();
}

pub fn wait() void {
    event.wait();
}

pub fn cancel() void {
    while (true) {
        var batch = event.set();
        if (batch.isEmpty()) break;
        hyperia.pool.schedule(.{}, batch);
    }
}

fn handler(signum: c_int) callconv(.C) void {
    if (signum != os.SIGINT) return;

    while (true) {
        var batch = event.set();
        if (batch.isEmpty()) break;
        hyperia.pool.schedule(.{}, batch);
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
