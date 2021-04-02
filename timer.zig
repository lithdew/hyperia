const std = @import("std");
const hyperia = @import("hyperia.zig");

const mem = std.mem;
const mpsc = hyperia.mpsc;
const testing = std.testing;

pub const Queue = struct {
    const Timer = struct {
        pub const DONE = 0;
        pub const CANCELLED = 1;

        event: mpsc.AsyncAutoResetEvent(usize) = .{},
        expires_at: usize,

        pub fn cancel(self: *Timer) void {
            self.event.set(CANCELLED);
        }

        pub fn wait(self: *Timer) bool {
            return self.event.wait() == DONE;
        }

        pub fn set(self: *Timer, now: usize) bool {
            if (self.expires_at > now) return false;

            self.event.set(DONE);
            return true;
        }
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

test "timer: add timers and update latest time" {
    var a: Queue.Timer = .{ .expires_at = 10 };
    var b: Queue.Timer = .{ .expires_at = 20 };
    var c: Queue.Timer = .{ .expires_at = 30 };

    const allocator = testing.allocator;

    var queue = Queue.init(allocator);
    defer queue.deinit(allocator);

    try queue.add(&a);
    try queue.add(&b);
    try queue.add(&c);

    queue.update(25, struct {
        fn call(timer: *Queue.Timer) void {
            std.debug.print("Timer {} has expired!\n", .{timer});
        }
    });
}
