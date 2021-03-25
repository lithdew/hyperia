const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

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

pub const AsyncAutoResetEvent = struct {
    const Self = @This();

    const Node = struct {
        runnable: zap.Pool.Runnable = .{ .runFn = run },
        frame: anyframe,
        cancelled: bool = false,

        pub fn run(runnable: *zap.Pool.Runnable) void {
            const self = @fieldParentPtr(Node, "runnable", runnable);
            resume self.frame;
        }
    };

    const EMPTY = 0;
    const NOTIFIED = 1;
    const CLOSED = 2;

    state: usize = EMPTY,

    pub fn close(self: *Self) ?*zap.Pool.Runnable {
        switch (@atomicRmw(usize, &self.state, .Xchg, CLOSED, .AcqRel)) {
            EMPTY, NOTIFIED, CLOSED => return null,
            else => |state| {
                const node = @intToPtr(*Node, state);
                node.cancelled = true;
                return &node.runnable;
            },
        }
    }

    pub fn set(self: *Self) ?*zap.Pool.Runnable {
        var state = @atomicLoad(usize, &self.state, .Monotonic);
        while (true) {
            const new_state: usize = switch (state) {
                NOTIFIED, CLOSED => return null,
                else => NOTIFIED,
            };

            if (state != EMPTY) {
                state = @cmpxchgWeak(usize, &self.state, state, new_state, .Acquire, .Monotonic) orelse {
                    if (state != EMPTY) {
                        const node = @intToPtr(*Node, state);
                        return &node.runnable;
                    }
                    return null;
                };
            } else {
                state = @cmpxchgWeak(usize, &self.state, state, new_state, .Monotonic, .Monotonic) orelse {
                    if (state != EMPTY) {
                        const node = @intToPtr(*Node, state);
                        return &node.runnable;
                    }
                    return null;
                };
            }
        }
    }

    pub fn wait(self: *Self) !void {
        var state = @atomicLoad(usize, &self.state, .Monotonic);
        if (state == CLOSED) return error.Cancelled;

        if (state != NOTIFIED) {
            var node: Node = .{ .frame = @frame() };
            suspend { // This CMPXCHG can only fail if state is NOTIFIED.
                if (@cmpxchgStrong(usize, &self.state, state, @ptrToInt(&node), .Release, .Monotonic) != null) {
                    hyperia.pool.schedule(.{}, &node.runnable);
                }
            }
            if (node.cancelled) return error.Cancelled;
        }

        @atomicStore(usize, &self.state, EMPTY, .Monotonic);
    }
};

pub fn AsyncSink(comptime T: type) type {
    return struct {
        const Self = @This();

        sink: Sink(T) = .{},
        event: AsyncAutoResetEvent = .{},

        pub fn close(self: *Self) void {
            if (self.event.close()) |runnable| {
                hyperia.pool.schedule(.{}, runnable);
            }
        }

        pub fn push(self: *Self, src: *Sink(T).Node) void {
            self.sink.tryPush(src);

            if (self.event.set()) |runnable| {
                hyperia.pool.schedule(.{}, runnable);
            }
        }

        pub fn pushBatch(self: *Self, first: *Sink(T).Node, last: *Sink(T).Node) void {
            self.sink.tryPushBatch(first, last);

            if (self.event.set()) |runnable| {
                hyperia.pool.schedule(.{}, runnable);
            }
        }

        pub fn pop(self: *Self) !*Sink(T).Node {
            while (true) {
                return self.sink.tryPop() orelse {
                    try self.event.wait();
                    continue;
                };
            }
        }

        pub fn popBatch(self: *Self, b_first: **Sink(T).Node, b_last: **Sink(T).Node) !usize {
            while (true) {
                const num_items = self.sink.tryPopBatch(b_first, b_last);
                if (num_items == 0) {
                    try self.event.wait();
                    continue;
                }
                return num_items;
            }
        }
    };
}

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
    testing.refAllDecls(AsyncSink(u64));
    testing.refAllDecls(AsyncAutoResetEvent);
}

test "sink: push and pop 60,000 u64s with 15 producers" {
    const NUM_ITEMS = 60_000;
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
                self.allocator.destroy(while (true) {
                    if (self.sink.tryPop()) |node| {
                        break node;
                    }
                } else unreachable);
            }
        }
    };

    const allocator = testing.allocator;

    var sink: TestSink = .{};

    const consumer = try std.Thread.spawn(Context.runConsumer, Context{
        .allocator = allocator,
        .sink = &sink,
    });
    defer consumer.wait();

    var producers: [NUM_PRODUCERS]*std.Thread = undefined;
    defer for (producers) |producer| producer.wait();

    for (producers) |*producer| {
        producer.* = try std.Thread.spawn(Context.runProducer, Context{
            .allocator = allocator,
            .sink = &sink,
        });
    }
}

test "sink: batch push and pop 60,000 u64s with 15 producers" {
    const NUM_ITEMS = 60_000;
    const NUM_ITEMS_PER_BATCH = 100;
    const NUM_PRODUCERS = 15;

    const TestSink = Sink(u64);

    const Context = struct {
        allocator: *mem.Allocator,
        sink: *TestSink,

        fn runBatchProducer(self: @This()) !void {
            var i: usize = 0;
            while (i < NUM_ITEMS / NUM_PRODUCERS) : (i += NUM_ITEMS_PER_BATCH) {
                var first = try self.allocator.create(TestSink.Node);
                first.* = .{ .value = @intCast(u64, i) };

                const last = first;

                var j: usize = 0;
                while (j < NUM_ITEMS_PER_BATCH - 1) : (j += 1) {
                    const node = try self.allocator.create(TestSink.Node);
                    node.* = .{
                        .next = first,
                        .value = @intCast(u64, i) + 1 + @intCast(u64, j),
                    };
                    first = node;
                }

                self.sink.tryPushBatch(first, last);
            }
        }

        fn runBatchConsumer(self: @This()) !void {
            var first: *TestSink.Node = undefined;
            var last: *TestSink.Node = undefined;

            var i: usize = 0;
            while (i < NUM_ITEMS) {
                var j = self.sink.tryPopBatch(&first, &last);
                i += j;

                while (j > 0) : (j -= 1) {
                    const next = first.next;
                    self.allocator.destroy(first);
                    first = next orelse continue;
                }
            }
        }
    };

    const allocator = testing.allocator;

    var sink: TestSink = .{};

    const consumer = try std.Thread.spawn(Context.runBatchConsumer, Context{
        .allocator = allocator,
        .sink = &sink,
    });
    defer consumer.wait();

    var producers: [NUM_PRODUCERS]*std.Thread = undefined;
    defer for (producers) |producer| producer.wait();

    for (producers) |*producer| {
        producer.* = try std.Thread.spawn(Context.runBatchProducer, Context{
            .allocator = allocator,
            .sink = &sink,
        });
    }
}
