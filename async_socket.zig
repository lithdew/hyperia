const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");
const Socket = @import("socket.zig").Socket;
const Reactor = @import("reactor.zig").Reactor;

const os = std.os;
const net = std.net;
const mpsc = hyperia.mpsc;
const testing = std.testing;

pub const AsyncSocket = struct {
    pub const Error = error{Cancelled};

    const Self = @This();

    const READY = 0;
    const CANCELLED = 1;

    socket: Socket,
    readable: mpsc.AsyncAutoResetEvent(usize) = .{},
    writable: mpsc.AsyncAutoResetEvent(usize) = .{},
    handle: Reactor.Handle = .{ .onEventFn = onEvent },

    pub fn init(domain: u32, socket_type: u32, flags: u32) !Self {
        return Self{ .socket = try Socket.init(domain, socket_type | os.SOCK_NONBLOCK, flags) };
    }

    pub fn deinit(self: *Self) void {
        self.socket.deinit();
    }

    pub fn from(socket: Socket) Self {
        return Self{ .socket = socket };
    }

    pub fn shutdown(self: *Self, how: os.ShutdownHow) !void {
        return self.socket.shutdown(how);
    }

    pub fn bind(self: *Self, address: net.Address) !void {
        return self.socket.bind(address);
    }

    pub fn listen(self: *Self, max_backlog_size: usize) !void {
        return self.socket.listen(max_backlog_size);
    }

    pub fn setReuseAddress(self: *Self, enabled: bool) !void {
        return self.socket.setReuseAddress(enabled);
    }

    pub fn getName(self: *Self) !net.Address {
        return self.socket.getName();
    }

    pub fn getReadBufferSize(self: *Self) !u32 {
        return self.socket.getReadBufferSize();
    }

    pub fn getWriteBufferSize(self: *Self) !u32 {
        return self.socket.getWriteBufferSize();
    }

    pub fn setReadBufferSize(self: *Self, size: u32) !void {
        return self.socket.setReadBufferSize(size);
    }

    pub fn setWriteBufferSize(self: *Self, size: u32) !void {
        return self.socket.setWriteBufferSize(size);
    }

    pub fn setReadTimeout(self: *Self, milliseconds: usize) !void {
        return self.socket.setReadTimeout(milliseconds);
    }

    pub fn setWriteTimeout(self: *Self, milliseconds: usize) !void {
        return self.socket.setWriteTimeout(milliseconds);
    }

    pub fn tryRead(self: *Self, buf: []u8) os.ReadError!usize {
        return self.socket.read(buf);
    }

    pub fn tryRecv(self: *Self, buf: []u8, flags: u32) os.RecvFromError!usize {
        return self.socket.recv(buf, flags);
    }

    pub fn tryWrite(self: *Self, buf: []const u8) os.WriteError!usize {
        return self.socket.write(buf);
    }

    pub fn trySend(self: *Self, buf: []const u8, flags: u32) os.SendError!usize {
        return self.socket.send(buf, flags);
    }

    pub fn tryConnect(self: *Self, address: net.Address) os.ConnectError!void {
        return self.socket.connect(address);
    }

    pub fn tryAccept(self: *Self, flags: u32) !Socket.Connection {
        return self.socket.accept(flags);
    }

    pub fn read(self: *Self, buf: []u8) (os.ReadError || Error)!usize {
        while (true) {
            const num_bytes = self.tryRead(buf) catch |err| switch (err) {
                error.WouldBlock => {
                    if (self.readable.wait() == CANCELLED) {
                        return error.Cancelled;
                    }
                    continue;
                },
                else => return err,
            };

            return num_bytes;
        }
    }

    pub fn recv(self: *Self, buf: []u8, flags: u32) (os.RecvFromError || Error)!usize {
        while (true) {
            const num_bytes = self.tryRecv(buf, flags) catch |err| switch (err) {
                error.WouldBlock => {
                    if (self.readable.wait() == CANCELLED) {
                        return error.Cancelled;
                    }
                    continue;
                },
                else => return err,
            };

            return num_bytes;
        }
    }

    pub fn write(self: *Self, buf: []const u8) (os.WriteError || Error)!usize {
        while (true) {
            const num_bytes = self.tryWrite(buf) catch |err| switch (err) {
                error.WouldBlock => {
                    if (self.writable.wait() == CANCELLED) {
                        return error.Cancelled;
                    }
                    continue;
                },
                else => return err,
            };

            return num_bytes;
        }
    }

    pub fn send(self: *Self, buf: []const u8, flags: u32) (os.SendError || Error)!usize {
        while (true) {
            const num_bytes = self.trySend(buf, flags) catch |err| switch (err) {
                error.WouldBlock => {
                    if (self.writable.wait() == CANCELLED) {
                        return error.Cancelled;
                    }
                    continue;
                },
                else => return err,
            };

            return num_bytes;
        }
    }

    pub fn connect(self: *Self, address: net.Address) (os.ConnectError || Error)!void {
        while (true) {
            return self.tryConnect(address) catch |err| switch (err) {
                error.WouldBlock => {
                    if (self.writable.wait() == CANCELLED) {
                        return error.Cancelled;
                    }
                },
                else => return err,
            };
        }
    }

    pub fn accept(self: *Self, flags: u32) (os.AcceptError || Error)!Socket.Connection {
        while (true) {
            const connection = self.tryAccept(flags) catch |err| switch (err) {
                error.WouldBlock => {
                    if (self.readable.wait() == CANCELLED) {
                        return error.Cancelled;
                    }
                    continue;
                },
                else => return err,
            };

            return connection;
        }
    }

    pub fn cancel(self: *Self, how: enum { read, write, connect, accept, all }) void {
        switch (how) {
            .read, .accept => {
                if (self.readable.set(CANCELLED)) |runnable| {
                    hyperia.pool.schedule(.{}, runnable);
                }
            },
            .write, .connect => {
                if (self.writable.set(CANCELLED)) |runnable| {
                    hyperia.pool.schedule(.{}, runnable);
                }
            },
            .all => {
                var batch: zap.Pool.Batch = .{};
                if (self.writable.set(CANCELLED)) |runnable| batch.push(runnable);
                if (self.readable.set(CANCELLED)) |runnable| batch.push(runnable);
                hyperia.pool.schedule(.{}, batch);
            },
        }
    }

    pub fn onEvent(handle: *Reactor.Handle, batch: *zap.Pool.Batch, event: Reactor.Event) void {
        const self = @fieldParentPtr(AsyncSocket, "handle", handle);

        if (event.is_readable) {
            if (self.readable.set(READY)) |runnable| {
                batch.push(runnable);
            }
        }

        if (event.is_writable) {
            if (self.writable.set(READY)) |runnable| {
                batch.push(runnable);
            }
        }

        if (event.is_hup) {
            if (self.readable.set(READY)) |runnable| batch.push(runnable);
            if (self.writable.set(READY)) |runnable| batch.push(runnable);
            // TODO(kenta): deinitialize resources for connection
        }
    }
};

