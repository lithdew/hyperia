const std = @import("std");
const zap = @import("zap");
const clap = @import("clap");
const hyperia = @import("hyperia");

const Reactor = hyperia.Reactor;
const AsyncSocket = hyperia.AsyncSocket;
const AsyncWaitGroupAllocator = hyperia.AsyncWaitGroupAllocator;

const io = std.io;
const os = std.os;
const fmt = std.fmt;
const net = std.net;
const mem = std.mem;
const mpsc = hyperia.mpsc;
const process = std.process;
const oneshot = hyperia.oneshot;
const log = std.log.scoped(.gossip);

usingnamespace hyperia.select;

pub const log_level = .debug;

var stopped: bool = false;

var mpsc_node_pool: hyperia.ObjectPool(mpsc.Queue([]const u8).Node, 4096) = undefined;
var mpsc_sink_pool: hyperia.ObjectPool(mpsc.Sink([]const u8).Node, 4096) = undefined;

pub const Frame = struct {
    runnable: zap.Pool.Runnable = .{ .runFn = run },
    frame: anyframe,

    pub fn run(runnable: *zap.Pool.Runnable) void {
        const self = @fieldParentPtr(Frame, "runnable", runnable);
        resume self.frame;
    }
};

pub const Client = struct {
    const Self = @This();

    pub const ConnectionError = AsyncSocket.ConnectError || os.EpollCtlError || os.SocketError;

    pub const ClientStatus = enum {
        open,
        closed,
        errored,
    };

    pub const Waiter = struct {
        runnable: zap.Pool.Runnable = .{ .runFn = run },
        frame: anyframe,

        result: ConnectionError!*Connection,
        next: ?*Waiter = null,

        pub fn run(runnable: *zap.Pool.Runnable) void {
            const self = @fieldParentPtr(Waiter, "runnable", runnable);
            resume self.frame;
        }
    };

    pub const Connection = struct {
        client: *Self,
        socket: AsyncSocket,
        frame: @Frame(Connection.start),
        queue: mpsc.AsyncQueue([]const u8),
        connected: bool = false,

        pub fn start(self: *Connection, reactor: Reactor) !void {
            defer {
                log.info("???", .{});
                suspend {
                    self.cleanup();
                    self.client.wga.allocator.destroy(self);
                }
            }

            var frame: Frame = .{ .frame = @frame() };
            suspend hyperia.pool.schedule(.{}, &frame.runnable);

            // self.client.closed MUST be false when a connection is started
            // an attempt to connect is made below, which MUST suspend this function and return control to acquire()

            self.tryConnect(reactor) catch |err| {
                return self.client.reportConnectError(self, err);
            };

            // we successfully connected

            if (!self.client.reportConnected(self)) {
                return;
            }

            while (true) {
                self.run();

                var num_attempts: usize = 0;
                var last_err: ConnectionError = undefined;

                while (true) : (num_attempts += 1) {
                    if (!self.client.mayReconnect(self)) return;

                    if (num_attempts == 10) {
                        return self.client.reportConnectError(self, last_err);
                    }

                    log.info("attempt {d}: reconnecting to {}...", .{
                        num_attempts,
                        self.client.address,
                    });

                    self.tryConnect(reactor) catch |err| {
                        last_err = err;
                        continue;
                    };

                    break;
                }

                // we successfully connected

                if (!self.client.reportConnected(self)) {
                    return;
                }
            }
        }

        fn tryConnect(self: *Connection, reactor: Reactor) !void {
            self.socket = try AsyncSocket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
            errdefer self.socket.deinit();

            try reactor.add(self.socket.socket.fd, &self.socket.handle, .{ .readable = true, .writable = true });
            try self.socket.connect(self.client.address);
        }

        fn write(self: *Connection, buf: []const u8) !void {
            const node = try mpsc_node_pool.acquire(hyperia.allocator);
            node.* = .{ .value = buf };
            self.queue.push(node);
        }

        fn cleanup(self: *Connection) void {
            var first: *mpsc.Queue([]const u8).Node = undefined;
            var last: *mpsc.Queue([]const u8).Node = undefined;

            var num_items = self.queue.tryPopBatch(&first, &last);
            while (num_items > 0) : (num_items -= 1) {
                const next = first.next;
                mpsc_node_pool.release(hyperia.allocator, first);
                first = next orelse continue;
            }
        }

        fn run(self: *Connection) void {
            const Cases = struct {
                write: struct {
                    run: Case(Connection.writeLoop),
                    cancel: Case(mpsc.AsyncQueue([]const u8).cancel),
                },
                read: struct {
                    run: Case(Connection.readLoop),
                    cancel: Case(AsyncSocket.cancel),
                },
            };

            switch (select(
                Cases{
                    .write = .{
                        .run = call(Connection.writeLoop, .{self}),
                        .cancel = call(mpsc.AsyncQueue([]const u8).cancel, .{&self.queue}),
                    },
                    .read = .{
                        .run = call(Connection.readLoop, .{self}),
                        .cancel = call(AsyncSocket.cancel, .{ &self.socket, .read }),
                    },
                },
            )) {
                .write => |result| {
                    if (result) {} else |err| {
                        log.warn("write error: {}", .{err});
                    }
                },
                .read => |result| {
                    if (result) {} else |err| {
                        log.warn("read error: {}", .{err});
                    }
                },
            }
        }

        fn writeLoop(self: *Connection) !void {
            var first: *mpsc.Queue([]const u8).Node = undefined;
            var last: *mpsc.Queue([]const u8).Node = undefined;
            while (true) {
                const num_items = self.queue.popBatch(&first, &last);
                if (num_items == 0) return;

                var i: usize = 0;
                errdefer while (i < num_items) : (i += 1) {
                    const next = first.next;
                    mpsc_node_pool.release(hyperia.allocator, first);
                    first = next orelse continue;
                };

                while (i < num_items) : (i += 1) {
                    var index: usize = 0;
                    while (index < first.value.len) {
                        const num_bytes = (await (async self.socket.send(first.value[index..], os.MSG_NOSIGNAL))) catch |err| switch (err) {
                            error.ConnectionResetByPeer => return,
                            else => return err,
                        };

                        index += num_bytes;
                    }

                    const next = first.next;
                    mpsc_node_pool.release(hyperia.allocator, first);
                    first = next orelse continue;
                }
            }
        }

        fn readLoop(self: *Connection) !void {
            var buf: [4096]u8 = undefined;
            while (true) {
                const num_bytes = self.socket.recv(&buf, os.MSG_NOSIGNAL) catch |err| switch (err) {
                    error.ConnectionResetByPeer => return,
                    else => return err,
                };
                if (num_bytes == 0) return;

                const message = mem.trim(u8, buf[0..num_bytes], "\r\n");
                log.info("got message from {}: '{s}'", .{ self.client.address, message });

                try self.write("hello world\n");
            }
        }
    };

    pub const capacity = 4;

    lock: std.Thread.Mutex = .{},

    pool: [*]*Connection,
    pos: usize = 0,

    waiters: ?*Waiter = null,
    status: ClientStatus = .open,

    address: net.Address,
    wga: AsyncWaitGroupAllocator,

    pub fn init(allocator: *mem.Allocator, address: net.Address) !Client {
        return Client{
            .pool = try allocator.create([capacity]*Connection),
            .address = address,
            .wga = .{ .backing_allocator = allocator },
        };
    }

    pub fn deinit(self: *Self, allocator: *mem.Allocator) void {
        self.wga.wait();
        allocator.destroy(@ptrCast(*const [capacity]*Connection, self.pool));
    }

    pub fn close(self: *Self) void {
        const held = self.lock.acquire();
        defer held.release();

        self.status = .closed;

        for (self.pool[0..self.pos]) |conn, i| {
            log.info("closing [{d}] {}", .{ i, self.address });

            if (conn.connected) {
                conn.socket.shutdown(.both) catch {};
            }
        }
    }

    fn connect(self: *Self, reactor: Reactor) !*Connection {
        const conn = try self.wga.allocator.create(Connection);
        errdefer self.wga.allocator.destroy(conn);

        conn.client = self;
        conn.queue = .{};
        conn.connected = false;

        self.pool[self.pos] = conn;
        self.pos += 1;

        conn.frame = async conn.start(reactor);

        log.info("there are {} connections", .{self.pos});

        return conn;
    }

    fn acquire(self: *Self, reactor: Reactor) !*Connection {
        const held = self.lock.acquire();

        if (self.status == .closed) {
            held.release();
            return error.Closed;
        }

        const pool = self.pool[0..self.pos];
        if (pool.len == 0) {
            self.status = .open;

            _ = self.connect(reactor) catch |err| {
                held.release();
                return err;
            };

            var waiter: Waiter = .{ .frame = @frame(), .result = undefined };
            suspend {
                log.info("suspended 1", .{});
                waiter.next = self.waiters;
                self.waiters = &waiter;
                held.release();
            }

            log.info("resumed 1", .{});

            return waiter.result;
        }

        var min_conn = pool[0];
        var min_pending = min_conn.queue.peek();
        if (min_pending == 0 and min_conn.connected) {
            log.info("returning min conn {*}", .{min_conn});
            held.release();
            return min_conn;
        }

        for (pool[1..]) |conn| {
            if (!conn.connected) continue;

            const pending = conn.queue.peek();
            if (pending == 0) {
                log.info("returning pooled conn {*}", .{conn});
                held.release();
                return conn;
            }
            if (pending < min_pending) {
                min_conn = conn;
                min_pending = pending;
            }
        }

        if (pool.len < capacity and self.status != .errored) {
            _ = self.connect(reactor) catch |err| {
                held.release();
                return err;
            };

            var waiter: Waiter = .{ .frame = @frame(), .result = undefined };
            suspend {
                log.info("suspended 2", .{});
                waiter.next = self.waiters;
                self.waiters = &waiter;
                held.release();
            }

            if (waiter.result) |r| {
                log.info("resumed 2 (result is {*})", .{r});
                log.info("resumed 2 (connected is {})", .{r.connected});
            } else |err| {
                log.info("resumed 2 (result is {})", .{err});
            }

            return waiter.result;
        }

        if (min_conn.connected) {
            log.info("returning connected min conn {*}", .{min_conn});
            held.release();
            return min_conn;
        }

        var waiter: Waiter = .{ .frame = @frame(), .result = undefined };
        suspend {
            log.info("suspended 3", .{});
            waiter.next = self.waiters;
            self.waiters = &waiter;
            held.release();
        }

        log.info("resumed 3", .{});

        return waiter.result;
    }

    fn reportConnectError(self: *Self, conn: *Connection, err: ConnectionError) void {
        const held = self.lock.acquire();
        defer held.release();

        // only report an error if this is the only connection in the pool
        // when 'self.client.errored' is true, thenno other connections would have been established

        if (conn.connected) {
            unreachable; // should never be called if 'connected' is true
        }

        self.status = .errored;
        log.info("release connect error", .{});
        self.release(conn);

        // (maybe) ONLY wake up waiters and report the error if it is the only connection
        // in the pool

        if (self.pos > 0) return;

        var batch: zap.Pool.Batch = .{};
        defer hyperia.pool.schedule(.{}, batch);

        while (self.waiters) |waiter| : (self.waiters = waiter.next) {
            log.info("2 next is {*}", .{waiter.next});
            waiter.result = err;
            batch.push(&waiter.runnable);
        }
    }

    fn reportConnected(self: *Self, conn: *Connection) bool {
        const held = self.lock.acquire();
        defer held.release();

        // if 'self.closed', deinit the socket and return false

        if (self.status == .closed) {
            if (conn.connected) {
                unreachable; // should never be called if 'connected' is true
            }

            conn.socket.deinit();
            log.info("release connected", .{});
            self.release(conn);

            return false;
        }

        // reset 'self.status' to be open instead of errored to allow more connections to be established
        // resume all waitesr and provide them this connection

        self.status = .open;
        conn.connected = true;

        var batch: zap.Pool.Batch = .{};
        defer hyperia.pool.schedule(.{}, batch);

        while (self.waiters) |waiter| : (self.waiters = waiter.next) {
            log.info("1 next is {*}", .{waiter.next});
            waiter.result = conn;
            batch.push(&waiter.runnable);
        }

        log.info("report connected", .{});

        return true;
    }

    fn mayReconnect(self: *Self, conn: *Connection) bool {
        const held = self.lock.acquire();
        defer held.release();

        // we disconnected, see if we are allowed to reconnect or not
        // - only attempt to reconnect if we are the last client
        // - only attempt to reconnect if the client is not already closed
        // - should we only attempt to reconnect if 'self.client.errored' is true? (check) (maybe not)

        if (conn.connected) {
            conn.connected = false;
            conn.socket.deinit();
        }

        if (self.status == .closed or self.pos > 1) {
            log.info("release may reconnect", .{});
            self.release(conn);
            return false;
        }

        conn.connected = false;
        return true;
    }

    fn release(self: *Self, conn: *Connection) void {
        log.info("deallocating", .{});

        const i = mem.indexOfScalar(*Connection, self.pool[0..self.pos], conn) orelse unreachable;
        if (i == self.pos - 1) {
            self.pool[i] = undefined;
            self.pos -= 1;
            return;
        }

        self.pool[i] = self.pool[self.pos - 1];
        self.pos -= 1;
    }

    pub fn write(self: *Self, reactor: Reactor, buf: []const u8) !void {
        const conn = try self.acquire(reactor);
        mem.doNotOptimizeAway(conn);
        log.info("conn is {}", .{@ptrToInt(conn)});
        try conn.write(buf);
    }
};

