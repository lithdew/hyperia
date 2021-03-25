const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

const os = std.os;
const mem = std.mem;
const builtin = std.builtin;
const testing = std.testing;

pub const cache_line_length = switch (builtin.cpu.arch) {
    .x86_64, .aarch64, .powerpc64 => 128,
    .arm, .mips, .mips64, .riscv64 => 32,
    .s390x => 256,
    else => 64,
};

pub fn Queue(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            sequence: usize align(cache_line_length),
            item: T,
        };

        entries: [*]Entry align(cache_line_length),
        enqueue_pos: usize align(cache_line_length),
        dequeue_pos: usize align(cache_line_length),

        pub fn init(allocator: *mem.Allocator) !Self {
            const entries = try allocator.create([capacity]Entry);
            for (entries) |*entry, i| entry.sequence = i;

            return Self{
                .entries = entries,
                .enqueue_pos = 0,
                .dequeue_pos = 0,
            };
        }

        pub fn deinit(self: *Self, allocator: *mem.Allocator) void {
            allocator.destroy(@ptrCast(*const [capacity]Entry, self.entries));
        }

        pub fn tryPush(self: *Self, item: T) bool {
            var entry: *Entry = undefined;
            var pos = @atomicLoad(usize, &self.enqueue_pos, .Monotonic);
            while (true) : (os.sched_yield() catch {}) {
                entry = &self.entries[pos & (capacity - 1)];

                const seq = @atomicLoad(usize, &entry.sequence, .Acquire);
                const diff = seq -% pos;
                if (diff == 0) {
                    pos = @cmpxchgWeak(usize, &self.enqueue_pos, pos, pos +% 1, .Monotonic, .Monotonic) orelse {
                        break;
                    };
                } else if (diff < 0) {
                    return false;
                } else {
                    pos = @atomicLoad(usize, &self.enqueue_pos, .Monotonic);
                }
            }
            entry.item = item;
            @atomicStore(usize, &entry.sequence, pos +% 1, .Release);
            return true;
        }

        pub fn tryPop(self: *Self) ?T {
            var entry: *Entry = undefined;
            var pos = @atomicLoad(usize, &self.dequeue_pos, .Monotonic);
            while (true) : (os.sched_yield() catch {}) {
                entry = &self.entries[pos & (capacity - 1)];

                const seq = @atomicLoad(usize, &entry.sequence, .Acquire);
                const diff = seq -% (pos +% 1);
                if (diff == 0) {
                    pos = @cmpxchgWeak(usize, &self.dequeue_pos, pos, pos +% 1, .Monotonic, .Monotonic) orelse {
                        break;
                    };
                } else if (diff < 0) {
                    return null;
                } else {
                    pos = @atomicLoad(usize, &self.dequeue_pos, .Monotonic);
                }
            }
            defer @atomicStore(usize, &entry.sequence, pos +% (capacity - 1) +% 1, .Release);
            return entry.item;
        }
    };
}

test "mpmc/queue: push and pop 60,000 u64s with 4 producers and 4 consumers" {
    const NUM_ITEMS = 60_000;
    const NUM_PRODUCERS = 4;
    const NUM_CONSUMERS = 4;

    const TestQueue = Queue(u64, 2048);

    const Context = struct {
        queue: *TestQueue,

        fn runProducer(self: @This()) !void {
            var i: usize = 0;
            while (i < NUM_ITEMS / NUM_PRODUCERS) : (i += 1) {
                while (true) {
                    if (self.queue.tryPush(@intCast(u64, i))) {
                        break;
                    }
                }
            }
        }

        fn runConsumer(self: @This()) !void {
            var i: usize = 0;
            while (i < NUM_ITEMS / NUM_CONSUMERS) : (i += 1) {
                while (true) {
                    if (self.queue.tryPop() != null) {
                        break;
                    }
                }
            }
        }
    };

    const allocator = testing.allocator;

    var queue = try TestQueue.init(allocator);
    defer queue.deinit(allocator);

    var producers: [NUM_PRODUCERS]*std.Thread = undefined;
    defer for (producers) |producer| producer.wait();

    var consumers: [NUM_CONSUMERS]*std.Thread = undefined;
    defer for (consumers) |consumer| consumer.wait();

    for (consumers) |*consumer| consumer.* = try std.Thread.spawn(Context.runConsumer, Context{ .queue = &queue });
    for (producers) |*producer| producer.* = try std.Thread.spawn(Context.runProducer, Context{ .queue = &queue });
}
