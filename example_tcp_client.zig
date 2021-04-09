const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia");

const Timer = hyperia.Timer;
const Reactor = hyperia.Reactor;
const SpinLock = hyperia.sync.SpinLock;

const AsyncSocket = hyperia.AsyncSocket;
const CircuitBreaker = hyperia.CircuitBreaker;
const AsyncWaitGroupAllocator = hyperia.AsyncWaitGroupAllocator;

const os = std.os;
const mem = std.mem;
const net = std.net;
const meta = std.meta;
const time = std.time;
const mpmc = hyperia.mpmc;

const log = std.log.scoped(.client);
const assert = std.debug.assert;

pub const log_level = .debug;

const ConnectCircuitBreaker = CircuitBreaker(.{ .failure_threshold = 10, .reset_timeout = 1000 });

var stopped: bool = false;
var clock: time.Timer = undefined;

var reactor_event: Reactor.AutoResetEvent = undefined;
var timer: Timer = undefined;

pub const Frame = struct {
    runnable: zap.Pool.Runnable = .{ .runFn = run },
    frame: anyframe,

    fn run(runnable: *zap.Pool.Runnable) void {
        const self = @fieldParentPtr(Frame, "runnable", runnable);
        resume self.frame;
    }

    pub fn yield() void {
        var frame: Frame = .{ .frame = @frame() };
        suspend hyperia.pool.schedule(.{}, &frame.runnable);
    }
};

