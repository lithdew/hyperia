const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

const mem = std.mem;
const math = std.math;
const time = std.time;
const mpsc = hyperia.mpsc;
const testing = std.testing;

const assert = std.debug.assert;

const SpinLock = hyperia.sync.SpinLock;

const Timer = @This();

pub const Handle = struct {
    pub const DONE = 0;
    pub const CANCELLED = 1;

    event: mpsc.AsyncAutoResetEvent(usize) = .{},
    expires_at: usize = 0,

    pub fn start(self: *Timer.Handle, timer: *Timer, expires_at: usize) !void {
        self.event = .{};
        self.expires_at = expires_at;

        try timer.add(self);
    }

    pub fn cancel(self: *Timer, Handle, timer: *Timer) void {
        if (!timer.cancel(self)) return;

        if (self.event.set(CANCELLED)) |runnable| {
            hyperia.pool.schedule(.{}, runnable);
        }
    }

    pub fn wait(self: *Timer.Handle) bool {
        return self.event.wait() == DONE;
    }

    pub fn set(self: *Timer.Handle) ?*zap.Pool.Runnable {
        return self.event.set(DONE);
    }
};

lock: SpinLock = .{},
entries: std.PriorityQueue(*Timer.Handle),

pub fn init(allocator: *mem.Allocator) Timer {
    return Timer{
        .entries = std.PriorityQueue(*Timer.Handle).init(allocator, struct {
            fn lessThan(a: *Timer.Handle, b: *Timer.Handle) math.Order {
                return math.order(a.expires_at, b.expires_at);
            }
        }.lessThan),
    };
}

pub fn deinit(self: *Timer, allocator: *mem.Allocator) void {
    self.entries.deinit();
}

pub fn add(self: *Timer, handle: *Timer.Handle) !void {
    const held = self.lock.acquire();
    defer held.release();

    try self.entries.add(handle);
}

pub fn cancel(self: *Timer, handle: *Timer.Handle) bool {
    const held = self.lock.acquire();
    defer held.release();

    const i = mem.indexOfScalar(*Timer.Handle, self.entries.items, handle) orelse return false;
    assert(self.entries.removeIndex(i) == handle);

    return true;
}

pub fn delay(self: *Timer, current_time: usize) ?usize {
    const held = self.lock.acquire();
    defer held.release();

    const head = self.entries.peek() orelse return null;
    return math.sub(usize, head.expires_at, current_time) catch 0;
}

pub fn update(self: *Timer, current_time: usize, callback: anytype) void {
    const held = self.lock.acquire();
    defer held.release();

    while (true) {
        const head = self.entries.peek() orelse break;
        if (head.expires_at > current_time) break;

        callback.call(self.entries.remove());
    }
}

test {
    testing.refAllDecls(@This());
}

test "timer/async: add timers and execute them" {
    hyperia.init();
    defer hyperia.deinit();

    const allocator = testing.allocator;

    var timer = Timer.init(allocator);
    defer timer.deinit(allocator);

    var a: Timer.Handle = .{ .expires_at = @intCast(usize, time.milliTimestamp()) + 10 };
    var b: Timer.Handle = .{ .expires_at = @intCast(usize, time.milliTimestamp()) + 20 };
    var c: Timer.Handle = .{ .expires_at = @intCast(usize, time.milliTimestamp()) + 30 };

    try timer.add(&a);
    try timer.add(&b);
    try timer.add(&c);

    var fa = async a.wait();
    var fb = async b.wait();
    var fc = async c.wait();

    while (true) {
        time.sleep(timer.delay(@intCast(usize, time.milliTimestamp())) orelse break);

        var batch: zap.Pool.Batch = .{};
        defer while (batch.pop()) |runnable| runnable.run();

        timer.update(@intCast(usize, @intCast(usize, time.milliTimestamp())), struct {
            batch: *zap.Pool.Batch,

            pub fn call(self: @This(), handle: *Timer.Handle) void {
                self.batch.push(handle.set());
            }
        }{ .batch = &batch });
    }

    testing.expect(nosuspend await fa);
    testing.expect(nosuspend await fb);
    testing.expect(nosuspend await fc);
}

test "timer: add timers and update latest time" {
    const allocator = testing.allocator;

    var timer = Timer.init(allocator);
    defer timer.deinit(allocator);

    var a: Timer.Handle = .{ .expires_at = 10 };
    var b: Timer.Handle = .{ .expires_at = 20 };
    var c: Timer.Handle = .{ .expires_at = 30 };

    try timer.add(&a);
    try timer.add(&b);
    try timer.add(&c);

    timer.update(25, struct {
        fn call(handle: *Timer.Handle) void {
            return {};
        }
    });

    testing.expect(timer.delay(25) == c.expires_at - 25);
}
