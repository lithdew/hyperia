const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

const testing = std.testing;

pub const Signal = struct {
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
    const CLOSED = 1;

    state: usize = EMPTY,

    pub fn wait(self: *Self) void {
        var node: Node = .{ .frame = @frame() };

        suspend {
            var state = @atomicLoad(usize, &self.state, .Monotonic);

            while (true) {
                const new_state = switch (state) {
                    EMPTY => update: {
                        node.next = null;
                        break :update @ptrToInt(&node);
                    },
                    CLOSED => {
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
    }

    pub fn close(self: *Self) zap.Pool.Batch {
        var batch: zap.Pool.Batch = .{};

        const state = @atomicRmw(usize, &self.state, .Xchg, CLOSED, .AcqRel);
        if (state == EMPTY or state == CLOSED) return batch;

        var it = @intToPtr(?*Node, state);
        while (it) |node| : (it = node.next) {
            batch.push(&node.runnable);
        }

        return batch;
    }

    pub fn set(self: *Self) zap.Pool.Batch {
        var batch: zap.Pool.Batch = .{};

        var state = @atomicLoad(usize, &self.state, .Monotonic);
        while (true) {
            const new_state = switch (state) {
                EMPTY, CLOSED => return batch,
                else => @as(usize, EMPTY),
            };

            state = @cmpxchgWeak(usize, &self.state, state, new_state, .Acquire, .Monotonic) orelse {
                var it = @intToPtr(?*Node, state);
                while (it) |node| : (it = node.next) {
                    batch.push(&node.runnable);
                }
                return batch;
            };
        }
    }
};

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
                var state = @atomicLoad(usize, &self.state, .Acquire);

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

                    state = @cmpxchgWeak(usize, &self.state, state, new_state, .Release, .Acquire) orelse break;
                }
            }

            return self.data;
        }

        pub fn set(self: *Self, data: T) void {
            const state = @atomicRmw(usize, &self.state, .Xchg, NOTIFIED, .AcqRel);
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

    channel.set({});

    nosuspend await a;
    nosuspend await b;
    nosuspend await c;
    nosuspend await d;

    testing.expect(channel.state == Channel(void).NOTIFIED);
}

test "oneshot/channel: stress test" {
    const Frame = struct {
        runnable: zap.Pool.Runnable = .{ .runFn = run },
        frame: anyframe,

        fn run(runnable: *zap.Pool.Runnable) void {
            const self = @fieldParentPtr(@This(), "runnable", runnable);
            resume self.frame;
        }
    };

    const Context = struct {
        channel: Channel(void) = .{},

        event: std.Thread.StaticResetEvent = .{},
        waiter_count: usize,
        setter_count: usize,

        fn runWaiter(self: *@This()) void {
            var frame: Frame = .{ .frame = @frame() };
            suspend hyperia.pool.schedule(.{}, &frame.runnable);

            self.channel.wait();
        }

        fn runSetter(self: *@This()) void {
            var frame: Frame = .{ .frame = @frame() };
            suspend hyperia.pool.schedule(.{}, &frame.runnable);

            self.channel.set({});
        }

        pub fn run(self: *@This()) !void {
            var frame: Frame = .{ .frame = @frame() };
            suspend hyperia.pool.schedule(.{}, &frame.runnable);

            var waiters = try testing.allocator.alloc(@Frame(@This().runWaiter), self.waiter_count);
            var setters = try testing.allocator.alloc(@Frame(@This().runSetter), self.setter_count);

            for (waiters) |*waiter| waiter.* = async self.runWaiter();
            for (setters) |*setter| setter.* = async self.runSetter();

            for (waiters) |*waiter| await waiter;
            for (setters) |*setter| await setter;

            suspend {
                testing.allocator.free(setters);
                testing.allocator.free(waiters);
                self.event.set();
            }
        }
    };

    const path = try std.fs.selfExePathAlloc(testing.allocator);
    defer testing.allocator.free(path);

    std.debug.print("{s}\n", .{path});

    hyperia.init();
    defer hyperia.deinit();

    const allocator = testing.allocator;

    var test_count: usize = 1000;
    var rand = std.rand.DefaultPrng.init(@intCast(u64, std.time.milliTimestamp()));

    while (test_count > 0) : (test_count -= 1) {
        const waiter_count = rand.random.intRangeAtMost(usize, 4, 10);
        const setter_count = rand.random.intRangeAtMost(usize, 4, 10);

        var ctx: Context = .{
            .waiter_count = waiter_count,
            .setter_count = setter_count,
        };

        var frame = async ctx.run();
        ctx.event.wait();
    }
}
