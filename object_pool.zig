const std = @import("std");

const mem = std.mem;
const testing = std.testing;

pub fn ObjectPool(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();

        pub const Object = struct {
            next: ?*Object = null,
            item: T,
        };

        head: ?*Object = null,
        len: usize = 0,

        pub fn init(allocator: *mem.Allocator) !Self {
            var self: Self = .{};
            errdefer self.deinit(allocator);

            var i: usize = 0;
            while (i < capacity) : (i += 1) {
                const object = try allocator.create(Object);
                object.* = .{ .next = self.head, .item = undefined };
                self.head = object;
            }

            self.len = capacity;

            return self;
        }

        pub fn deinit(self: Self, allocator: *mem.Allocator) void {
            var it = self.head;
            while (it) |object| {
                it = object.next;
                allocator.destroy(object);
            }
        }

        pub fn acquire(self: *Self, allocator: *mem.Allocator) !*T {
            if (self.head) |object| {
                self.head = object.next;
                self.len -= 1;
                return &object.item;
            }

            const object = try allocator.create(Object);
            return &object.item;
        }

        pub fn release(self: *Self, allocator: *mem.Allocator, item: *T) void {
            const object = @fieldParentPtr(Object, "item", item);
            if (self.len == capacity) {
                allocator.destroy(object);
            } else {
                object.next = self.head;
                object.item = undefined;
                self.head = object;
                self.len += 1;
            }
        }
    };
}

test {
    testing.refAllDecls(ObjectPool(u8, 16));
}

test "object_pool: test invariants" {
    const allocator = testing.allocator;

    var pool = try ObjectPool(u8, 3).init(allocator);
    defer pool.deinit(allocator);

    testing.expect(pool.len == 3);
    const a = try pool.acquire(allocator);
    const b = try pool.acquire(allocator);
    const c = try pool.acquire(allocator);
    testing.expect(pool.len == 0);
    const d = try pool.acquire(allocator);
    testing.expect(pool.len == 0);
    pool.release(allocator, d);
    testing.expect(pool.len == 1);
    pool.release(allocator, c);
    testing.expect(pool.len == 2);
    pool.release(allocator, b);
    testing.expect(pool.len == 3);
    pool.release(allocator, a);
    testing.expect(pool.len == 3);
}
