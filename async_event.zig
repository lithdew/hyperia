const std = @import("std");
const zap = @import("zap");
const Reactor = @import("reactor.zig").Reactor;

const os = std.os;
const mem = std.mem;
const testing = std.testing;

const assert = std.debug.assert;

pub const AsyncAutoResetEvent = struct {
    const Self = @This();

    fd: os.fd_t,
    reactor: Reactor,
    notified: bool = true,
    handle: Reactor.Handle = .{ .onEventFn = onEvent },

    pub fn init(flags: u32, reactor: Reactor) !Self {
        return Self{ .fd = try os.eventfd(0, flags | os.EFD_NONBLOCK), .reactor = reactor };
    }

    pub fn deinit(self: *Self) void {
        os.close(self.fd);
    }

    pub fn post(self: *Self) void {
        if (!@atomicRmw(bool, &self.notified, .Xchg, false, .AcqRel)) return;

        os.epoll_ctl(self.reactor.fd, os.EPOLL_CTL_MOD, self.fd, &os.epoll_event{
            .events = os.EPOLLONESHOT | os.EPOLLOUT,
            .data = .{ .ptr = @ptrToInt(&self.handle) },
        }) catch {};
    }

    pub fn onEvent(handle: *Reactor.Handle, batch: *zap.Pool.Batch, event: Reactor.Event) void {
        assert(event.is_writable);

        const self = @fieldParentPtr(AsyncAutoResetEvent, "handle", handle);
        @atomicStore(bool, &self.notified, true, .Release);
    }
};

test "auto_reset_event/async: post a notification 1000 times" {
    const reactor = try Reactor.init(os.EPOLL_CLOEXEC);
    defer reactor.deinit();

    var test_event = try AsyncAutoResetEvent.init(os.EFD_CLOEXEC, reactor);
    defer test_event.deinit();

    try reactor.add(test_event.fd, &test_event.handle, .{});

    try reactor.poll(1, struct {
        pub fn call(event: Reactor.Event) void {
            unreachable;
        }
    }, 0);

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

    testing.expect(@atomicLoad(bool, &test_event.notified, .Monotonic));
}
