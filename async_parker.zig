const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

const testing = std.testing;

pub const AsyncParker = struct {
    pub const Error = error{Cancelled};

    const EMPTY: usize = 0;
    const NOTIFIED: usize = 1;
    const CLOSED: usize = 2;

    const Self = @This();

    const Node = struct {
        runnable: zap.Pool.Runnable = .{ .runFn = run },
        frame: anyframe,
        cancelled: bool = false,
        next: ?*Node = null,

        pub fn run(runnable: *zap.Pool.Runnable) void {
            const self = @fieldParentPtr(Node, "runnable", runnable);
            resume self.frame;
        }
    };

    state: usize = EMPTY,

    pub fn wait(self: *Self) Error!void {
        var node: Node = .{ .frame = @frame() };

        suspend {
            var state = @atomicLoad(usize, &self.state, .Monotonic);

            while (true) {
                const new_state = switch (state) {
                    EMPTY => @ptrToInt(&node),
                    NOTIFIED => EMPTY,
                    CLOSED => {
                        node.cancelled = true;
                        hyperia.pool.schedule(.{}, &node.runnable);
                        break;
                    },
                    else => unreachable,
                };

                state = @cmpxchgWeak(usize, &self.state, state, new_state, .Release, .Monotonic) orelse {
                    if (state == NOTIFIED) {
                        hyperia.pool.schedule(.{}, &node.runnable);
                    }
                    break;
                };
            }
        }

        if (node.cancelled) {
            return error.Cancelled;
        }
    }

    pub fn cancel(self: *Self) ?*zap.Pool.Runnable {
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            const new_state = switch (state) {
                EMPTY, NOTIFIED, CLOSED => return null,
                else => EMPTY,
            };

            state = @cmpxchgWeak(usize, &self.state, state, new_state, .Acquire, .Monotonic) orelse {
                const node = @intToPtr(*Node, state);
                node.cancelled = true;
                return &node.runnable;
            };
        }
    }

    pub fn notify(self: *Self) ?*zap.Pool.Runnable {
        var state = @atomicLoad(usize, &self.state, .Monotonic);

        while (true) {
            const new_state = switch (state) {
                EMPTY => NOTIFIED,
                NOTIFIED, CLOSED => return null,
                else => EMPTY,
            };

            state = @cmpxchgWeak(usize, &self.state, state, new_state, .Acquire, .Monotonic) orelse {
                if (state == EMPTY) return null;
                const node = @intToPtr(*Node, state);
                return &node.runnable;
            };
        }
    }

    pub fn close(self: *Self) ?*zap.Pool.Runnable {
        switch (@atomicRmw(usize, &self.state, .Xchg, CLOSED, .AcqRel)) {
            EMPTY, NOTIFIED, CLOSED => return null,
            else => |state| {
                const node = @intToPtr(*Node, state);
                node.cancelled = true;
                return &node.runnable;
            },
        }
    }
};

test {
    testing.refAllDecls(@This());
}
