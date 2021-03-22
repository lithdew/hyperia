const std = @import("std");
const hyperia = @import("hyperia.zig");

const mem = std.mem;
const testing = std.testing;

const AsyncWaitGroup = hyperia.AsyncWaitGroup;

pub const AsyncWaitGroupAllocator = struct {
    const Self = @This();

    backing_allocator: *mem.Allocator,
    allocator: mem.Allocator = .{
        .allocFn = alloc,
        .resizeFn = resize,
    },
    wg: AsyncWaitGroup = .{},

    fn alloc(allocator: *mem.Allocator, len: usize, ptr_align: u29, len_align: u29, ret_addr: usize) mem.Allocator.Error![]u8 {
        const self = @fieldParentPtr(Self, "allocator", allocator);
        const bytes = try self.backing_allocator.allocFn(self.backing_allocator, len, ptr_align, len_align, ret_addr);
        self.wg.add(bytes.len);

        return bytes;
    }

    fn resize(allocator: *mem.Allocator, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ret_addr: usize) mem.Allocator.Error!usize {
        const self = @fieldParentPtr(Self, "allocator", allocator);
        const bytes_len = try self.backing_allocator.resizeFn(self.backing_allocator, buf, buf_align, new_len, len_align, ret_addr);
        if (bytes_len < buf.len) {
            self.wg.sub(buf.len - bytes_len);
        } else {
            self.wg.add(bytes_len - buf.len);
        }
        return bytes_len;
    }

    pub fn wait(self: *Self) void {
        self.wg.wait();
    }
};

test {
    testing.refAllDecls(@This());
}

test "async_wait_group_allocator: wait for all allocations to be freed" {
    hyperia.init();
    defer hyperia.deinit();

    var wga = AsyncWaitGroupAllocator{ .backing_allocator = testing.allocator };
    const allocator = &wga.allocator;

    var a = try allocator.alloc(u8, 16);
    var b = async wga.wait();
    var c = try allocator.alloc(u8, 128);

    allocator.free(a);
    allocator.free(c);
    nosuspend await b;
}
