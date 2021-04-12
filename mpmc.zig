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

    /// Cancels a waiter so that the waiter may be manually resumed.
    /// Returns true if the waiter may be manually resumed, and false
    /// otherwise because a setter appears to have already resumed
    /// the waiter.
    pub fn cancel(self: *Self) bool {
        var state = @atomicLoad(u64, &self.state, .Monotonic);
        while (true) {
            if (getSetterCount(state) >= getWaiterCount(state)) return false;

            state = @cmpxchgWeak(
                u64,
                &self.state,
                state,
                state - waiter_increment,
                .AcqRel,
                .Acquire,
            ) orelse return true;
        }
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

pub const Semaphore = struct {
    const Self = @This();

    pub const Waiter = struct {
        runnable: zap.Pool.Runnable = .{ .runFn = run },
        frame: anyframe,

        parent: *Self,
        prev: ?*Waiter = null,
        next: ?*Waiter = null,
        cancelled: bool = false,
    };

    tokens: usize = 0,

    lock: hyperia.sync.SpinLock = .{},
    waiters: ?*Waiter = null,

    pub fn init(tokens: usize) Self {
        return .{ .tokens = tokens };
    }

    pub fn signal(self: *Self) void {
        var tokens = @atomicLoad(usize, &self.tokens, .Monotonic);
        while (true) {
            while (tokens == 0) {
                if (self.signalSlow()) return;
                tokens = @atomicLoad(usize, &self.tokens, .Acquire);
            }

            tokens = @cmpxchgWeak(
                usize,
                &self.tokens,
                tokens,
                tokens + 1,
                .Release,
                .Acquire,
            ) orelse return;
        }
    }

    fn signalSlow(self: *Self) bool {
        var waiter: *Waiter = wake: {
            const held = self.lock.acquire();
            defer held.release();

            const tokens = @atomicLoad(usize, &self.tokens, .Acquire);
            if (tokens != 0) return false;

            const waiter = self.waiters orelse {
                assert(@cmpxchgStrong(
                    usize,
                    &self.tokens,
                    tokens,
                    tokens + 1,
                    .Monotonic,
                    .Monotonic,
                ) == null);
                return true;
            };

            if (waiter.next) |next| {
                next.prev = null;
            }
            self.waiters = waiter.next;

            break :wake waiter;
        };

        hyperia.pool.schedule(.{}, &waiter.runnable);
        return true;
    }

    pub fn wait(self: *Self, waiter: *Waiter) void {
        var tokens = @atomicLoad(usize, &self.tokens, .Acquire);
        while (true) {
            while (tokens == 0) {
                suspend {
                    waiter.frame = @frame();
                    if (!self.waitSlow(waiter)) {
                        hyperia.pool.schedule(.{}, &waiter.runnable);
                    }
                }
                tokens = @atomicLoad(usize, &self.tokens, .Acquire);
            }

            tokens = @cmpxchgWeak(
                usize,
                &self.tokens,
                tokens,
                tokens - 1,
                .Release,
                .Acquire,
            ) orelse return;
        }
    }

    fn waitSlow(self: *Self, waiter: *Waiter) bool {
        const held = self.lock.acquire();
        defer held.release();

        const tokens = @atomicLoad(usize, &self.tokens, .Acquire);
        if (tokens != 0) return false;

        if (self.waiters) |head| {
            head.prev = waiter;
        }
        waiter.next = self.waiters;
        self.waiters = waiter;

        return true;
    }
};

pub const Event = struct {
    const Self = @This();

    pub const State = enum {
        unset,
        set,
    };

    pub const Waiter = struct {
        runnable: zap.Pool.Runnable = .{ .runFn = run },
        frame: anyframe,

        parent: *Event,
        prev: ?*Waiter = null,
        next: ?*Waiter = null,
        cancelled: bool = false,

        fn run(runnable: *zap.Pool.Runnable) void {
            const self = @fieldParentPtr(Waiter, "runnable", runnable);
            resume self.frame;
        }

        pub fn cancel(self: *Waiter) ?*zap.Pool.Runnable {
            const runnable = collect: {
                const held = self.parent.lock.acquire();
                defer held.release();

                if (self.cancelled) return null;

                self.cancelled = true;

                if (self.prev == null and self.next == null) return null;
                if (self.parent.waiters == self) return null;

                if (self.prev) |prev| {
                    prev.next = self.next;
                    self.prev = null;
                } else {
                    self.parent.waiters = self.next;
                }

                if (self.next) |next| {
                    next.prev = self.prev;
                    self.next = null;
                }

                break :collect &self.runnable;
            };

            return runnable;
        }

        /// Waits until the parenting event is set. It returns true
        /// if this waiter was not cancelled, and false otherwise.
        pub fn wait(self: *Waiter) bool {
            const held = self.parent.lock.acquire();

            if (self.cancelled) {
                held.release();
                return false;
            }

            if (self.parent.state == .set) {
                self.parent.state = .unset;
                held.release();
                return true;
            }

            suspend {
                self.frame = @frame();
                if (self.parent.waiters) |waiter| {
                    waiter.prev = self;
                }
                self.next = self.parent.waiters;
                self.parent.waiters = self;
                held.release();
            }

            assert(self.prev == null);
            assert(self.next == null);

            return !self.cancelled;
        }
    };

    lock: hyperia.sync.SpinLock = .{},
    state: State = .unset,
    waiters: ?*Waiter = null,

    pub fn set(self: *Self) ?*zap.Pool.Runnable {
        const runnable: ?*zap.Pool.Runnable = collect: {
            const held = self.lock.acquire();
            defer held.release();

            if (self.state == .set) {
                break :collect null;
            }

            if (self.waiters) |waiter| {
                self.waiters = waiter.next;
                waiter.next = null;
                waiter.prev = null;
                break :collect &waiter.runnable;
            } else {
                self.state = .set;
                break :collect null;
            }
        };

        return runnable;
    }

    pub fn createWaiter(self: *Self) Waiter {
        return Waiter{ .parent = self, .frame = undefined };
    }
};

pub fn AsyncQueue(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        const Self = @This();

        queue: Queue(T, capacity),
        closed: bool = false,
        producer_event: Event = .{},
        consumer_event: Event = .{},

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

        pub fn close(self: *Self) void {
            @atomicStore(bool, &self.closed, true, .Monotonic);
            while (true) {
                var batch: zap.Pool.Batch = .{};
                batch.push(self.producer_event.set());
                batch.push(self.consumer_event.set());
                if (batch.isEmpty()) break;
                hyperia.pool.schedule(.{}, batch);
            }
        }

        pub const Pusher = struct {
            parent: *Self,
            waiter: Event.Waiter,

            pub fn cancel(self: *Pusher) ?*zap.Pool.Runnable {
                return self.waiter.cancel();
            }

            pub fn push(self: *Pusher, item: T) bool {
                while (!@atomicLoad(bool, &self.parent.closed, .Monotonic)) {
                    if (self.parent.tryPush(item)) {
                        hyperia.pool.schedule(.{}, self.parent.consumer_event.set());
                        return true;
                    }
                    if (!self.waiter.wait()) return false;
                }
                return false;
            }
        };

        pub const Popper = struct {
            parent: *Self,
            waiter: Event.Waiter,

            pub fn cancel(self: *Popper) ?*zap.Pool.Runnable {
                return self.waiter.cancel();
            }

            pub fn pop(self: *Popper) ?T {
                while (!@atomicLoad(bool, &self.parent.closed, .Monotonic)) {
                    if (self.parent.tryPop()) |item| {
                        hyperia.pool.schedule(.{}, self.parent.producer_event.set());
                        return item;
                    }
                    if (!self.waiter.wait()) return null;
                }
                return null;
            }
        };

        pub fn pusher(self: *Self) Pusher {
            return Pusher{ .parent = self, .waiter = self.producer_event.createWaiter() };
        }

        pub fn popper(self: *Self) Popper {
            return Popper{ .parent = self, .waiter = self.consumer_event.createWaiter() };
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
    testing.refAllDecls(Event);
    testing.refAllDecls(Semaphore);
    testing.refAllDecls(Queue(u64, 128));
    testing.refAllDecls(AsyncQueue(u64, 128));
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