pub const Node = struct {
    pub const Connection = struct {
        node: *Node,
        socket: AsyncSocket,
        address: net.Address,
        frame: @Frame(Connection.start),
        queue: mpsc.AsyncSink([]const u8) = .{},

        pub fn start(self: *Connection) !void {
            defer {
                log.info("{} has disconnected", .{self.address});
                if (self.node.deregister(self.address)) {
                    suspend {
                        self.cleanup();
                        self.socket.deinit();
                        self.node.wga.allocator.destroy(self);
                    }
                }
            }

            const Cases = struct {
                write: struct {
                    run: Case(Connection.writeLoop),
                    cancel: Case(mpsc.AsyncSink([]const u8).cancel),
                },
                read: struct {
                    run: Case(Connection.readLoop),
                    cancel: Case(AsyncSocket.cancel),
                },
            };

            switch (select(
                Cases{
                    .write = .{
                        .run = call(Connection.writeLoop, .{self}),
                        .cancel = call(mpsc.AsyncSink([]const u8).cancel, .{&self.queue}),
                    },
                    .read = .{
                        .run = call(Connection.readLoop, .{self}),
                        .cancel = call(AsyncSocket.cancel, .{ &self.socket, .read }),
                    },
                },
            )) {
                .write => |result| return result,
                .read => |result| return result,
            }
        }

        pub fn cleanup(self: *Connection) void {
            var first: *mpsc.Sink([]const u8).Node = undefined;
            var last: *mpsc.Sink([]const u8).Node = undefined;

            var num_items = self.queue.tryPopBatch(&first, &last);
            while (num_items > 0) : (num_items -= 1) {
                const next = first.next;
                mpsc_sink_pool.release(hyperia.allocator, first);
                first = next orelse continue;
            }
        }

        pub fn writeLoop(self: *Connection) !void {
            var first: *mpsc.Sink([]const u8).Node = undefined;
            var last: *mpsc.Sink([]const u8).Node = undefined;

            while (true) {
                const num_items = self.queue.popBatch(&first, &last);
                if (num_items == 0) return;

                var i: usize = 0;
                errdefer while (i < num_items) : (i += 1) {
                    const next = first.next;
                    mpsc_sink_pool.release(hyperia.allocator, first);
                    first = next orelse continue;
                };

                while (i < num_items) : (i += 1) {
                    var index: usize = 0;
                    while (index < first.value.len) {
                        index += try self.socket.send(first.value[index..], os.MSG_NOSIGNAL);
                    }

                    const next = first.next;
                    mpsc_sink_pool.release(hyperia.allocator, first);
                    first = next orelse continue;
                }
            }
        }

        pub fn readLoop(self: *Connection) !void {
            var buf: [1024]u8 = undefined;

            while (true) {
                const num_bytes = try self.socket.recv(&buf, os.MSG_NOSIGNAL);
                if (num_bytes == 0) return;
            }
        }
    };

    listener: AsyncSocket,

    wga: AsyncWaitGroupAllocator,
    lock: std.Thread.Mutex = .{},
    clients: std.AutoArrayHashMapUnmanaged(os.sockaddr, *Client) = .{},
    connections: std.AutoArrayHashMapUnmanaged(os.sockaddr, *Connection) = .{},

    pub fn init(allocator: *mem.Allocator) Node {
        return Node{ .listener = undefined, .wga = .{ .backing_allocator = allocator } };
    }

    pub fn deinit(self: *Node, allocator: *mem.Allocator) void {
        var clients: []*Client = undefined;
        defer allocator.free(clients);

        {
            const held = self.lock.acquire();
            defer held.release();

            for (self.connections.items()) |entry| {
                log.info("closing incoming connection {}", .{entry.value.address});
                entry.value.socket.shutdown(.both) catch {};
            }

            clients = allocator.alloc(*Client, self.clients.count()) catch unreachable;

            for (self.clients.items()) |entry, i| {
                log.info("closing outgoing connection {}", .{entry.value.address});
                clients[i] = entry.value;
                entry.value.close();
            }
        }

        self.wga.wait();
        self.connections.deinit(allocator);

        for (clients) |client| {
            client.deinit(allocator);
            allocator.destroy(client);
        }

        self.clients.deinit(allocator);
    }

    pub fn close(self: *Node) void {
        self.listener.shutdown(.recv) catch {};
    }

    pub fn start(self: *Node, reactor: Reactor, address: net.Address) !void {
        self.listener = try AsyncSocket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
        errdefer self.listener.deinit();

        try reactor.add(self.listener.socket.fd, &self.listener.handle, .{ .readable = true });

        try self.listener.setReuseAddress(true);
        try self.listener.setReusePort(true);
        try self.listener.setNoDelay(true);
        try self.listener.setFastOpen(true);
        try self.listener.setQuickAck(true);

        try self.listener.bind(address);
        try self.listener.listen(128);

        log.info("listening for connections on: {}", .{try self.listener.getName()});
    }

    fn accept(self: *Node, allocator: *mem.Allocator, reactor: Reactor) !void {
        while (true) {
            var conn = try self.listener.accept(os.SOCK_CLOEXEC | os.SOCK_NONBLOCK);
            errdefer conn.socket.deinit();

            try conn.socket.setNoDelay(true);

            log.info("got connection: {}", .{conn.address});

            const wga_allocator = &self.wga.allocator;

            const connection = try wga_allocator.create(Connection);
            errdefer wga_allocator.destroy(connection);

            connection.node = self;
            connection.socket = AsyncSocket.from(conn.socket);
            connection.address = conn.address;
            connection.queue = .{};

            try reactor.add(conn.socket.fd, &connection.socket.handle, .{ .readable = true, .writable = true });

            {
                const held = self.lock.acquire();
                defer held.release();

                try self.connections.put(allocator, connection.address.any, connection);
            }

            connection.frame = async connection.start();
        }
    }

    fn deregister(self: *Node, address: net.Address) bool {
        const held = self.lock.acquire();
        defer held.release();

        return self.clients.swapRemove(address.any) != null;
    }

    fn acquire(self: *Node, allocator: *mem.Allocator, address: net.Address) !*Client {
        const held = self.lock.acquire();
        defer held.release();

        const result = try self.clients.getOrPut(allocator, address.any);
        errdefer self.clients.removeAssertDiscard(address.any);

        if (!result.found_existing) {
            result.entry.value = try allocator.create(Client);
            errdefer allocator.destroy(result.entry.value);

            result.entry.value.* = try Client.init(allocator, address);
        }

        return result.entry.value;
    }

    pub fn write(self: *Node, allocator: *mem.Allocator, reactor: Reactor, address: net.Address, buf: []const u8) !void {
        const client = try self.acquire(allocator, address);
        try client.write(reactor, buf);
    }
};

