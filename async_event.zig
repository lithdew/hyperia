const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia");
const Reactor = @import("reactor.zig").Reactor;

const os = std.os;
const mem = std.mem;
const testing = std.testing;

const assert = std.debug.assert;

pub const AsyncEvent = struct {
    const Self = @This();

    fd: os.fd_t,
    notified: bool = true,

    pub fn init(flags: u32) !Self {
        return Self{ .fd = try os.eventfd(0, flags | os.EFD_NONBLOCK) };
    }

    pub fn deinit(self: Self) void {
        os.close(self.fd);
    }

    pub fn post(self: *Self) void {
        if (!@atomicRmw(bool, &self.notified, .Xchg, false, .AcqRel)) return;

        const num_bytes = os.write(self.fd, mem.asBytes(&@as(u64, 1))) catch |err| switch (err) {
            error.WouldBlock => 8,
            error.NotOpenForWriting => return,
            else => unreachable,
        };

        assert(num_bytes == @sizeOf(u64));
    }

    pub fn reset(self: *Self) void {
        var counter: u64 = undefined;
        while (true) {
            const num_bytes = os.read(self.fd, mem.asBytes(&counter)) catch |err| switch (err) {
                error.WouldBlock => break,
                else => unreachable,
            };

            assert(num_bytes == @sizeOf(u64));
        }

        @atomicStore(bool, &self.notified, true, .Release);
    }
};

pub const AsyncAutoResetEvent = struct {
    const Self = @This();

    event: AsyncEvent,
    handle: Reactor.Handle = .{ .onEventFn = onEvent },

    pub fn init(flags: u32) !Self {
        return Self{ .event = try AsyncEvent.init(flags) };
    }

    pub fn deinit(self: *Self) void {
        self.event.deinit();
    }

    pub fn post(self: *Self) void {
        self.event.post();
    }

    pub fn onEvent(handle: *Reactor.Handle, batch: *zap.Pool.Batch, event: Reactor.Event) void {
        const self = @fieldParentPtr(AsyncAutoResetEvent, "handle", handle);

        if (event.is_readable) {
            self.event.reset();
        }
    }
};

test "auto_reset_event/async: post a notification 1000 times" {
    const reactor = try Reactor.init(os.EPOLL_CLOEXEC);
    defer reactor.deinit();

    var test_event = try AsyncAutoResetEvent.init(os.EFD_CLOEXEC);
    defer test_event.deinit();

    try reactor.add(test_event.event.fd, &test_event.handle, .{ .readable = true });

    // Registering an eventfd to epoll will not trigger a notification.
    // Deregistering an eventfd from epoll will not trigger a notification.
    // Attempt to post a notification to see if we achieve expected behavior.

    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        test_event.post();

        try reactor.poll(1, struct {
            pub fn call(event: Reactor.Event) void {
                const handle = @intToPtr(*Reactor.Handle, event.data);

                var batch: zap.Pool.Batch = .{};
                defer testing.expect(batch.isEmpty());

                handle.call(&batch, event);
            }
        }, null);
    }

    testing.expect(@atomicLoad(bool, &test_event.event.notified, .Monotonic));
}
