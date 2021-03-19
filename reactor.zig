const std = @import("std");
const Socket = @import("socket.zig").Socket;

const os = std.os;
const net = std.net;
const mem = std.mem;
const testing = std.testing;

const print = std.debug.print;

pub const Reactor = struct {
    pub const Event = struct {
        data: usize,
        is_error: bool,
        is_hup: bool,
        is_readable: bool,
        is_writable: bool,
    };

    pub const Interest = struct {
        oneshot: bool = false,
        readable: bool = false,
        writable: bool = false,

        pub fn flags(self: Interest) u32 {
            var set: u32 = os.EPOLLRDHUP;
            set |= if (self.oneshot) os.EPOLLONESHOT else os.EPOLLET;
            if (self.readable) set |= os.EPOLLIN;
            if (self.writable) set |= os.EPOLLOUT;
            return set;
        }
    };

    fd: os.fd_t,

    pub fn init(flags: u32) !Reactor {
        const fd = try os.epoll_create1(flags);
        return Reactor{ .fd = fd };
    }

    pub fn deinit(self: Reactor) void {
        os.close(self.fd);
    }

    pub fn add(self: Reactor, fd: os.fd_t, data: anytype, interest: Interest) !void {
        try os.epoll_ctl(self.fd, os.EPOLL_CTL_ADD, fd, &os.epoll_event{
            .events = interest.flags(),
            .data = .{ .ptr = if (@typeInfo(@TypeOf(data)) == .Pointer) @ptrToInt(data) else data },
        });
    }

    pub fn poll(self: Reactor, comptime max_num_events: comptime_int, closure: anytype, timeout_milliseconds: ?usize) !void {
        var events: [max_num_events]os.epoll_event = undefined;

        const num_events = os.epoll_wait(self.fd, &events, if (timeout_milliseconds) |ms| @intCast(i32, ms) else -1);
        for (events[0..num_events]) |ev| {
            const is_error = ev.events & os.EPOLLERR != 0;
            const is_hup = ev.events & (os.EPOLLHUP | os.EPOLLRDHUP) != 0;
            const is_readable = ev.events & os.EPOLLIN != 0;
            const is_writable = ev.events & os.EPOLLOUT != 0;

            closure.call(Event{
                .data = ev.data.ptr,
                .is_error = is_error,
                .is_hup = is_hup,
                .is_readable = is_readable,
                .is_writable = is_writable,
            });
        }
    }
};

test {
    testing.refAllDecls(Reactor);
}

test "reactor: shutdown before accept async socket" {
    const reactor = try Reactor.init(os.EPOLL_CLOEXEC);
    defer reactor.deinit();

    const a = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_NONBLOCK | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer a.deinit();

    try reactor.add(a.fd, 0, .{ .readable = true });
    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 0,
                    .is_error = false,
                    .is_hup = true,
                    .is_readable = false,
                    .is_writable = false,
                },
                event,
            );
        }
    }, null);

    try a.bind(net.Address.initIp4([_]u8{ 0, 0, 0, 0 }, 0));
    try a.listen(128);

    const binded_address = try a.getName();
    print("Binded to address: {}\n", .{binded_address});

    const b = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_NONBLOCK | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer b.deinit();

    try reactor.add(b.fd, 1, .{ .readable = true, .writable = true });
    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 1,
                    .is_error = false,
                    .is_hup = true,
                    .is_readable = false,
                    .is_writable = true,
                },
                event,
            );
        }
    }, null);

    b.connect(binded_address) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };

    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 1,
                    .is_error = false,
                    .is_hup = false,
                    .is_readable = false,
                    .is_writable = true,
                },
                event,
            );
        }
    }, null);

    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 0,
                    .is_error = false,
                    .is_hup = false,
                    .is_readable = true,
                    .is_writable = false,
                },
                event,
            );
        }
    }, null);

    const ab = try a.accept(os.SOCK_CLOEXEC);
    defer ab.socket.deinit();

    try os.shutdown(ab.socket.fd, .both);

    try reactor.add(ab.socket.fd, 2, .{ .readable = true, .writable = true });

    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 1,
                    .is_error = false,
                    .is_hup = true,
                    .is_readable = true,
                    .is_writable = true,
                },
                event,
            );
        }
    }, null);

    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 2,
                    .is_error = false,
                    .is_hup = true,
                    .is_readable = true,
                    .is_writable = true,
                },
                event,
            );
        }
    }, null);
}

