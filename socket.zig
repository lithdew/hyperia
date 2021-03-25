const std = @import("std");

const os = std.os;
const mem = std.mem;
const net = std.net;
const time = std.time;
const testing = std.testing;

const print = std.debug.print;

pub const Socket = struct {
    fd: os.socket_t,

    pub fn init(domain: u32, socket_type: u32, protocol: u32) !Socket {
        return Socket{ .fd = try os.socket(domain, socket_type, protocol) };
    }

    pub fn deinit(self: Socket) void {
        os.close(self.fd);
    }

    pub fn shutdown(self: Socket, how: os.ShutdownHow) !void {
        try os.shutdown(self.fd, how);
    }

    pub fn bind(self: Socket, address: net.Address) !void {
        try os.bind(self.fd, &address.any, address.getOsSockLen());
    }

    pub fn listen(self: Socket, max_backlog_size: usize) !void {
        try os.listen(self.fd, @truncate(u31, max_backlog_size));
    }

    pub fn setReuseAddress(self: Socket, enabled: bool) !void {
        try os.setsockopt(self.fd, os.SOL_SOCKET, os.SO_REUSEADDR, mem.asBytes(&@as(usize, @boolToInt(enabled))));
    }

    pub fn getName(self: Socket) !net.Address {
        var binded_address: os.sockaddr = undefined;
        var binded_address_len: u32 = @sizeOf(os.sockaddr);
        try os.getsockname(self.fd, &binded_address, &binded_address_len);
        return net.Address.initPosix(@alignCast(4, &binded_address));
    }

    pub fn connect(self: Socket, address: net.Address) !void {
        try os.connect(self.fd, &address.any, address.getOsSockLen());
    }

    pub fn getError(self: Socket) !void {
        try os.getsockoptError(self.fd);
    }

    pub fn getReadBufferSize(self: Socket) !u32 {
        var value: u32 = undefined;
        var value_len: u32 = @sizeOf(u32);

        const rc = os.system.getsockopt(self.fd, os.SOL_SOCKET, os.SO_RCVBUF, mem.asBytes(&value), &value_len);
        return switch (os.errno(rc)) {
            0 => value,
            os.EBADF => error.BadFileDescriptor,
            os.EFAULT => error.InvalidAddressSpace,
            os.EINVAL => error.InvalidSocketOption,
            os.ENOPROTOOPT => error.UnknownSocketOption,
            os.ENOTSOCK => error.NotASocket,
            else => |err| os.unexpectedErrno(err),
        };
    }

    pub fn getWriteBufferSize(self: Socket) !u32 {
        var value: u32 = undefined;
        var value_len: u32 = @sizeOf(u32);

        const rc = os.system.getsockopt(self.fd, os.SOL_SOCKET, os.SO_SNDBUF, mem.asBytes(&value), &value_len);
        return switch (os.errno(rc)) {
            0 => value,
            os.EBADF => error.BadFileDescriptor,
            os.EFAULT => error.InvalidAddressSpace,
            os.EINVAL => error.InvalidSocketOption,
            os.ENOPROTOOPT => error.UnknownSocketOption,
            os.ENOTSOCK => error.NotASocket,
            else => |err| os.unexpectedErrno(err),
        };
    }

    pub fn setReadBufferSize(self: Socket, size: u32) !void {
        const rc = os.system.setsockopt(self.fd, os.SOL_SOCKET, os.SO_RCVBUF, mem.asBytes(&size), @sizeOf(u32));
        return switch (os.errno(rc)) {
            0 => {},
            os.EBADF => error.BadFileDescriptor,
            os.EFAULT => error.InvalidAddressSpace,
            os.EINVAL => error.InvalidSocketOption,
            os.ENOPROTOOPT => error.UnknownSocketOption,
            os.ENOTSOCK => error.NotASocket,
            else => |err| os.unexpectedErrno(err),
        };
    }

    pub fn setWriteBufferSize(self: Socket, size: u32) !void {
        const rc = os.system.setsockopt(self.fd, os.SOL_SOCKET, os.SO_SNDBUF, mem.asBytes(&size), @sizeOf(u32));
        return switch (os.errno(rc)) {
            0 => {},
            os.EBADF => error.BadFileDescriptor,
            os.EFAULT => error.InvalidAddressSpace,
            os.EINVAL => error.InvalidSocketOption,
            os.ENOPROTOOPT => error.UnknownSocketOption,
            os.ENOTSOCK => error.NotASocket,
            else => |err| os.unexpectedErrno(err),
        };
    }

    pub fn setReadTimeout(self: Socket, milliseconds: usize) !void {
        const timeout = os.timeval{
            .tv_sec = @intCast(isize, milliseconds / time.ms_per_s),
            .tv_usec = @intCast(isize, (milliseconds % time.ms_per_s) * time.us_per_ms),
        };

        const rc = os.system.setsockopt(self.fd, os.SOL_SOCKET, os.SO_RCVTIMEO, mem.asBytes(&timeout), @sizeOf(os.timeval));
        return switch (os.errno(rc)) {
            0 => {},
            os.EBADF => error.BadFileDescriptor,
            os.EFAULT => error.InvalidAddressSpace,
            os.EINVAL => error.InvalidSocketOption,
            os.ENOPROTOOPT => error.UnknownSocketOption,
            os.ENOTSOCK => error.NotASocket,
            else => |err| os.unexpectedErrno(err),
        };
    }

    pub fn setWriteTimeout(self: Socket, milliseconds: usize) !void {
        const timeout = os.timeval{
            .tv_sec = @intCast(isize, milliseconds / time.ms_per_s),
            .tv_usec = @intCast(isize, (milliseconds % time.ms_per_s) * time.us_per_ms),
        };

        const rc = os.system.setsockopt(self.fd, os.SOL_SOCKET, os.SO_SNDTIMEO, mem.asBytes(&timeout), @sizeOf(os.timeval));
        return switch (os.errno(rc)) {
            0 => {},
            os.EBADF => error.BadFileDescriptor,
            os.EFAULT => error.InvalidAddressSpace,
            os.EINVAL => error.InvalidSocketOption,
            os.ENOPROTOOPT => error.UnknownSocketOption,
            os.ENOTSOCK => error.NotASocket,
            else => |err| os.unexpectedErrno(err),
        };
    }

    pub const Connection = struct {
        socket: Socket,
        address: net.Address,
    };

    pub fn accept(self: Socket, flags: u32) !Connection {
        var address: os.sockaddr = undefined;
        var address_len: u32 = @sizeOf(os.sockaddr);

        const fd = try os.accept(self.fd, &address, &address_len, flags);

        return Connection{
            .socket = Socket{ .fd = fd },
            .address = net.Address.initPosix(@alignCast(4, &address)),
        };
    }

    pub fn read(self: Socket, buf: []u8) !usize {
        return try os.read(self.fd, buf);
    }

    pub fn recv(self: Socket, buf: []u8, flags: u32) !usize {
        return try os.recv(self.fd, buf, flags);
    }

    pub fn write(self: Socket, buf: []const u8) !usize {
        return try os.write(self.fd, buf);
    }

    pub fn send(self: Socket, buf: []const u8, flags: u32) !usize {
        return try os.send(self.fd, buf, flags);
    }
};

