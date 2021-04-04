const std = @import("std");
const zap = @import("zap");

const mem = std.mem;
const heap = std.heap;
const builtin = std.builtin;
const testing = std.testing;

const assert = std.debug.assert;

pub const mpsc = @import("mpsc.zig");
pub const mpmc = @import("mpmc.zig");
pub const oneshot = @import("oneshot.zig");

pub const ctrl_c = @import("ctrl_c.zig");
pub const select = @import("select.zig");

pub const ObjectPool = @import("object_pool.zig").ObjectPool;

pub const Reactor = @import("reactor.zig").Reactor;
pub const Socket = @import("socket.zig").Socket;
pub const AsyncSocket = @import("async_socket.zig").AsyncSocket;
pub const AsyncWaitGroup = @import("async_wait_group.zig").AsyncWaitGroup;
pub const AsyncWaitGroupAllocator = @import("async_wait_group_allocator.zig").AsyncWaitGroupAllocator;

pub const Timer = @import("time.zig").Timer;
pub const TimerQueue = @import("time.zig").Queue;

pub var gpa: heap.GeneralPurposeAllocator(.{}) = undefined;
pub var allocator: *mem.Allocator = undefined;

pub var pool: zap.Pool = undefined;

pub fn init() void {
    gpa = .{};
    if (builtin.link_libc) {
        gpa.backing_allocator = heap.c_allocator;
    }
    allocator = &gpa.allocator;

    pool = zap.Pool.init(.{ .max_threads = 1 });
}

pub fn deinit() void {
    pool.deinit();
    assert(!gpa.deinit());
}

test {
    testing.refAllDecls(@This());
}