pub fn runExample(options: Options, reactor: Reactor, node: *Node) !void {
    for (options.peer_addresses) |peer_address| {
        var i: usize = 0;
        while (true) {
            try node.write(hyperia.allocator, reactor, peer_address, "initial message\n");
        }
    }
    suspend;
}

pub fn runApp(options: Options, reactor: Reactor, reactor_event: *Reactor.AutoResetEvent) !void {
    defer {
        @atomicStore(bool, &stopped, true, .Release);
        reactor_event.post();
    }

    var node = Node.init(hyperia.allocator);
    defer node.deinit(hyperia.allocator);

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, 9000);
    try node.start(reactor, address);

    const Cases = struct {
        node: struct {
            run: Case(Node.accept),
            cancel: Case(Node.close),
        },
        example: struct {
            run: Case(runExample),
        },
        ctrl_c: struct {
            run: Case(hyperia.ctrl_c.wait),
            cancel: Case(hyperia.ctrl_c.cancel),
        },
    };

    switch (select(
        Cases{
            .node = .{
                .run = call(Node.accept, .{ &node, hyperia.allocator, reactor }),
                .cancel = call(Node.close, .{&node}),
            },
            .example = .{
                .run = call(runExample, .{ options, reactor, &node }),
            },
            .ctrl_c = .{
                .run = call(hyperia.ctrl_c.wait, .{}),
                .cancel = call(hyperia.ctrl_c.cancel, .{}),
            },
        },
    )) {
        .node => |result| {
            return result;
        },
        .example => |result| {
            return result;
        },
        .ctrl_c => |result| {
            log.info("shutting down...", .{});
            return result;
        },
    }
}