pub const Client = struct {
    pub const WriteQueue = mpmc.AsyncQueue([]const u8, 4096);

    pub const capacity = 4;

    pub const Waiter = struct {
        runnable: zap.Pool.Runnable = .{ .runFn = run },
        frame: anyframe,

        result: Connection.Error!void = undefined,
        next: ?*Waiter = undefined,

        pub fn run(runnable: *zap.Pool.Runnable) void {
            const self = @fieldParentPtr(Waiter, "runnable", runnable);
            resume self.frame;
        }
    };

    pub const Connection = struct {
        pub const Error = os.ConnectError;

        client: *Client,
        socket: AsyncSocket,
        connected: bool = false,
        frame: @Frame(Connection.run),

        pub fn deinit(self: *Connection) void {
            self.client.wga.allocator.destroy(self);
        }

        pub fn run(self: *Connection) !void {
            defer {
                suspend self.deinit();
            }

            var num_attempts: usize = 0;

            while (true) : (num_attempts += 1) {
                Frame.yield();

                if (self.client.connect_circuit.query(@intCast(usize, time.milliTimestamp())) == .open) {
                    assert(!self.client.reportConnectError(self, true, @errorToInt(error.NetworkUnreachable)));
                    return;
                }

                if (num_attempts > 0) {
                    log.info("{*} reconnection attempt {}", .{ self, num_attempts });
                }

                self.connect() catch |err| {
                    if (!self.client.reportConnectError(self, false, @errorToInt(err))) {
                        return;
                    }
                    continue;
                };
                defer self.socket.deinit();

                if (!self.client.reportConnected(self)) {
                    return;
                }

                num_attempts = 0;

                var popper = self.client.queue.popper();

                var read_frame = async self.readLoop();
                var write_frame = async self.writeLoop(&popper);

                _ = await read_frame;
                hyperia.pool.schedule(.{}, popper.cancel());
                _ = await write_frame;

                if (self.client.reportDisconnected(self)) {
                    return;
                }
            }
        }

        fn readLoop(self: *Connection) !void {
            defer log.info("{*} read loop ended", .{self});

            var buf: [1024]u8 = undefined;
            while (true) {
                const num_bytes = try self.socket.read(&buf);
                if (num_bytes == 0) return;
            }
        }

        fn writeLoop(self: *Connection, popper: *WriteQueue.Popper) !void {
            defer log.info("{*} write loop ended", .{self});

            while (true) {
                const buf = popper.pop() orelse return;

                var i: usize = 0;
                while (i < buf.len) {
                    i += try self.socket.send(buf[i..], os.MSG_NOSIGNAL);
                }

                Frame.yield();
            }
        }

        fn connect(self: *Connection) !void {
            self.socket = try AsyncSocket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
            errdefer self.socket.deinit();

            try self.socket.setNoDelay(true);

            try self.client.reactor.add(self.socket.socket.fd, &self.socket.handle, Reactor.Interest{
                .readable = true,
                .writable = true,
            });

            try self.socket.connect(self.client.address);
        }
    };

    lock: SpinLock = .{},

    address: net.Address,
    reactor: Reactor,

    pool: [*]*Connection,
    len: usize = 0,

    queue: WriteQueue,
    wga: AsyncWaitGroupAllocator,
    waiters: ?*Waiter = null,

    closed: bool = false,
    connect_circuit: ConnectCircuitBreaker = ConnectCircuitBreaker.init(.half_open),

    pub fn init(allocator: *mem.Allocator, reactor: Reactor, address: net.Address) !Client {
        const pool = try allocator.create([capacity]*Connection);
        errdefer allocator.destroy(pool);

        const queue = try WriteQueue.init(allocator);
        errdefer queue.deinit(allocator);

        return Client{
            .address = address,
            .reactor = reactor,
            .pool = pool,
            .queue = queue,
            .wga = .{ .backing_allocator = allocator },
        };
    }

    pub fn deinit(self: *Client, allocator: *mem.Allocator) void {
        self.wga.wait();
        self.queue.deinit(allocator);
        allocator.destroy(@ptrCast(*const [capacity]*Connection, self.pool));
    }

    pub fn close(self: *Client) void {
        self.queue.close();

        const held = self.lock.acquire();
        defer held.release();

        self.closed = true;

        for (self.pool[0..self.len]) |conn| {
            if (conn.connected) {
                conn.socket.shutdown(.both) catch {};
                log.info("{*} signalled to shutdown", .{conn});
            }
        }
    }

    pub fn write(self: *Client, buf: []const u8) !void {
        try self.ensureConnectionAvailable();
        if (!self.queue.pusher().push(buf)) return error.Closed;
    }

    /// Lock must be held. Allocates a new connection and registers it
    /// to this clients' pool of connections.
    fn spawn(self: *Client) !*Connection {
        const conn = try self.wga.allocator.create(Connection);
        errdefer self.wga.allocator.destroy(conn);

        conn.* = .{
            .client = self,
            .socket = undefined,
            .frame = undefined,
        };

        self.pool[self.len] = conn;
        self.len += 1;

        log.info("{*} got spawned", .{conn});

        return conn;
    }

    pub const PoolResult = union(enum) {
        available: void,
        spawned_pending: *Connection,
        spawned_available: *Connection,
        pending: void,
    };

    fn queryPool(self: *Client) !PoolResult {
        if (self.len == 0) {
            return PoolResult{ .spawned_pending = try self.spawn() };
        }

        const pool = self.pool[0..self.len];

        const any_connected = for (pool) |conn| {
            if (conn.connected) break true;
        } else false;

        if (self.queue.count() == 0 or pool.len == capacity) {
            return if (any_connected) PoolResult.available else PoolResult.pending;
        }

        if (any_connected) {
            return PoolResult{ .spawned_available = try self.spawn() };
        }
        return PoolResult{ .spawned_pending = try self.spawn() };
    }

    pub fn ensureConnectionAvailable(self: *Client) !void {
        const held = self.lock.acquire();

        if (self.closed) {
            held.release();
            return error.Closed;
        }

        const result = self.queryPool() catch |err| {
            held.release();
            return err;
        };

        if (result == .available) {
            held.release();
            return;
        }

        if (result == .spawned_available) {
            held.release();
            result.spawned_available.frame = async result.spawned_available.run();
            return;
        }

        var waiter: Waiter = .{ .frame = @frame() };

        suspend {
            waiter.next = self.waiters;
            self.waiters = &waiter;
            held.release();

            if (result == .spawned_pending) {
                result.spawned_pending.frame = async result.spawned_pending.run();
            }
        }

        return waiter.result;
    }

    /// Lock must be held, and connection must exist in the pool.
    fn deregister(self: *Client, conn: *Connection) void {
        const pool = self.pool[0..self.len];
        const i = mem.indexOfScalar(*Connection, pool, conn) orelse unreachable;

        log.info("connection {*} was released", .{conn});

        if (i == self.len - 1) {
            pool[i] = undefined;
            self.len -= 1;
            return;
        }

        pool[i] = pool[self.len - 1];
        self.len -= 1;
    }

    fn reportConnected(self: *Client, conn: *Connection) bool {
        log.info("{*} successfully connected", .{conn});

        const batch = collected: {
            var batch: zap.Pool.Batch = .{};

            const held = self.lock.acquire();
            defer held.release();

            assert(!conn.connected);

            if (self.closed) {
                self.deregister(conn);
                return false;
            }

            conn.connected = true;
            self.connect_circuit.reportSuccess();

            while (self.waiters) |waiter| : (self.waiters = waiter.next) {
                waiter.result = {};
                batch.push(&waiter.runnable);
            }

            break :collected batch;
        };

        hyperia.pool.schedule(.{}, batch);
        return true;
    }

    fn reportConnectError(
        self: *Client,
        conn: *Connection,
        unrecoverable: bool,
        err: meta.Int(.unsigned, @sizeOf(Connection.Error) * 8),
    ) bool {
        const batch = collect: {
            var batch: zap.Pool.Batch = .{};

            const held = self.lock.acquire();
            defer held.release();

            assert(!conn.connected);

            if (!unrecoverable) {
                log.info("{*} got an error while connecting: {}", .{
                    conn,
                    @errSetCast(Connection.Error, @intToError(err)),
                });
            }

            self.connect_circuit.reportFailure(@intCast(usize, time.milliTimestamp()));

            if (self.len > 1) {
                self.deregister(conn);
                return false;
            }

            while (self.waiters) |waiter| : (self.waiters = waiter.next) {
                waiter.result = @errSetCast(Connection.Error, @intToError(err));
                batch.push(&waiter.runnable);
            }

            break :collect batch;
        };

        hyperia.pool.schedule(.{}, batch);

        return !unrecoverable;
    }

    fn reportDisconnected(self: *Client, conn: *Connection) bool {
        const held = self.lock.acquire();
        defer held.release();

        assert(conn.connected);
        conn.connected = false;

        log.info("{*} disconnected", .{conn});

        if (self.closed or self.len > 1) {
            self.deregister(conn);
            return true;
        }

        return false;
    }
};

