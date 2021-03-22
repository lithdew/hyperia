const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

const testing = std.testing;

pub const AsyncWaitGroup = struct {
    const Self = @This();

    const Node = struct {
        runnable: zap.Pool.Runnable = .{ .runFn = run },
        frame: anyframe,

        pub fn run(runnable: *zap.Pool.Runnable) void {
            const self = @fieldParentPtr(Node, "runnable", runnable);
            resume self.frame;
        }
    };

    lock: std.Thread.Mutex = .{},
    waiter: ?*Node = null,
    state: usize = 0,

    pub fn add(self: *Self, delta: usize) void {
        if (delta == 0) return;

        const held = self.lock.acquire();
        defer held.release();

        self.state += delta;
    }

    pub fn sub(self: *Self, delta: usize) void {
        if (delta == 0) return;

        const held = self.lock.acquire();
        defer held.release();

        self.state -= delta;
        if (self.state != 0) {
            return;
        }

        const waiter = self.waiter orelse return;
        self.waiter = null;

        hyperia.pool.schedule(.{}, &waiter.runnable);
    }

    pub fn wait(self: *Self) void {
        const held = self.lock.acquire();
        if (self.state == 0) {
            held.release();
        } else {
            suspend {
                var waiter: Node = .{ .frame = @frame() };
                self.waiter = &waiter;
                held.release();
            }
        }
    }
};

test {
    testing.refAllDecls(@This());
}
