const std = @import("std");

const mem = std.mem;
const builtin = std.builtin;
const testing = std.testing;

const assert = std.debug.assert;

pub const cache_line_length = switch (builtin.cpu.arch) {
    .x86_64, .aarch64, .powerpc64 => 128,
    .arm, .mips, .mips64, .riscv64 => 32,
    .s390x => 256,
    else => 64,
};

pub fn Queue(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();

        entries: [capacity]T align(cache_line_length) = undefined,
        enqueue_pos: usize align(cache_line_length) = 0,
        dequeue_pos: usize align(cache_line_length) = 0,

        pub fn push(self: *Self, item: T) bool {
            const head = self.enqueue_pos;
            const tail = @atomicLoad(usize, &self.dequeue_pos, .Acquire);
            if (head +% 1 -% tail > capacity) {
                return false;
            }
            self.entries[head & (capacity - 1)] = item;
            @atomicStore(usize, &self.enqueue_pos, head +% 1, .Release);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const tail = self.dequeue_pos;
            const head = @atomicLoad(usize, &self.enqueue_pos, .Acquire);
            if (tail -% head == 0) {
                return null;
            }
            const popped = self.entries[tail & (capacity - 1)];
            @atomicStore(usize, &self.dequeue_pos, tail +% 1, .Release);
            return popped;
        }
    };
}

test "queue" {
    var queue: Queue(u64, 4) = .{};

    var i: usize = 0;
    while (i < 4) : (i += 1) testing.expect(queue.push(i));
    testing.expect(!queue.push(5));
    testing.expect(!queue.push(6));
    testing.expect(!queue.push(7));
    testing.expect(!queue.push(8));

    var j: usize = 0;
    while (j < 4) : (j += 1) testing.expect(queue.pop().? == j);
    testing.expect(queue.pop() == null);
    testing.expect(queue.pop() == null);
    testing.expect(queue.pop() == null);
    testing.expect(queue.pop() == null);
}
