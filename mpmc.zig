const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia.zig");

const os = std.os;
const mem = std.mem;
const math = std.math;
const builtin = std.builtin;
const testing = std.testing;

const assert = std.debug.assert;

pub const cache_line_length = switch (builtin.cpu.arch) {
    .x86_64, .aarch64, .powerpc64 => 128,
    .arm, .mips, .mips64, .riscv64 => 32,
    .s390x => 256,
    else => 64,
};

pub const AsyncAutoResetEvent = struct {
    const Self = @This();

    const Waiter = struct {
        runnable: zap.Pool.Runnable = .{ .runFn = run },
        frame: anyframe,

        next: ?*Waiter = null,
        refs: u32 = 2,

        pub fn run(runnable: *zap.Pool.Runnable) void {
            const self = @fieldParentPtr(Waiter, "runnable", runnable);
            resume self.frame;
        }
    };

    const setter_increment: u64 = 1;
    const waiter_increment: u64 = @as(u64, 1) << 32;

    state: u64 = 0,
    waiters: ?*Waiter = null,
    new_waiters: ?*Waiter = null,

    fn getSetterCount(state: u64) callconv(.Inline) u32 {
        return @truncate(u32, state);
    }

    fn getWaiterCount(state: u64) callconv(.Inline) u32 {
        return @intCast(u32, state >> 32);
    }

    pub fn wait(self: *Self) void {
        var state = @atomicLoad(u64, &self.state, .Monotonic);
        if (getSetterCount(state) > getWaiterCount(state)) {
            if (@cmpxchgStrong(
                u64,
                &self.state,
                state,
                state - setter_increment,
                .Acquire,
                .Monotonic,
            ) == null) return;
        }
        self.park();
    }

    pub fn set(self: *Self) zap.Pool.Batch {
        var state = @atomicLoad(u64, &self.state, .Monotonic);
        while (true) {
            if (getSetterCount(state) > getWaiterCount(state)) return .{};

            state = @cmpxchgWeak(
                u64,
                &self.state,
                state,
                state + setter_increment,
                .AcqRel,
                .Acquire,
            ) orelse break;
        }

        if (getSetterCount(state) == 0 and getWaiterCount(state) > 0) {
            return self.unpark(state + setter_increment);
        }

        return .{};
    }

    fn park(self: *Self) void {
        var waiter: Waiter = .{ .frame = @frame() };

        suspend {
            var head = @atomicLoad(?*Waiter, &self.new_waiters, .Monotonic);
            while (true) {
                waiter.next = head;

                head = @cmpxchgWeak(
                    ?*Waiter,
                    &self.new_waiters,
                    head,
                    &waiter,
                    .Release,
                    .Monotonic,
                ) orelse break;
            }

            var batch: zap.Pool.Batch = .{};
            defer hyperia.pool.schedule(.{}, batch);

            var state = @atomicRmw(u64, &self.state, .Add, waiter_increment, .AcqRel);
            if (getSetterCount(state) > 0 and getWaiterCount(state) == 0) {
                batch.push(self.unpark(state + waiter_increment));
            }

            if (@atomicRmw(u32, &waiter.refs, .Sub, 1, .Acquire) == 1) {
                batch.push(&waiter.runnable);
            }
        }
    }

    fn unpark(self: *Self, state: u64) zap.Pool.Batch {
        var batch: zap.Pool.Batch = .{};
        var waiters_to_resume: ?*Waiter = null;
        var waiters_to_resume_tail: *?*Waiter = &waiters_to_resume;

        var num_waiters_to_resume: u64 = math.min(getWaiterCount(state), getSetterCount(state));
        assert(num_waiters_to_resume > 0);

        while (num_waiters_to_resume != 0) {
            var i: usize = 0;
            while (i < num_waiters_to_resume) : (i += 1) {
                if (self.waiters == null) {
                    var new_waiters = @atomicRmw(?*Waiter, &self.new_waiters, .Xchg, null, .Acquire);
                    assert(new_waiters != null);

                    while (new_waiters) |new_waiter| {
                        const next = new_waiter.next;
                        new_waiter.next = self.waiters;
                        self.waiters = new_waiter;
                        new_waiters = next;
                    }
                }

                const waiter_to_resume = self.waiters orelse unreachable;
                self.waiters = waiter_to_resume.next;

                waiter_to_resume.next = null;
                waiters_to_resume_tail.* = waiter_to_resume;
                waiters_to_resume_tail = &waiter_to_resume.next;
            }

            const delta = num_waiters_to_resume | (num_waiters_to_resume << 32);
            const new_state = @atomicRmw(u64, &self.state, .Sub, delta, .AcqRel) - delta;
            num_waiters_to_resume = math.min(getWaiterCount(new_state), getSetterCount(new_state));
        }

        assert(waiters_to_resume != null);

        while (waiters_to_resume) |waiter| {
            const next = waiter.next;
            if (@atomicRmw(u32, &waiter.refs, .Sub, 1, .Release) == 1) {
                batch.push(&waiter.runnable);
            }
            waiters_to_resume = next;
        }

        return batch;
    }
};

