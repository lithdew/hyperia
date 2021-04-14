const std = @import("std");

const mem = std.mem;
const builtin = std.builtin;
const testing = std.testing;

const assert = std.debug.assert;

pub const cache_line_length = switch (builtin.cpu.arch) {
    .x86_64, .aarch64, .powerpc64 => 128,
    .arm, .mips, .mips64, .riscv64 => 32,
    .s390x => 256,
    else => 64,
};

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            next: ?*Node = null,
            value: T,
        };

        stub: Node = .{ .value = undefined },
        tail: ?*Node align(128) = null,
        head: ?*Node align(128) = null,

        pub fn push(self: *Self, node: *Node) void {
            @atomicStore(?*Node, &(self.head orelse &self.stub).next, node, .Release);
            self.head = node;
        }

        pub fn pop(self: *Self) ?*Node {
            const result = @atomicLoad(?*Node, &(self.tail orelse &self.stub).next, .Acquire) orelse return null;
            @atomicStore(?*Node, &self.tail, result, .Release);
            return result;
        }
    };
}

test "queue" {
    var queue: Queue(u64) = .{};
    var node: Queue(u64).Node = .{ .value = 42 };

    queue.push(&node);
    testing.expect(queue.pop().? == &node);
}