test "reactor: shutdown async socket" {
    const reactor = try Reactor.init(os.EPOLL_CLOEXEC);
    defer reactor.deinit();

    const a = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_NONBLOCK | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer a.deinit();

    try reactor.add(a.fd, 0, .{ .readable = true });
    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 0,
                    .is_error = false,
                    .is_hup = true,
                    .is_readable = false,
                    .is_writable = false,
                },
                event,
            );
        }
    }, null);

    try a.bind(net.Address.initIp4([_]u8{ 0, 0, 0, 0 }, 0));
    try a.listen(128);

    const binded_address = try a.getName();
    print("Binded to address: {}\n", .{binded_address});

    const b = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_NONBLOCK | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer b.deinit();

    try reactor.add(b.fd, 1, .{ .readable = true, .writable = true });
    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 1,
                    .is_error = false,
                    .is_hup = true,
                    .is_readable = false,
                    .is_writable = true,
                },
                event,
            );
        }
    }, null);

    b.connect(binded_address) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };

    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 1,
                    .is_error = false,
                    .is_hup = false,
                    .is_readable = false,
                    .is_writable = true,
                },
                event,
            );
        }
    }, null);

    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 0,
                    .is_error = false,
                    .is_hup = false,
                    .is_readable = true,
                    .is_writable = false,
                },
                event,
            );
        }
    }, null);

    const ab = try a.accept(os.SOCK_CLOEXEC);
    defer ab.socket.deinit();

    try reactor.add(ab.socket.fd, 2, .{ .readable = true, .writable = true });
    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 2,
                    .is_error = false,
                    .is_hup = false,
                    .is_readable = false,
                    .is_writable = true,
                },
                event,
            );
        }
    }, null);

    try os.shutdown(b.fd, .both);

    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 2,
                    .is_error = false,
                    .is_hup = true,
                    .is_readable = true,
                    .is_writable = true,
                },
                event,
            );
        }
    }, null);

    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 1,
                    .is_error = false,
                    .is_hup = true,
                    .is_readable = true,
                    .is_writable = true,
                },
                event,
            );
        }
    }, null);
}

test "reactor: async socket" {
    const reactor = try Reactor.init(os.EPOLL_CLOEXEC);
    defer reactor.deinit();

    const a = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_NONBLOCK | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer a.deinit();

    try reactor.add(a.fd, 0, .{ .readable = true });
    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 0,
                    .is_error = false,
                    .is_hup = true,
                    .is_readable = false,
                    .is_writable = false,
                },
                event,
            );
        }
    }, null);

    try a.bind(net.Address.initIp4([_]u8{ 0, 0, 0, 0 }, 0));
    try a.listen(128);

    const binded_address = try a.getName();
    print("Binded to address: {}\n", .{binded_address});

    const b = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_NONBLOCK | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer b.deinit();

    try reactor.add(b.fd, 1, .{ .readable = true, .writable = true });
    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 1,
                    .is_error = false,
                    .is_hup = true,
                    .is_readable = false,
                    .is_writable = true,
                },
                event,
            );
        }
    }, null);

    b.connect(binded_address) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };

    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 1,
                    .is_error = false,
                    .is_hup = false,
                    .is_readable = false,
                    .is_writable = true,
                },
                event,
            );
        }
    }, null);

    try reactor.poll(1, struct {
        fn call(event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = 0,
                    .is_error = false,
                    .is_hup = false,
                    .is_readable = true,
                    .is_writable = false,
                },
                event,
            );
        }
    }, null);
}
