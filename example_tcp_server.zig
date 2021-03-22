const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia");
const Reactor = hyperia.Reactor;
const AsyncSocket = hyperia.AsyncSocket;
const AsyncAutoResetEvent = hyperia.AsyncAutoResetEvent;

const os = std.os;
const net = std.net;
const log = std.log.scoped(.server);

var stopped: bool = false;

pub fn accept(reactor: Reactor, listener: *AsyncSocket) !void {
    while (true) {
        var conn = try listener.accept(os.SOCK_CLOEXEC);
        defer conn.socket.deinit();

        log.info("got connection: {}", .{conn.address});
    }
}

pub fn runApp(reactor: Reactor, reactor_event: *AsyncAutoResetEvent) !void {
    defer {
        @atomicStore(bool, &stopped, true, .Release);
        reactor_event.post();
    }

    var listener = try AsyncSocket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer listener.deinit();

    try reactor.add(listener.socket.fd, &listener.handle, .{ .readable = true });

    try listener.setReuseAddress(true);
    try listener.bind(net.Address.initIp4(.{ 0, 0, 0, 0 }, 9000));
    try listener.listen(128);

    log.info("listening for connections on: {}", .{try listener.getName()});

    var accept_frame = async accept(reactor, &listener);
    defer await accept_frame catch {};

    hyperia.ctrl_c.wait();
    try listener.shutdown(.recv);

    log.info("shutting down...", .{});
}

pub fn main() !void {
    hyperia.init();
    defer hyperia.deinit();

    hyperia.ctrl_c.init();
    defer hyperia.ctrl_c.deinit();

    const reactor = try Reactor.init(os.EPOLL_CLOEXEC);
    defer reactor.deinit();

    var reactor_event = try AsyncAutoResetEvent.init(os.EFD_CLOEXEC, reactor);
    defer reactor_event.deinit();

    try reactor.add(reactor_event.fd, &reactor_event.handle, .{});

    var frame = async runApp(reactor, &reactor_event);

    while (!@atomicLoad(bool, &stopped, .Acquire)) {
        const EventProcessor = struct {
            batch: zap.Pool.Batch = .{},

            pub fn call(self: *@This(), event: Reactor.Event) void {
                log.info("got event: {}", .{event});

                const handle = @intToPtr(*Reactor.Handle, event.data);
                handle.call(&self.batch, event);
            }
        };

        var processor: EventProcessor = .{};
        defer hyperia.pool.schedule(.{}, processor.batch);

        try reactor.poll(128, &processor, null);
    }

    try nosuspend await frame;

    log.info("good bye!", .{});
}
