const std = @import("std");

const mem = std.mem;
const net = std.net;
const fmt = std.fmt;
const testing = std.testing;

pub fn parseAddress(buf: []const u8) !net.Address {
    var j: usize = 0;
    var k: usize = 0;

    const i = mem.lastIndexOfScalar(u8, buf, ':') orelse {
        const port = fmt.parseInt(u16, buf, 10) catch return error.MissingPort;
        return net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    };

    const host = parse: {
        if (buf[0] == '[') {
            const end = mem.indexOfScalar(u8, buf, ']') orelse return error.MissingEndBracket;
            if (end + 1 == i) {} else if (end + 1 == buf.len) {
                return error.MissingRightBracket;
            } else {
                return error.MissingPort;
            }

            j = 1;
            k = end + 1;
            break :parse buf[1..end];
        }

        if (mem.indexOfScalar(u8, buf[0..i], ':') != null) {
            return error.TooManyColons;
        }
        break :parse buf[0..i];
    };

    if (mem.indexOfScalar(u8, buf[j..], '[') != null) {
        return error.UnexpectedLeftBracket;
    }

    if (mem.indexOfScalar(u8, buf[k..], ']') != null) {
        return error.UnexpectedRightBracket;
    }

    const port = fmt.parseInt(u16, buf[i + 1 ..], 10) catch return error.BadPort;
    if (host.len == 0) return net.Address.initIp4(.{ 0, 0, 0, 0 }, port);

    return try net.Address.parseIp(host, port);
}

test {
    testing.refAllDecls(@This());
}
