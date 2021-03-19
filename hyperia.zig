const std = @import("std");
const zap = @import("zap");

const mem = std.mem;
const heap = std.heap;
const builtin = std.builtin;

const assert = std.debug.assert;

pub var gpa: heap.GeneralPurposeAllocator(.{}) = undefined;
pub var allocator: mem.Allocator = undefined;

pub var pool: zap.Pool = undefined;

pub fn init() void {
    gpa = .{};
    if (builtin.link_libc) {
        gpa.backing_allocator = heap.c_allocator;
    }

    pool = zap.Pool.init(.{});
}

pub fn deinit() void {
    pool.deinit();
    assert(gpa.deinit());
}
