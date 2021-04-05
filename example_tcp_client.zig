const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia");

const Reactor = hyperia.Reactor;
const SpinLock = hyperia.sync.SpinLock;
const AsyncSocket = hyperia.AsyncSocket;
const AsyncWaitGroupAllocator = hyperia.AsyncWaitGroupAllocator;

const os = std.os;
const mem = std.mem;
const net = std.net;
const meta = std.meta;

const log = std.log.scoped(.client);
const assert = std.debug.assert;

var stopped: bool = false;

var reactor_event: Reactor.AutoResetEvent = undefined;

pub const Frame = struct {
    runnable: zap.Pool.Runnable = .{ .runFn = run },
    frame: anyframe,

    pub fn run(runnable: *zap.Pool.Runnable) void {
        const self = @fieldParentPtr(Frame, "runnable", runnable);
        resume self.frame;
    }

    pub fn yield() void {
        var frame: Frame = .{ .frame = @frame() };
        suspend hyperia.pool.schedule(.{}, &frame.runnable);
    }
};

pub const Client = struct {
    pub const capacity = 1;

    pub const Status = enum {
        open,
        closed,
        errored,
    };

    pub const Waiter = struct {
        runnable: zap.Pool.Runnable = .{ .runFn = run },
        frame: anyframe,

        result: Connection.Error!*Connection,
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

            self.connect() catch |err| {
                self.client.reportConnectError(self, @errorToInt(err));
                return err;
            };

            if (!self.client.reportConnected(self)) {
                return;
            }

            log.info("successfully connected", .{});

            var read_frame = async self.readLoop();
            var write_frame = async self.writeLoop();

            _ = await read_frame;
            _ = await write_frame;

            if (self.client.reportDisconnected(self)) {
                return;
            }

            self.client.reportConnectError(self, @errorToInt(error.NetworkUnreachable));
        }

        fn readLoop(self: *Connection) !void {
            var buf: [1024]u8 = undefined;
            while (true) {
                const num_bytes = try self.socket.read(&buf);
                if (num_bytes == 0) return;
            }
        }

        fn writeLoop(self: *Connection) !void {
            const message = "message\n";

            while (true) {
                var i: usize = 0;
                while (i < message.len) {
                    i += try self.socket.send(message[i..], os.MSG_NOSIGNAL);
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

    wga: AsyncWaitGroupAllocator,
    waiters: ?*Waiter = null,
    status: Status = .open,

    pub fn init(allocator: *mem.Allocator, reactor: Reactor, address: net.Address) !Client {
        const pool = try allocator.create([capacity]*Connection);
        errdefer allocator.destroy(pool);

        return Client{
            .address = address,
            .reactor = reactor,
            .pool = pool,
            .wga = .{ .backing_allocator = allocator },
        };
    }

    pub fn deinit(self: *Client, allocator: *mem.Allocator) void {
        self.wga.wait();
        allocator.destroy(@ptrCast(*const [capacity]*Connection, self.pool));
    }

    pub fn close(self: *Client) void {
        const held = self.lock.acquire();
        defer held.release();

        self.status = .closed;

        for (self.pool[0..self.len]) |conn| {
            if (conn.connected) {
                conn.socket.shutdown(.both) catch {};
            }
        }
    }

    pub const FetchResult = union(enum) {
        available: *Connection,
        spawned: *Connection,
        pending: void,
    };

    fn tryFetch(self: *Client) !FetchResult {
        if (self.len == 0) {
            const conn = try self.wga.allocator.create(Connection);
            errdefer self.wga.allocator.destroy(conn);

            conn.* = .{ .client = self, .socket = undefined, .frame = undefined };

            self.pool[self.len] = conn;
            self.len += 1;

            self.status = .open;

            return FetchResult{ .spawned = conn };
        }

        if (!self.pool[0].connected) {
            return FetchResult.pending;
        }

        return FetchResult{ .available = self.pool[0] };
    }

    pub fn fetch(self: *Client) !*Connection {
        const held = self.lock.acquire();

        if (self.status == .closed) {
            held.release();
            return error.Closed;
        }

        const result = self.tryFetch() catch |err| {
            held.release();
            return err;
        };

        if (result == .available) {
            held.release();
            return result.available;
        }

        var waiter: Waiter = .{ .frame = @frame(), .result = undefined };
        suspend {
            waiter.next = self.waiters;
            self.waiters = &waiter;
            held.release();

            if (result == .spawned) {
                result.spawned.frame = async result.spawned.run();
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
        const batch = collected: {
            var batch: zap.Pool.Batch = .{};

            const held = self.lock.acquire();
            defer held.release();

            assert(!conn.connected);

            if (self.status == .closed) {
                conn.socket.deinit();
                self.deregister(conn);
                return false;
            }

            self.status = .open;
            conn.connected = true;

            while (self.waiters) |waiter| : (self.waiters = waiter.next) {
                waiter.result = conn;
                batch.push(&waiter.runnable);
            }

            break :collected batch;
        };

        hyperia.pool.schedule(.{}, batch);
        return true;
    }

    fn reportConnectError(self: *Client, conn: *Connection, err: meta.Int(.unsigned, @sizeOf(Connection.Error) * 8)) void {
        const batch = collect: {
            var batch: zap.Pool.Batch = .{};

            const held = self.lock.acquire();
            defer held.release();

            assert(!conn.connected);

            if (self.status != .closed) {
                self.status = .errored;
            }

            self.status = .errored;
            self.deregister(conn);

            // Only the last pooled connection reports an error.

            if (self.len > 0) {
                return;
            }

            while (self.waiters) |waiter| : (self.waiters = waiter.next) {
                waiter.result = @errSetCast(Connection.Error, @intToError(err));
                batch.push(&waiter.runnable);
            }

            break :collect batch;
        };

        hyperia.pool.schedule(.{}, batch);
    }

    fn reportDisconnected(self: *Client, conn: *Connection) bool {
        const held = self.lock.acquire();
        defer held.release();

        assert(conn.connected);
        conn.connected = false;

        if (self.status == .closed or self.len > 1) {
            conn.socket.deinit();
            self.deregister(conn);
            return true;
        }

        conn.socket.deinit();
        return false;
    }
};

fn runBenchmark(client: *Client) !void {
    defer log.info("done", .{});

    var i: usize = 0;
    while (i < 1_000_000) : (i += 1) {
        var conn = try await async client.fetch();
        Frame.yield();
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
        }{ .batch = &batch }, null);
    }

    try nosuspend await frame;

    log.info("good bye!", .{});
}
