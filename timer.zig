const std = @import("std");

const mem = std.mem;
const testing = std.testing;

pub fn Queue(comptime T: type) type {
    return struct {
        const Timer = struct {
            expires_at: usize,
            item: T,
        };

        const Self = @This();

        entries: std.PriorityQueue(*Timer) = .{},

        pub fn init(allocator: *mem.Allocator) Self {
            return Self{
                .entries = std.PriorityQueue(*Timer).init(allocator, struct {
                    fn lessThan(a: *Timer, b: *Timer) bool {
                        return a.expires_at < b.expires_at;
                    }
                }.lessThan),
            };
        }

        pub fn deinit(self: *Self, allocator: *mem.Allocator) void {
            self.entries.deinit();
        }

        pub fn add(self: *Self, timer: *Timer) !void {
            try self.entries.add(timer);
        }

        pub fn peek(self: *Self) ?*Timer {
            return self.entries.peek();
        }

        pub fn pop(self: *Self) *Timer {
            return self.entries.remove();
        }

        pub fn update(self: *Self, current_time: usize, callback: anytype) void {
            while (true) {
                const head = self.entries.peek() orelse return;
                if (head.expires_at > current_time) return;

                callback.call(self.entries.remove());
            }
        }
    };
}

test "timer: add timers and update latest time" {
    const TestQueue = Queue(usize);

    var a: TestQueue.Timer = .{ .expires_at = 10, .item = 0 };
    var b: TestQueue.Timer = .{ .expires_at = 20, .item = 1 };
    var c: TestQueue.Timer = .{ .expires_at = 30, .item = 2 };

    const allocator = testing.allocator;

    var queue = TestQueue.init(allocator);
    defer queue.deinit(allocator);

    try queue.add(&a);
    try queue.add(&b);
    try queue.add(&c);

    queue.update(25, struct {
        fn call(timer: *TestQueue.Timer) void {
            std.debug.print("Timer {} has expired!\n", .{timer});
        }
    });
}