fn runBenchmark(client: *Client) !void {
    defer log.info("done", .{});

    var i: usize = 0;
    while (true) : (i +%= 1) {
        await async client.write("message\n") catch |err| switch (err) {
            error.Closed => return,
            else => return err,
        };

        if (i % 50 == 0) Frame.yield();
    }
}

fn runApp(reactor: Reactor) !void {
    defer {
        @atomicStore(bool, &stopped, true, .Release);
        reactor_event.post();
    }

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, 9000);

    var client = try Client.init(hyperia.allocator, reactor, address);
    defer client.deinit(hyperia.allocator);

    var benchmark_frame = async runBenchmark(&client);
    var ctrl_c_frame = async hyperia.ctrl_c.wait();

    await ctrl_c_frame;
    log.info("got ctrl+c", .{});
    client.close();
    try await benchmark_frame;
}

pub fn main() !void {
    hyperia.init();
    defer hyperia.deinit();

    hyperia.ctrl_c.init();
    defer hyperia.ctrl_c.deinit();

    clock = try time.Timer.start();

    timer = Timer.init(hyperia.allocator);
    defer timer.deinit(hyperia.allocator);

    const reactor = try Reactor.init(os.EPOLL_CLOEXEC);
    defer reactor.deinit();

    reactor_event = try Reactor.AutoResetEvent.init(os.EFD_CLOEXEC, reactor);
    defer reactor_event.deinit();

    try reactor.add(reactor_event.fd, &reactor_event.handle, .{});

    var frame = async runApp(reactor);

    while (!@atomicLoad(bool, &stopped, .Acquire)) {
        var batch: zap.Pool.Batch = .{};
        defer hyperia.pool.schedule(.{}, batch);

        try reactor.poll(128, struct {
            batch: *zap.Pool.Batch,

            pub fn call(self: @This(), event: Reactor.Event) void {
                const handle = @intToPtr(*Reactor.Handle, event.data);
                handle.call(self.batch, event);
            }
        }{ .batch = &batch }, timer.delay(clock.read()));

        timer.update(clock.read(), struct {
            batch: *zap.Pool.Batch,

            pub fn call(self: @This(), handle: *Timer.Handle) void {
                self.batch.push(handle.set());
            }
        }{ .batch = &batch });
    }

    try nosuspend await frame;

    log.info("good bye!", .{});
}
