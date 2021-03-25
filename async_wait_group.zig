const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

const mpsc = hyperia.mpsc;
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

    state: usize = 0,
    event: mpsc.AsyncAutoResetEvent = .{},

    pub fn add(self: *Self, delta: usize) void {
        if (delta == 0) return;

        _ = @atomicRmw(usize, &self.state, .Add, delta, .Monotonic);
    }

    pub fn sub(self: *Self, delta: usize) void {
        if (delta == 0) return;
        if (@atomicRmw(usize, &self.state, .Sub, delta, .Release) - delta != 0) return;

        @fence(.Acquire);

        if (self.event.set()) |runnable| {
            hyperia.pool.schedule(.{}, runnable);
        }
    }

    pub fn wait(self: *Self) void {
        while (@atomicLoad(usize, &self.state, .Monotonic) != 0) {
            self.event.wait();
        }
    }
};

test {
    testing.refAllDecls(@This());
}
