const std = @import("std");
const hyperia = @import("hyperia.zig");

const SpinLock = hyperia.sync.SpinLock;

const math = std.math;
const time = std.time;
const testing = std.testing;

pub const Options = struct {
    // max_concurrent_attempts: usize, // TODO(kenta): use a cancellable semaphore to limit max number of concurrent attempts
    failure_threshold: usize,
    reset_timeout: usize,
};

pub fn CircuitBreaker(comptime opts: Options) type {
    return struct {
        const Self = @This();

        pub const State = enum {
            closed,
            open,
            half_open,
        };

        lock: SpinLock = .{},
        failure_count: usize = 0,
        last_failure_time: usize = 0,

        pub fn init(state: State) Self {
            return switch (state) {
                .closed => .{},
                .half_open => .{ .failure_count = math.maxInt(usize) },
                .open => .{ .failure_count = math.maxInt(usize), .last_failure_time = math.maxInt(usize) },
            };
        }

        pub fn run(self: *Self, current_time: usize, closure: anytype) !void {
            switch (self.query()) {
                .closed, .half_open => {
                    closure.call() catch {
                        self.reportFailure(current_time);
                        return error.Failed;
                    };

                    self.reportSuccess();
                },
                .open => return error.Broken,
            }
        }

        pub fn query(self: *Self, current_time: usize) State {
            const held = self.lock.acquire();
            defer held.release();

            if (self.failure_count >= opts.failure_threshold) {
                if (math.sub(usize, current_time, self.last_failure_time) catch 0 <= opts.reset_timeout) {
                    return .open;
                }
                return .half_open;
            }

            return .closed;
        }

        pub fn reportFailure(self: *Self, current_time: usize) void {
            const held = self.lock.acquire();
            defer held.release();

            self.failure_count = math.add(usize, self.failure_count, 1) catch opts.failure_threshold;
            self.last_failure_time = current_time;
        }

        pub fn reportSuccess(self: *Self) void {
            const held = self.lock.acquire();
            defer held.release();

            self.failure_count = 0;
            self.last_failure_time = 0;
        }
    };
}

test {
    testing.refAllDecls(CircuitBreaker(.{ .failure_threshold = 10, .reset_timeout = 1000 }));
}

test "circuit_breaker: init and query state" {
    const TestBreaker = CircuitBreaker(.{ .failure_threshold = 10, .reset_timeout = 1000 });

    const current_time = @intCast(usize, time.milliTimestamp());
    testing.expect(TestBreaker.init(.open).query(current_time) == .open);
    testing.expect(TestBreaker.init(.closed).query(current_time) == .closed);
    testing.expect(TestBreaker.init(.half_open).query(current_time) == .half_open);
}
