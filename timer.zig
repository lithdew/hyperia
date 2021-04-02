const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

const mem = std.mem;
const time = std.time;
const mpsc = hyperia.mpsc;
const testing = std.testing;

pub const Queue = struct {
    const Timer = struct {
        pub const DONE = 0;
        pub const CANCELLED = 1;

        event: mpsc.AsyncAutoResetEvent(usize) = .{},
        expires_at: usize,

        pub fn cancel(self: *Timer) ?*zap.Pool.Runnable {
            return self.event.set(CANCELLED);
        }

        pub fn wait(self: *Timer) bool {
            return self.event.wait() == DONE;
        }

        pub fn set(self: *Timer) ?*zap.Pool.Runnable {
            return self.event.set(DONE);
        }
    };

    const Self = @This();

    lock: std.Thread.Mutex = .{},
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
        const held = self.lock.acquire();
        defer held.release();

        try self.entries.add(timer);
    }

    pub fn update(self: *Self, current_time: usize, callback: anytype) ?usize {
        const held = self.lock.acquire();
        defer held.release();

        while (true) {
            const head = self.entries.peek() orelse return null;
            if (head.expires_at > current_time) return head.expires_at - current_time;

            callback.call(self.entries.remove());
        }
    }
};

test {
    testing.refAllDecls(@This());
}

test "timer/async: add timers and execute them" {
    hyperia.init();
    defer hyperia.deinit();

    const allocator = testing.allocator;

    var queue = Queue.init(allocator);
    defer queue.deinit(allocator);

    var a: Queue.Timer = .{ .expires_at = @intCast(usize, time.milliTimestamp()) + 10 };
    var b: Queue.Timer = .{ .expires_at = @intCast(usize, time.milliTimestamp()) + 20 };
    var c: Queue.Timer = .{ .expires_at = @intCast(usize, time.milliTimestamp()) + 30 };

    try queue.add(&a);
    try queue.add(&b);
    try queue.add(&c);

    var fa = async a.wait();
    var fb = async b.wait();
    var fc = async c.wait();

    while (true) {
        const Processor = struct {
            batch: zap.Pool.Batch = .{},

            fn call(self: *@This(), timer: *Queue.Timer) void {
                self.batch.push(timer.set());
            }
        };

        const delay = update: {
            var processor: Processor = .{};
            defer while (processor.batch.pop()) |runnable| runnable.run();

            break :update queue.update(@intCast(usize, time.milliTimestamp()), &processor);
        };

        time.sleep(delay orelse break);
    }

    testing.expect(nosuspend await fa);
    testing.expect(nosuspend await fb);
    testing.expect(nosuspend await fc);
}

test "timer: add timers and update latest time" {
    const allocator = testing.allocator;

    var queue = Queue.init(allocator);
    defer queue.deinit(allocator);

    var a: Queue.Timer = .{ .expires_at = 10 };
    var b: Queue.Timer = .{ .expires_at = 20 };
    var c: Queue.Timer = .{ .expires_at = 30 };

    try queue.add(&a);
    try queue.add(&b);
    try queue.add(&c);

    const maybe_delay = queue.update(25, struct {
        fn call(timer: *Queue.Timer) void {}
    });

    testing.expect(maybe_delay == c.expires_at - 25);
}