test {
    testing.refAllDecls(@This());
}

test "socket/async" {
    hyperia.init();
    defer hyperia.deinit();

    const reactor = try Reactor.init(os.EPOLL_CLOEXEC);
    defer reactor.deinit();

    var a = try AsyncSocket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer a.deinit();

    try reactor.add(a.socket.fd, &a.handle, .{ .readable = true });
    try reactor.poll(1, struct {
        expected_data: usize,

        pub fn call(self: @This(), event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = self.expected_data,
                    .is_error = false,
                    .is_hup = true,
                    .is_readable = false,
                    .is_writable = false,
                },
                event,
            );
        }
    }{ .expected_data = @ptrToInt(&a.handle) }, null);

    try a.bind(net.Address.initIp4([_]u8{ 0, 0, 0, 0 }, 0));
    try a.listen(128);

    const binded_address = try a.getName();

    var b = try AsyncSocket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer b.deinit();

    try reactor.add(b.socket.fd, &b.handle, .{ .readable = true, .writable = true });
    try reactor.poll(1, struct {
        expected_data: usize,

        pub fn call(self: @This(), event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = self.expected_data,
                    .is_error = false,
                    .is_hup = true,
                    .is_readable = false,
                    .is_writable = true,
                },
                event,
            );
        }
    }{ .expected_data = @ptrToInt(&b.handle) }, null);

    var connect_frame = async b.connect(binded_address);

    try reactor.poll(1, struct {
        expected_data: usize,

        pub fn call(self: @This(), event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = self.expected_data,
                    .is_error = false,
                    .is_hup = false,
                    .is_readable = false,
                    .is_writable = true,
                },
                event,
            );

            var batch: zap.Pool.Batch = .{};
            defer hyperia.pool.schedule(.{}, batch);

            const handle = @intToPtr(*Reactor.Handle, event.data);
            handle.call(&batch, event);
        }
    }{ .expected_data = @ptrToInt(&b.handle) }, null);

    try nosuspend await connect_frame;

    try reactor.poll(1, struct {
        expected_data: usize,

        pub fn call(self: @This(), event: Reactor.Event) void {
            testing.expectEqual(
                Reactor.Event{
                    .data = self.expected_data,
                    .is_error = false,
                    .is_hup = false,
                    .is_readable = true,
                    .is_writable = false,
                },
                event,
            );

            var batch: zap.Pool.Batch = .{};
            defer hyperia.pool.schedule(.{}, batch);

            const handle = @intToPtr(*Reactor.Handle, event.data);
            handle.call(&batch, event);
        }
    }{ .expected_data = @ptrToInt(&a.handle) }, null);

    var ab = try nosuspend a.accept(os.SOCK_CLOEXEC | os.SOCK_NONBLOCK);
    defer ab.socket.deinit();
}
