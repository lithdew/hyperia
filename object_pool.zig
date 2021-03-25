const std = @import("std");
const hyperia = @import("hyperia.zig");

const mem = std.mem;
const mpmc = hyperia.mpmc;
const testing = std.testing;

pub fn ObjectPool(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();

        queue: mpmc.Queue(*T, capacity),
        head: [*]T,

        pub fn init(allocator: *mem.Allocator) !Self {
            var queue = try mpmc.Queue(*T, capacity).init(allocator);
            errdefer queue.deinit(allocator);

            const items = try allocator.create([capacity]T);
            errdefer allocator.destroy(items);

            for (items) |*item| if (!queue.tryPush(item)) unreachable;

            return Self{ .queue = queue, .head = items };
        }

        pub fn deinit(self: *Self, allocator: *mem.Allocator) void {
            allocator.destroy(@ptrCast(*const [capacity]T, self.head));
            self.queue.deinit(allocator);
        }

        pub fn acquire(self: *Self, allocator: *mem.Allocator) !*T {
            if (self.queue.tryPop()) |item| {
                return item;
            }
            return try allocator.create(T);
        }

        pub fn release(self: *Self, allocator: *mem.Allocator, item: *T) void {
            if (@ptrToInt(item) >= @ptrToInt(self.head) and @ptrToInt(item) <= @ptrToInt(self.head + capacity - 1)) {
                while (true) {
                    if (self.queue.tryPush(item)) {
                        break;
                    }
                }
                return;
            }
            allocator.destroy(item);
        }
    };
}

test {
    testing.refAllDecls(ObjectPool(u8, 16));
}

test "object_pool: test invariants" {
    const allocator = testing.allocator;

    var pool = try ObjectPool(u8, 2).init(allocator);
    defer pool.deinit(allocator);

    const a = try pool.acquire(allocator);
    const b = try pool.acquire(allocator);
    const c = try pool.acquire(allocator);
    pool.release(allocator, c);
    pool.release(allocator, b);
    pool.release(allocator, a);
}
