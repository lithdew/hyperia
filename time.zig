const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

const mem = std.mem;
const math = std.math;
const time = std.time;
const mpsc = hyperia.mpsc;
const testing = std.testing;

const assert = std.debug.assert;

pub const Timer = struct {
    pub const DONE = 0;
    pub const CANCELLED = 1;

    event: mpsc.AsyncAutoResetEvent(usize) = .{},
    expires_at: usize = 0,

    pub fn start(self: *Timer, queue: *Queue, expires_at: usize) !void {
        self.event = .{};
        self.expires_at = expires_at;

        try queue.add(self);
    }

    pub fn cancel(self: *Timer, queue: *Queue) void {
        if (!queue.cancel(self)) return;

        if (self.event.set(CANCELLED)) |runnable| {
            hyperia.pool.schedule(.{}, runnable);
        }
    }

    pub fn wait(self: *Timer) bool {
        return self.event.wait() == DONE;
    }

    pub fn set(self: *Timer) ?*zap.Pool.Runnable {
        return self.event.set(DONE);
    }
};

pub const Queue = struct {
    const Self = @This();

    lock: std.Thread.Mutex = .{},
    entries: std.PriorityQueue(*Timer) = .{},

    pub fn init(allocator: *mem.Allocator) Self {
        return Self{
            .entries = std.PriorityQueue(*Timer).init(allocator, struct {
                fn lessThan(a: *Timer, b: *Timer) math.Order {
                    return math.order(a.expires_at, b.expires_at);
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

    pub fn cancel(self: *Self, timer: *Timer) bool {
        const held = self.lock.acquire();
        defer held.release();

        const i = mem.indexOfScalar(*Timer, self.entries.items, timer) orelse return false;
        assert(self.entries.removeIndex(i) == timer);

        return true;
    }

    pub fn delay(self: *Self, current_time: usize) ?usize {
        const held = self.lock.acquire();
        defer held.release();

        const head = self.entries.peek() orelse return null;
        return math.sub(usize, head.expires_at, current_time) catch 0;
    }

    pub fn update(self: *Self, current_time: usize, callback: anytype) void {
        const held = self.lock.acquire();
        defer held.release();

        while (true) {
            const head = self.entries.peek() orelse break;
            if (head.expires_at > current_time) break;

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

    var a: Timer = .{ .expires_at = @intCast(usize, time.milliTimestamp()) + 10 };
    var b: Timer = .{ .expires_at = @intCast(usize, time.milliTimestamp()) + 20 };
    var c: Timer = .{ .expires_at = @intCast(usize, time.milliTimestamp()) + 30 };

    try queue.add(&a);
    try queue.add(&b);
    try queue.add(&c);

    var fa = async a.wait();
    var fb = async b.wait();
    var fc = async c.wait();

    while (true) {
        const Processor = struct {
            batch: zap.Pool.Batch = .{},

            fn call(self: *@This(), timer: *Timer) void {
                self.batch.push(timer.set());
            }
        };

        time.sleep(queue.delay(@intCast(usize, time.milliTimestamp())) orelse break);

        var processor: Processor = .{};
        defer while (processor.batch.pop()) |runnable| runnable.run();

        queue.update(@intCast(usize, @intCast(usize, time.milliTimestamp())), &processor);
    }

    testing.expect(nosuspend await fa);
    testing.expect(nosuspend await fb);
    testing.expect(nosuspend await fc);
}

test "timer: add timers and update latest time" {
    const allocator = testing.allocator;

    var queue = Queue.init(allocator);
    defer queue.deinit(allocator);

    var a: Timer = .{ .expires_at = 10 };
    var b: Timer = .{ .expires_at = 20 };
    var c: Timer = .{ .expires_at = 30 };

    try queue.add(&a);
    try queue.add(&b);
    try queue.add(&c);

    queue.update(25, struct {
        fn call(timer: *Timer) void {}
    });

    testing.expect(queue.delay(25) == c.expires_at - 25);
}