pub fn AsyncQueue(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();

        const READY = 0;
        const CANCELLED = 1;

        queue: Queue(T, capacity),
        producer_event: AsyncAutoResetEvent = .{},
        consumer_event: AsyncAutoResetEvent = .{},

        pub fn init(allocator: *mem.Allocator) !Self {
            return Self{ .queue = try Queue(T, capacity).init(allocator) };
        }

        pub fn deinit(self: *Self, allocator: *mem.Allocator) void {
            self.queue.deinit(allocator);
        }

        pub fn tryPush(self: *Self, item: T) bool {
            return self.queue.tryPush(item);
        }

        pub fn tryPop(self: *Self) ?T {
            return self.queue.tryPop();
        }

        pub fn count(self: *Self) usize {
            return self.queue.count();
        }

        pub fn push(self: *Self, item: T) void {
            while (!self.tryPush(item)) {
                self.producer_event.wait();
            }

            self.consumer_event.set();
        }

        pub fn pop(self: *Self) T {
            while (true) {
                if (self.tryPop()) |item| {
                    self.producer_event.set();
                    return item;
                }
                self.consumer_event.wait();
            }
        }
    };
}

pub fn Queue(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            sequence: usize align(cache_line_length),
            item: T,
        };

        entries: [*]Entry align(cache_line_length),
        enqueue_pos: usize align(cache_line_length),
        dequeue_pos: usize align(cache_line_length),

        pub fn init(allocator: *mem.Allocator) !Self {
            const entries = try allocator.create([capacity]Entry);
            for (entries) |*entry, i| entry.sequence = i;

            return Self{
                .entries = entries,
                .enqueue_pos = 0,
                .dequeue_pos = 0,
            };
        }

        pub fn deinit(self: *Self, allocator: *mem.Allocator) void {
            allocator.destroy(@ptrCast(*const [capacity]Entry, self.entries));
        }

        pub fn count(self: *Self) usize {
            const tail = @atomicLoad(usize, &self.dequeue_pos, .Monotonic);
            const head = @atomicLoad(usize, &self.enqueue_pos, .Monotonic);
            return (tail -% head) % (capacity - 1);
        }

        pub fn tryPush(self: *Self, item: T) bool {
            var entry: *Entry = undefined;
            var pos = @atomicLoad(usize, &self.enqueue_pos, .Monotonic);
            while (true) : (os.sched_yield() catch {}) {
                entry = &self.entries[pos & (capacity - 1)];

                const seq = @atomicLoad(usize, &entry.sequence, .Acquire);
                const diff = @intCast(isize, seq) -% @intCast(isize, pos);
                if (diff == 0) {
                    pos = @cmpxchgWeak(usize, &self.enqueue_pos, pos, pos +% 1, .Monotonic, .Monotonic) orelse {
                        break;
                    };
                } else if (diff < 0) {
                    return false;
                } else {
                    pos = @atomicLoad(usize, &self.enqueue_pos, .Monotonic);
                }
            }
            entry.item = item;
            @atomicStore(usize, &entry.sequence, pos +% 1, .Release);
            return true;
        }

        pub fn tryPop(self: *Self) ?T {
            var entry: *Entry = undefined;
            var pos = @atomicLoad(usize, &self.dequeue_pos, .Monotonic);
            while (true) : (os.sched_yield() catch {}) {
                entry = &self.entries[pos & (capacity - 1)];

                const seq = @atomicLoad(usize, &entry.sequence, .Acquire);
                const diff = @intCast(isize, seq) -% @intCast(isize, pos +% 1);
                if (diff == 0) {
                    pos = @cmpxchgWeak(usize, &self.dequeue_pos, pos, pos +% 1, .Monotonic, .Monotonic) orelse {
                        break;
                    };
                } else if (diff < 0) {
                    return null;
                } else {
                    pos = @atomicLoad(usize, &self.dequeue_pos, .Monotonic);
                }
            }
            const item = entry.item;
            @atomicStore(usize, &entry.sequence, pos +% (capacity - 1) +% 1, .Release);
            return item;
        }
    };
}

