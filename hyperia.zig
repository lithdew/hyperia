const std = @import("std");
const zap = @import("zap");

const mem = std.mem;
const heap = std.heap;
const builtin = std.builtin;
const testing = std.testing;

const assert = std.debug.assert;

pub const mpsc = @import("mpsc.zig");
pub const timer = @import("timer.zig");

pub const ObjectPool = @import("object_pool.zig").ObjectPool;

pub const Reactor = @import("reactor.zig").Reactor;
pub const Socket = @import("socket.zig").Socket;
pub const AsyncParker = @import("async_parker.zig").AsyncParker;
pub const AsyncSocket = @import("async_socket.zig").AsyncSocket;
pub const AsyncEvent = @import("async_event.zig").AsyncEvent;
pub const AsyncAutoResetEvent = @import("async_event.zig").AsyncAutoResetEvent;

pub var gpa: heap.GeneralPurposeAllocator(.{}) = undefined;
pub var allocator: *mem.Allocator = undefined;

pub var pool: zap.Pool = undefined;

pub fn init() void {
    gpa = .{};
    if (builtin.link_libc) {
        gpa.backing_allocator = heap.c_allocator;
    }
    allocator = &gpa.allocator;

    pool = zap.Pool.init(.{});
}

pub fn deinit() void {
    pool.deinit();
    assert(!gpa.deinit());
}

test {
    testing.refAllDecls(@This());
}