test {
    testing.refAllDecls(Socket);
}

test "socket/linux: set write timeout" {
    const a = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer a.deinit();

    try a.bind(net.Address.initIp4([_]u8{ 0, 0, 0, 0 }, 0));
    try a.listen(128);

    const binded_address = try a.getName();
    print("Binded to address: {}\n", .{binded_address});

    const b = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer b.deinit();

    try b.connect(binded_address);

    const ab = try a.accept(os.SOCK_CLOEXEC);
    defer ab.socket.deinit();

    // The minimum read buffer size is 128.
    // The minimum write buffer size is 1024.
    // All buffer sizes are doubled when they are passed in.
    // After taking into account book-keeping for buffer sizes, the minimum
    // buffer size before writes start to block the main thread is 65,483 bytes.

    var buf: [65_483]u8 = undefined;

    try ab.socket.setReadBufferSize(128);
    try b.setWriteBufferSize(1024);
    try b.setWriteTimeout(10);

    testing.expectEqual(buf.len - 1, try b.write(&buf));
}

test "socket/linux: set read timeout" {
    const a = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer a.deinit();

    try a.bind(net.Address.initIp4([_]u8{ 0, 0, 0, 0 }, 0));
    try a.listen(128);

    const binded_address = try a.getName();
    print("Binded to address: {}\n", .{binded_address});

    const b = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer b.deinit();

    try b.connect(binded_address);
    try b.setReadTimeout(10);

    const ab = try a.accept(os.SOCK_CLOEXEC);
    defer ab.socket.deinit();

    var buf: [1]u8 = undefined;
    testing.expectError(error.WouldBlock, b.read(&buf));
}

test "socket/linux: create socket pair" {
    const a = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_NONBLOCK | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer a.deinit();

    try a.bind(net.Address.initIp4([_]u8{ 0, 0, 0, 0 }, 0));
    try a.listen(128);

    const binded_address = try a.getName();
    print("Binded to address: {}\n", .{binded_address});

    const b = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_NONBLOCK | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer b.deinit();

    testing.expectError(error.WouldBlock, b.connect(binded_address));
    try b.getError();

    const ab = try a.accept(os.SOCK_NONBLOCK | os.SOCK_CLOEXEC);
    defer ab.socket.deinit();
}

test "raw_socket/linux: create socket pair" {
    const empty_ip4_address = os.sockaddr_in{ .port = 0, .addr = 0 };

    const a = try os.socket(os.AF_INET, os.SOCK_STREAM | os.SOCK_NONBLOCK | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer os.close(a);

    try os.bind(a, @ptrCast(*const os.sockaddr, &empty_ip4_address), @sizeOf(os.sockaddr_in));
    try os.listen(a, 128);

    var binded_address: os.sockaddr = undefined;
    var binded_address_len: u32 = @sizeOf(os.sockaddr);
    try os.getsockname(a, &binded_address, &binded_address_len);

    switch (binded_address.family) {
        os.AF_INET => print("Binded to IPv4 address: {}", .{@ptrCast(*align(1) os.sockaddr_in, &binded_address)}),
        os.AF_INET6 => print("Binded to IPv6 address: {}", .{@ptrCast(*align(1) os.sockaddr_in6, &binded_address)}),
        else => return error.UnexpectedAddressFamily,
    }

    const b = try os.socket(os.AF_INET, os.SOCK_STREAM | os.SOCK_NONBLOCK | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer os.close(b);

    testing.expectError(error.WouldBlock, os.connect(b, &binded_address, binded_address_len));
    try os.getsockoptError(b);
}