pub const Options = struct {
    listen_address: net.Address = net.Address.initIp4(.{ 0, 0, 0, 0 }, 9000),
    peer_addresses: []net.Address = &[_]net.Address{},

    pub fn deinit(self: Options, allocator: *mem.Allocator) void {
        allocator.free(self.peer_addresses);
    }
};

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

pub fn main() !void {
    hyperia.init();
    defer hyperia.deinit();

    hyperia.ctrl_c.init();
    defer hyperia.ctrl_c.deinit();

    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help   Display this help and exit.                ") catch unreachable,
        clap.parseParam("-l, --listen Port to listen for incoming connections on.") catch unreachable,
        clap.parseParam("<POS>...") catch unreachable,
    };

    var diagnostic: clap.Diagnostic = undefined;

    var args = clap.parse(clap.Help, &params, hyperia.allocator, &diagnostic) catch |err| {
        diagnostic.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer args.deinit();

    var options: Options = .{};
    defer options.deinit(hyperia.allocator);

    options.peer_addresses = parse: {
        var peer_addresses = try std.ArrayList(net.Address).initCapacity(hyperia.allocator, args.positionals().len);
        errdefer peer_addresses.deinit();

        for (args.positionals()) |raw_peer_address| {
            const peer_address = try parseAddress(raw_peer_address);
            peer_addresses.appendAssumeCapacity(peer_address);

            log.info("got peer address: {}", .{peer_address});
        }

        break :parse peer_addresses.toOwnedSlice();
    };

    mpsc_node_pool = try hyperia.ObjectPool(mpsc.Queue([]const u8).Node, 4096).init(hyperia.allocator);
    defer mpsc_node_pool.deinit(hyperia.allocator);

    mpsc_sink_pool = try hyperia.ObjectPool(mpsc.Sink([]const u8).Node, 4096).init(hyperia.allocator);
    defer mpsc_sink_pool.deinit(hyperia.allocator);

    const reactor = try Reactor.init(os.EPOLL_CLOEXEC);
    defer reactor.deinit();

    var reactor_event = try Reactor.AutoResetEvent.init(os.EFD_CLOEXEC, reactor);
    defer reactor_event.deinit();

    try reactor.add(reactor_event.fd, &reactor_event.handle, .{});

    var frame = async runApp(options, reactor, &reactor_event);

    while (!@atomicLoad(bool, &stopped, .Acquire)) {
        const EventProcessor = struct {
            batch: zap.Pool.Batch = .{},

            pub fn call(self: *@This(), event: Reactor.Event) void {
                const handle = @intToPtr(*Reactor.Handle, event.data);
                handle.call(&self.batch, event);
            }
        };

        var processor: EventProcessor = .{};
        defer hyperia.pool.schedule(.{}, processor.batch);

        try reactor.poll(128, &processor, null);
    }

    try nosuspend await frame;

    log.info("good bye!", .{});
}
