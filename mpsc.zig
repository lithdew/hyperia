const std = @import("std");

const os = std.os;
const mem = std.mem;
const builtin = std.builtin;
const testing = std.testing;

pub const cache_line_length = switch (builtin.cpu.arch) {
    .x86_64, .aarch64, .powerpc64 => 128,
    .arm, .mips, .mips64, .riscv64 => 32,
    .s390x => 256,
    else => 64,
};

/// Unbounded MPSC queue supporting batching operations.
pub fn Sink(comptime T: type) type {
    return struct {
        pub const Node = struct {
            next: ?*Node = null,
            value: T,
        };

        const Self = @This();

        front: Node align(cache_line_length) = .{ .value = undefined },
        back: ?*Node align(cache_line_length) = null,

        pub fn tryPush(self: *Self, src: *Node) void {
            src.next = null;
            const old_back = @atomicRmw(?*Node, &self.back, .Xchg, src, .AcqRel) orelse &self.front;
            @atomicStore(?*Node, &old_back.next, src, .Release);
        }

        pub fn tryPushBatch(self: *Self, first: *Node, last: *Node) void {
            last.next = null;
            const old_back = @atomicRmw(?*Node, &self.back, .Xchg, last, .AcqRel) orelse &self.front;
            @atomicStore(?*Node, &old_back.next, first, .Release);
        }

        pub fn tryPop(self: *Self) ?*Node {
            var first = @atomicLoad(?*Node, &self.front.next, .Acquire) orelse return null;

            if (@atomicLoad(?*Node, &first.next, .Acquire)) |next| {
                self.front.next = next;
                return first;
            }

            var last = @atomicLoad(?*Node, &self.back, .Acquire) orelse &self.front;
            if (first != last) return null;

            self.front.next = null;
            if (@cmpxchgStrong(?*Node, &self.back, last, &self.front, .AcqRel, .Acquire) == null) {
                return first;
            }

            var maybe_next = @atomicLoad(?*Node, &first.next, .Acquire);
            while (maybe_next == null) : (os.sched_yield() catch {}) {
                maybe_next = @atomicLoad(?*Node, &first.next, .Acquire);
            }

            self.front.next = maybe_next;

            return first;
        }

        pub fn tryPopBatch(self: *Self, b_first: **Node, b_last: **Node) usize {
            var front = @atomicLoad(?*Node, &self.front.next, .Acquire) orelse return 0;
            b_first.* = front;

            var maybe_next = @atomicLoad(?*Node, &front.next, .Acquire);
            var count: usize = 0;

            while (maybe_next) |next| {
                count += 1;
                b_last.* = front;
                front = next;
                maybe_next = @atomicLoad(?*Node, &next.next, .Acquire);
            }

            var last = @atomicLoad(?*Node, &self.back, .Acquire) orelse &self.front;
            if (front != last) {
                @atomicStore(?*Node, &self.front.next, front, .Release);
                return count;
            }

            self.front.next = null;
            if (@cmpxchgStrong(?*Node, &self.back, last, &self.front, .AcqRel, .Acquire) == null) {
                count += 1;
                b_last.* = front;
                return count;
            }

            maybe_next = @atomicLoad(?*Node, &front.next, .Acquire);
            while (maybe_next == null) : (os.sched_yield() catch {}) {
                maybe_next = @atomicLoad(?*Node, &front.next, .Acquire);
            }

            count += 1;
            self.front.next = maybe_next;
            b_last.* = front;

            return count;
        }
    };
}

test {
    testing.refAllDecls(Sink(u64));
}

test "sink: push and pop 600,000 u64s with 15 producers" {
    const NUM_ITEMS = 600_000;
    const NUM_PRODUCERS = 15;

    const TestSink = Sink(u64);

    const Context = struct {
        allocator: *mem.Allocator,
        sink: *TestSink,

        fn runProducer(self: @This()) !void {
            var i: usize = 0;
            while (i < NUM_ITEMS / NUM_PRODUCERS) : (i += 1) {
                const node = try self.allocator.create(TestSink.Node);
                node.* = .{ .value = @intCast(u64, i) };
                self.sink.tryPush(node);
            }
        }

        fn runConsumer(self: @This()) !void {
            var i: usize = 0;
            while (i < NUM_ITEMS) : (i += 1) {
                const node = while (true) {
                    if (self.sink.tryPop()) |node| {
                        break node;
                    }
                } else unreachable;

                self.allocator.destroy(node);
            }
        }
    };

    const allocator = testing.allocator;

    var sink: TestSink = .{};

    var consumer = try std.Thread.spawn(Context{ .allocator = allocator, .sink = &sink }, Context.runConsumer);

    var producers: [NUM_PRODUCERS]*std.Thread = undefined;
    for (producers) |*producer| {
        producer.* = try std.Thread.spawn(Context{ .allocator = allocator, .sink = &sink }, Context.runProducer);
    }

    for (producers) |producer| {
        producer.wait();
    }

    consumer.wait();
}
