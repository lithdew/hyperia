const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

const mem = std.mem;
const mpsc = hyperia.mpsc;
const builtin = std.builtin;
const testing = std.testing;

const assert = std.debug.assert;

pub const cache_line_length = switch (builtin.cpu.arch) {
    .x86_64, .aarch64, .powerpc64 => 128,
    .arm, .mips, .mips64, .riscv64 => 32,
    .s390x => 256,
    else => 64,
};

pub fn AsyncQueue(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();

        queue: Queue(T, capacity) = .{},
        closed: bool = false,
        producer_event: mpsc.AsyncAutoResetEvent(void) = .{},
        consumer_event: mpsc.AsyncAutoResetEvent(void) = .{},

        pub fn close(self: *Self) void {
            @atomicStore(bool, &self.closed, true, .Monotonic);

            while (true) {
                var batch: zap.Pool.Batch = .{};
                batch.push(self.producer_event.set());
                batch.push(self.consumer_event.set());
                if (batch.isEmpty()) break;
                hyperia.pool.schedule(.{}, batch);
            }
        }

        pub fn push(self: *Self, item: T) bool {
            while (!@atomicLoad(bool, &self.closed, .Monotonic)) {
                if (self.queue.push(item)) {
                    if (self.consumer_event.set()) |runnable| {
                        hyperia.pool.schedule(.{}, runnable);
                    }
                    return true;
                }
                self.producer_event.wait();
            }
            return false;
        }

        pub fn pop(self: *Self) ?T {
            while (!@atomicLoad(bool, &self.closed, .Monotonic)) {
                if (self.queue.pop()) |item| {
                    if (self.producer_event.set()) |runnable| {
                        hyperia.pool.schedule(.{}, runnable);
                    }
                    return item;
                }
                self.consumer_event.wait();
            }
            return null;
        }
    };
}

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

test {
    testing.refAllDecls(Queue(u64, 4));
    testing.refAllDecls(AsyncQueue(u64, 4));
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
