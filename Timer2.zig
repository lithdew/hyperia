const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

const os = std.os;
const mem = std.mem;
const math = std.math;
const time = std.time;
const testing = std.testing;

const assert = std.debug.assert;

const Reactor = hyperia.Reactor;

const Timer = @This();

pub const Handle = struct {
    pub const Error = error{Cancelled} || mem.Allocator.Error;

    parent: *Timer,
    expires_at: usize,
    result: ?Error = null,

    runnable: zap.Pool.Runnable = .{ .runFn = resumeWaiter },
    frame: anyframe = undefined,

    fn resumeWaiter(runnable: *zap.Pool.Runnable) void {
        const self = @fieldParentPtr(Timer.Handle, "runnable", runnable);
        resume self.frame;
    }

    pub fn cancel(self: *Timer.Handle) void {
        const i = mem.indexOfScalar(*Timer.Handle, self.parent.pending.items[0..self.parent.pending.len], self) orelse return;
        assert(self.parent.pending.removeIndex(i) == self);

        self.result = error.Cancelled;
        hyperia.pool.schedule(.{}, &self.runnable);
    }

    pub fn wait(self: *Timer.Handle) callconv(.Async) !void {
        suspend {
            self.frame = @frame();

            if (self.parent.pending.add(self)) {
                self.parent.event.post();
            } else |err| {
                self.result = err;
                hyperia.pool.schedule(.{}, &self.runnable);
            }
        }

        const err = self.result orelse return;
        self.result = null;
        return err;
    }
};

event: *Reactor.AutoResetEvent,
pending: std.PriorityQueue(*Handle),

pub fn init(allocator: *mem.Allocator, event: *Reactor.AutoResetEvent) Timer {
    return Timer{
        .event = event,
        .pending = std.PriorityQueue(*Handle).init(allocator, struct {
            fn compare(a: *Handle, b: *Handle) math.Order {
                return math.order(a.expires_at, b.expires_at);
            }
        }.compare),
    };
}

pub fn deinit(self: *Timer, allocator: *mem.Allocator) void {
    var batch: zap.Pool.Batch = .{};
    defer hyperia.pool.schedule(.{}, batch);

    while (self.pending.removeOrNull()) |handle| {
        handle.result = error.Cancelled;
        batch.push(&handle.runnable);
    }

    self.pending.deinit();
}

pub fn after(self: *Timer, duration_ms: usize) Handle {
    return Handle{ .parent = self, .expires_at = @intCast(usize, time.milliTimestamp()) + duration_ms };
}

pub fn at(self: *Timer, timestamp_ms: usize) Handle {
    return Handle{ .parent = self, .expires_at = timestamp_ms };
}

pub fn delay(self: *Timer) ?usize {
    const head = self.pending.peek() orelse return null;
    return math.sub(usize, head.expires_at, @intCast(usize, time.milliTimestamp())) catch 0;
}

pub fn update(self: *Timer, closure: anytype) void {
    const current_time = @intCast(usize, time.milliTimestamp());

    while (true) {
        const head = self.pending.peek() orelse break;
        if (head.expires_at > current_time) break;

        assert(self.pending.remove() == head);

        closure.call(head);
    }
}

test {
    testing.refAllDecls(@This());
}

test "timer2: register timer" {
    hyperia.init();
    defer hyperia.deinit();

    const allocator = testing.allocator;

    const reactor = try Reactor.init(os.EPOLL_CLOEXEC);
    defer reactor.deinit();

    var reactor_event = try Reactor.AutoResetEvent.init(os.EFD_CLOEXEC, reactor);
    defer reactor_event.deinit();

    try reactor.add(reactor_event.fd, &reactor_event.handle, .{});

    var timer = Timer.init(allocator, &reactor_event);
    defer timer.deinit(allocator);

    var handle = timer.after(100); // 100 milliseconds
    var handle_frame = async handle.wait();

    while (timer.delay()) |delay_duration| {
        try reactor.poll(1, struct {
            pub fn call(event: Reactor.Event) void {
                var batch: zap.Pool.Batch = .{};
                defer while (batch.pop()) |runnable| runnable.run();

                const event_handle = @intToPtr(*Reactor.Handle, event.data);
                event_handle.call(&batch, event);
            }
        }, delay_duration);

        timer.update(struct {
            pub fn call(timer_handle: *Timer.Handle) void {
                timer_handle.runnable.run();
            }
        });
    }

    try nosuspend await handle_frame;
}
