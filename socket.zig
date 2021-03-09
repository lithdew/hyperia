const std = @import("std");

const os = std.os;
const mem = std.mem;
const net = std.net;

const print = std.debug.print;

pub const Socket = struct {
    fd: os.fd_t,

    pub fn init(domain: u32, socket_type: u32, protocol: u32) !Socket {
        return Socket{ .fd = try os.socket(domain, socket_type, protocol) };
    }

    pub fn deinit(self: Socket) void {
        os.close(self.fd);
    }

    pub fn bind(self: Socket, address: net.Address) !void {
        try os.bind(self.fd, &address.any, address.getOsSockLen());
    }

    pub fn listen(self: Socket, max_backlog_size: usize) !void {
        try os.listen(self.fd, @truncate(u31, max_backlog_size));
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
};

test "socket/linux: create socket pair" {
    const a = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_NONBLOCK | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer a.deinit();

    try a.bind(net.Address.initIp4([_]u8{ 0, 0, 0, 0 }, 0));
    try a.listen(128);

    const binded_address = try a.getName();
    print("Binded to address: {}\n", .{binded_address});

    const b = try Socket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_NONBLOCK | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
    defer b.deinit();

    b.connect(binded_address) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };

    try b.getError();
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

    os.connect(b, &binded_address, binded_address_len) catch |err| switch (err) {
        error.WouldBlock => {},
        else => return err,
    };

    try os.getsockoptError(b);
}
