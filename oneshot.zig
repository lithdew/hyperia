const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

const testing = std.testing;

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            next: ?*Node = null,
            runnable: zap.Pool.Runnable = .{ .runFn = run },
            frame: anyframe,

            pub fn run(runnable: *zap.Pool.Runnable) void {
                const self = @fieldParentPtr(Node, "runnable", runnable);
                resume self.frame;
            }
        };

        const EMPTY = 0;
        const NOTIFIED = 1;

        state: usize = EMPTY,
        data: T = undefined,

        pub fn wait(self: *Self) T {
            var node: Node = .{ .frame = @frame() };

            suspend {
                var state = @atomicLoad(usize, &self.state, .Monotonic);

                while (true) {
                    const new_state = switch (state) {
                        EMPTY => update: {
                            node.next = null;
                            break :update @ptrToInt(&node);
                        },
                        NOTIFIED => {
                            hyperia.pool.schedule(.{}, &node.runnable);
                            break;
                        },
                        else => update: {
                            node.next = @intToPtr(?*Node, state);
                            break :update @ptrToInt(&node);
                        },
                    };

                    state = @cmpxchgWeak(usize, &self.state, state, new_state, .Release, .Monotonic) orelse break;
                }
            }

            return self.data;
        }

        pub fn put(self: *Self, data: T) void {
            const state = @atomicRmw(usize, &self.state, .Xchg, NOTIFIED, .Acquire);
            if (state == EMPTY or state == NOTIFIED) return;

            self.data = data;

            var batch: zap.Pool.Batch = .{};

            var it = @intToPtr(?*Node, state);
            while (it) |node| : (it = node.next) {
                batch.push(&node.runnable);
            }

            hyperia.pool.schedule(.{}, batch);
        }
    };
}

test {
    testing.refAllDecls(@This());
}

test "oneshot/channel: multiple waiters" {
    hyperia.init();
    defer hyperia.deinit();

    var channel: Channel(void) = .{};

    var a = async channel.wait();
    var b = async channel.wait();
    var c = async channel.wait();
    var d = async channel.wait();

    channel.put({});

    nosuspend await a;
    nosuspend await b;
    nosuspend await c;
    nosuspend await d;

    testing.expect(channel.state == Channel(void).NOTIFIED);
}

test "oneshot/channel: stress test" {
    const Waiter = struct {
        lock: *std.Thread.Mutex,
        cond: *std.Thread.Condition,
        count: *usize,

        channel: *Channel(void),
        runnable: zap.Pool.Runnable = .{ .runFn = run },
        frame: @Frame(runAsync) = undefined,

        fn run(runnable: *zap.Pool.Runnable) void {
            const self = @fieldParentPtr(@This(), "runnable", runnable);
            self.frame = async self.runAsync();
        }

        fn runAsync(self: *@This()) void {
            self.channel.wait();

            suspend {
                const held = self.lock.acquire();
                defer held.release();

                self.count.* -= 1;
                self.cond.signal();
            }
        }
    };

    const Putter = struct {
        lock: *std.Thread.Mutex,
        cond: *std.Thread.Condition,
        count: *usize,

        channel: *Channel(void),
        runnable: zap.Pool.Runnable = .{ .runFn = run },
        frame: @Frame(runAsync) = undefined,

        fn run(runnable: *zap.Pool.Runnable) void {
            const self = @fieldParentPtr(@This(), "runnable", runnable);
            self.frame = async self.runAsync();
        }

        fn runAsync(self: *@This()) void {
            self.channel.put({});

            suspend {
                const held = self.lock.acquire();
                defer held.release();

                self.count.* -= 1;
                self.cond.signal();
            }
        }
    };

    hyperia.init();
    defer hyperia.deinit();

    const allocator = testing.allocator;

    var test_count: usize = 10_000;
    var rand = std.rand.DefaultPrng.init(0);

    while (test_count > 0) : (test_count -= 1) {
        var lock: std.Thread.Mutex = .{};
        var cond: std.Thread.Condition = .{};
        var count: usize = 0;

        var waiters = std.ArrayList(Waiter).init(allocator);
        defer waiters.deinit();

        var putters = std.ArrayList(Putter).init(allocator);
        defer putters.deinit();

        const waiter_count = rand.random.intRangeAtMost(usize, 4, 10);
        const putter_count = rand.random.intRangeAtMost(usize, 4, 10);

        count = waiter_count + putter_count;

        var batch: zap.Pool.Batch = .{};
        var channel: Channel(void) = .{};

        var i: usize = 0;
        while (i < waiter_count) : (i += 1) {
            try waiters.append(Waiter{
                .lock = &lock,
                .cond = &cond,
                .count = &count,
                .channel = &channel,
            });
        }

        var j: usize = 0;
        while (j < putter_count) : (j += 1) {
            try putters.append(Putter{
                .lock = &lock,
                .cond = &cond,
                .count = &count,
                .channel = &channel,
            });
        }

        for (waiters.items) |*waiter| batch.push(&waiter.runnable);
        for (putters.items) |*putter| batch.push(&putter.runnable);

        hyperia.pool.schedule(.{}, batch);

        const held = lock.acquire();
        defer held.release();

        while (count != 0) cond.wait(&lock);
    }
}