test {
    testing.refAllDecls(@This());
}

test "mpmc/auto_reset_event: set and wait" {
    hyperia.init();
    defer hyperia.deinit();

    var event: AsyncAutoResetEvent = .{};

    testing.expect(event.set().isEmpty());
    testing.expect(event.set().isEmpty());
    testing.expect(event.set().isEmpty());
    testing.expect(AsyncAutoResetEvent.getSetterCount(event.state) == 1);
    nosuspend event.wait();
    testing.expect(AsyncAutoResetEvent.getSetterCount(event.state) == 0);

    var a = async event.wait();
    testing.expect(AsyncAutoResetEvent.getWaiterCount(event.state) == 1);
    var b = async event.wait();
    testing.expect(AsyncAutoResetEvent.getWaiterCount(event.state) == 2);
    var c = async event.wait();
    testing.expect(AsyncAutoResetEvent.getWaiterCount(event.state) == 3);

    event.set().pop().?.run();
    testing.expect(AsyncAutoResetEvent.getSetterCount(event.state) == 0);
    testing.expect(AsyncAutoResetEvent.getWaiterCount(event.state) == 2);
    nosuspend await a;

    event.set().pop().?.run();
    testing.expect(AsyncAutoResetEvent.getSetterCount(event.state) == 0);
    testing.expect(AsyncAutoResetEvent.getWaiterCount(event.state) == 1);
    nosuspend await b;

    event.set().pop().?.run();
    testing.expect(AsyncAutoResetEvent.getSetterCount(event.state) == 0);
    testing.expect(AsyncAutoResetEvent.getWaiterCount(event.state) == 0);
    nosuspend await c;
}

test "mpmc/queue: push and pop 60,000 u64s with 4 producers and 4 consumers" {
    const NUM_ITEMS = 60_000;
    const NUM_PRODUCERS = 4;
    const NUM_CONSUMERS = 4;

    const TestQueue = Queue(u64, 2048);

    const Context = struct {
        queue: *TestQueue,

        fn runProducer(self: @This()) !void {
            var i: usize = 0;
            while (i < NUM_ITEMS / NUM_PRODUCERS) : (i += 1) {
                while (true) {
                    if (self.queue.tryPush(@intCast(u64, i))) {
                        break;
                    }
                }
            }
        }

        fn runConsumer(self: @This()) !void {
            var i: usize = 0;
            while (i < NUM_ITEMS / NUM_CONSUMERS) : (i += 1) {
                while (true) {
                    if (self.queue.tryPop() != null) {
                        break;
                    }
                }
            }
        }
    };

    const allocator = testing.allocator;

    var queue = try TestQueue.init(allocator);
    defer queue.deinit(allocator);

    var producers: [NUM_PRODUCERS]*std.Thread = undefined;
    defer for (producers) |producer| producer.wait();

    var consumers: [NUM_CONSUMERS]*std.Thread = undefined;
    defer for (consumers) |consumer| consumer.wait();

    for (consumers) |*consumer| consumer.* = try std.Thread.spawn(Context.runConsumer, Context{ .queue = &queue });
    for (producers) |*producer| producer.* = try std.Thread.spawn(Context.runProducer, Context{ .queue = &queue });
}
