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
        const COMMITTED = 2;

        state: usize = EMPTY,
        data: T = undefined,

        pub fn wait(self: *Self) T {
            var node: Node = .{ .frame = @frame() };

            suspend {
                var state = @atomicLoad(usize, &self.state, .Acquire);

                while (true) {
                    const new_state = switch (state & 0b11) {
                        COMMITTED => {
                            hyperia.pool.schedule(.{}, &node.runnable);
                            break;
                        },
                        else => update: {
                            node.next = @intToPtr(?*Node, state & ~@as(usize, 0b11));
                            break :update @ptrToInt(&node) | (state & 0b11);
                        },
                    };

                    state = @cmpxchgWeak(
                        usize,
                        &self.state,
                        state,
                        new_state,
                        .Release,
                        .Acquire,
                    ) orelse break;
                }
            }

            return self.data;
        }

        pub fn get(self: *Self) ?T {
            if (@atomicLoad(usize, &self.state, .Acquire) != COMMITTED) {
                return null;
            }
            return self.data;
        }

        pub fn set(self: *Self) bool {
            var state = @atomicLoad(usize, &self.state, .Monotonic);

            const new_state = switch (state & 0b11) {
                NOTIFIED, COMMITTED => return false,
                else => state | NOTIFIED,
            };

            return @cmpxchgStrong(usize, &self.state, state, new_state, .Acquire, .Monotonic) == null;
        }

        pub fn reset(self: *Self) void {
            @atomicStore(usize, &self.state, EMPTY, .Monotonic);
        }

        pub fn commit(self: *Self, data: T) void {
            self.data = data;

            const state = @atomicRmw(usize, &self.state, .Xchg, COMMITTED, .AcqRel);
            if (state & 0b11 != NOTIFIED) unreachable;

            var batch: zap.Pool.Batch = .{};

            var it = @intToPtr(?*Node, state & ~@as(usize, 0b11));
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

    if (channel.set()) {
        channel.commit({});
    }

    nosuspend await a;
    nosuspend await b;
    nosuspend await c;
    nosuspend await d;

    testing.expect(channel.state == Channel(void).COMMITTED);
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

            if (self.channel.set()) {
                self.channel.commit({});
            }
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

    hyperia.init();
    defer hyperia.deinit();

    var test_count: usize = 1000;
    var rand = std.rand.DefaultPrng.init(0);

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
