const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

const testing = std.testing;

pub const Channel = struct {
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

    pub fn wait(self: *Self) void {
        var node: Node = .{ .frame = @frame() };

        suspend {
            var state = @atomicLoad(usize, &self.state, .Monotonic);

            while (true) {
                const new_state = switch (state) {
                    EMPTY => @ptrToInt(&node),
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
    }

    pub fn put(self: *Self) void {
        const state = @atomicRmw(usize, &self.state, .Xchg, NOTIFIED, .AcqRel);
        if (state == EMPTY or state == NOTIFIED) return;

        var it = @intToPtr(?*Node, state);
        while (it) |node| : (it = node.next) {
            hyperia.pool.schedule(.{}, &node.runnable);
        }
    }
};

test {
    testing.refAllDecls(@This());
}

test "oneshot/channel: multiple waiters" {
    var channel: Channel = .{};

    var a = async channel.wait();
    var b = async channel.wait();
    var c = async channel.wait();
    var d = async channel.wait();

    channel.put();

    nosuspend await a;
    nosuspend await b;
    nosuspend await c;
    nosuspend await d;

    testing.expect(channel.state == Channel.NOTIFIED);
}
