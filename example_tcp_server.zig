const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia");
const Reactor = hyperia.Reactor;
const AsyncSocket = hyperia.AsyncSocket;
const AsyncAutoResetEvent = hyperia.AsyncAutoResetEvent;

const os = std.os;
const net = std.net;
const log = std.log.scoped(.server);

pub fn loop(reactor: Reactor, listener: *AsyncSocket) !void {
    while (true) {
        var conn = try listener.accept(os.SOCK_CLOEXEC);
        defer conn.socket.deinit();

        log.info("got connection: {}", .{conn.address});
    }
}

pub fn main() !void {
    hyperia.init();
    defer hyperia.deinit();

    const reactor = try Reactor.init(os.EPOLL_CLOEXEC);
    defer reactor.deinit();

    var listener = try AsyncSocket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer listener.deinit();

    try reactor.add(listener.socket.fd, &listener.handle, .{ .readable = true });

    try listener.setReuseAddress(true);
    try listener.bind(net.Address.initIp4(.{ 0, 0, 0, 0 }, 9000));
    try listener.listen(128);

    log.info("listening for connections on: {}", .{try listener.getName()});

    var frame = async loop(reactor, &listener);

    while (true) {
        var batch: zap.Pool.Batch = .{};
        defer hyperia.pool.schedule(.{}, batch);

        try reactor.poll(
            128,
            struct {
                batch: *zap.Pool.Batch,

                pub fn call(self: @This(), event: Reactor.Event) void {
                    log.info("got event: {}", .{event});

                    const handle = @intToPtr(*Reactor.Handle, event.data);
                    handle.call(self.batch, event);
                }
            }{ .batch = &batch },
            null,
        );
    }

    try nosuspend await frame;
}
