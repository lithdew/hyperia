const std = @import("std");

const os = std.os;
const mem = std.mem;

const print = std.debug.print;

test "socket/linux: create socket pair" {
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
