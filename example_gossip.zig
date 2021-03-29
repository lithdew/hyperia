const std = @import("std");
const zap = @import("zap");
const clap = @import("clap");
const hyperia = @import("hyperia");

const Reactor = hyperia.Reactor;
const AsyncSocket = hyperia.AsyncSocket;
const AsyncWaitGroupAllocator = hyperia.AsyncWaitGroupAllocator;

const io = std.io;
const os = std.os;
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

pub const Client = struct {
    const Self = @This();

    pub const ConnectError = AsyncSocket.ConnectError || os.EpollCtlError || os.SocketError;

    pub const ConnectionStatus = union(enum) {
        connected: void,
        closed: void,
        failed: ConnectError,
    };

    pub const Connection = struct {
        client: *Self,
        socket: AsyncSocket,
        frame: @Frame(Connection.start),
        queue: mpsc.AsyncQueue([]const u8),
        status: oneshot.Channel(ConnectionStatus),

        pub fn start(self: *Connection, reactor: Reactor) !void {
            defer {
                if (self.client.release(self)) {
                    suspend {
                        self.cleanup();
                        self.client.wga.allocator.destroy(self);
                    }
                }
            }

            if (self.status.set()) {
                self.connect(reactor) catch |err| {
                    self.status.commit(.{ .failed = err });
                    return err;
                };

                self.status.commit(.connected);
            } else {
                return error.Cancelled;
            }

            while (true) {
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
                    .write => |result| {},
                    .read => |result| {},
                }

                const is_last_connection = check: {
                    const held = self.client.lock.acquire();
                    defer held.release();

                    // (block acquire()'s that may have got a hold of this instance)

                    if (self.status.get()) |status| {
                        if (status != .closed) {
                            self.status.reset();
                        }
                    }

                    // ... messages that leaked before self.status.reset() may still be queued
                    // (cleanup leaked messages)

                    self.cleanup();
                    self.socket.deinit();

                    break :check self.client.pos == 1;
                };

                // if we are the last client in the pool, retry
                // - if successful,   self.status.set(error.RetryAcquiringConnection) (let acquire() waiters retry and acquire this connection)
                // - if unsuccessful, self.status.set(last_connection_error); (let acquire() waiters fail stating we tried our best but couldn't acquire a connection)
                // else
                // - self.status.set(error.RetryAcquiringConnection) (let acquire() waiters find another available connection)

                if (!is_last_connection) {
                    if (self.status.set()) {
                        self.status.commit(.closed);
                    }
                    return;
                }

                var num_attempts: usize = 0;
                var last_err: ConnectError = undefined;
                while (true) : (num_attempts += 1) {
                    if (self.status.get()) |status| {
                        if (status != .closed) unreachable;
                        return error.Cancelled;
                    }

                    if (num_attempts == 10) {
                        if (self.status.set()) {
                            self.status.commit(.{ .failed = last_err });
                        }
                        return last_err;
                    }

                    log.info("attempt {d}: reconnecting to {}...", .{
                        num_attempts,
                        self.client.address,
                    });

                    self.connect(reactor) catch |err| {
                        last_err = err;
                        continue;
                    };

                    break;
                }

                if (self.status.set()) {
                    self.status.commit(.closed);
                } else {
                    self.socket.deinit();
                    return error.Cancelled;
                }
            }
        }

        fn connect(self: *Connection, reactor: Reactor) ConnectError!void {
            self.socket = try AsyncSocket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
            errdefer self.socket.deinit();

            try reactor.add(self.socket.socket.fd, &self.socket.handle, .{ .readable = true, .writable = true });
            try self.socket.connect(self.client.address);
        }

        pub fn cleanup(self: *Connection) void {
            var first: *mpsc.Queue([]const u8).Node = undefined;
            var last: *mpsc.Queue([]const u8).Node = undefined;

            var num_items = self.queue.tryPopBatch(&first, &last);
            while (num_items > 0) : (num_items -= 1) {
                const next = first.next;
                mpsc_node_pool.release(hyperia.allocator, first);
                first = next orelse continue;
            }
        }

        pub fn writeLoop(self: *Connection) !void {
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
                        index += try self.socket.send(first.value[index..], os.MSG_NOSIGNAL);
                    }

                    const next = first.next;
                    mpsc_node_pool.release(hyperia.allocator, first);
                    first = next orelse continue;
                }
            }
        }

        pub fn readLoop(self: *Connection) !void {
            var buf: [4096]u8 = undefined;
            while (true) {
                const num_bytes = try self.socket.read(&buf);
                if (num_bytes == 0) return;

                const message = mem.trim(u8, buf[0..num_bytes], "\r\n");
                log.info("got message from {}: '{s}'", .{ self.client.address, message });

                try self.write("hello world\n");
            }
        }

        fn write(self: *Connection, buf: []const u8) !void {
            const node = try mpsc_node_pool.acquire(hyperia.allocator);
            node.* = .{ .value = buf };
            self.queue.push(node);
        }
    };

    pub const capacity = 4;

    lock: std.Thread.Mutex = .{},
    closed: bool = false,

    pool: [*]*Connection,
    pos: usize = 0,

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

        self.closed = true;

        for (self.pool[0..self.pos]) |conn, i| {
            log.info("closing [{d}] {}", .{ i, self.address });

            const status = conn.status.get();
            const connected = status != null and status.? == .connected;

            conn.status.reset();
            if (conn.status.set()) conn.status.commit(.closed);
            if (!connected) continue;

            conn.socket.shutdown(.both) catch {};
        }
    }

    fn connect(self: *Self, reactor: Reactor) !*Connection {
        const conn = try self.wga.allocator.create(Connection);
        errdefer self.wga.allocator.destroy(conn);

        conn.client = self;
        conn.queue = .{};
        conn.status = .{};

        self.pool[self.pos] = conn;
        self.pos += 1;

        conn.frame = async conn.start(reactor);

        return conn;
    }

    fn release(self: *Self, conn: *Connection) bool {
        const held = self.lock.acquire();
        defer held.release();

        if (mem.indexOfScalar(*Connection, self.pool[0..self.pos], conn)) |i| {
            if (i == self.pos - 1) {
                self.pool[i] = undefined;
                self.pos -= 1;
                return true;
            }

            self.pool[i] = self.pool[self.pos - 1];
            self.pos -= 1;
            return true;
        }

        return false;
    }

    pub fn acquire(self: *Self, reactor: Reactor) !*Connection {
        while (true) {
            const pooled_conn: *Connection = connect: {
                const held = self.lock.acquire();
                defer held.release();

                if (self.closed) {
                    return error.Closed;
                }

                const pool = self.pool[0..self.pos];
                if (pool.len == 0) {
                    break :connect try self.connect(reactor);
                }

                var min_conn = pool[0];
                var min_pending: usize = min_conn.queue.peek();
                if (min_pending == 0) break :connect min_conn;

                for (pool[1..]) |conn| {
                    const pending: usize = conn.queue.peek();
                    if (pending == 0) break :connect conn;
                    if (pending < min_pending) {
                        min_conn = conn;
                        min_pending = pending;
                    }
                }

                if (pool.len < capacity) {
                    break :connect try self.connect(reactor);
                }

                break :connect min_conn;
            };

            switch (pooled_conn.status.wait()) {
                .failed => |err| return err,
                .closed => continue,
                else => {},
            }

            return pooled_conn;
        }
    }

    pub fn write(self: *Self, reactor: Reactor, buf: []const u8) !void {
        const conn = try self.acquire(reactor);
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
        try self.listener.bind(address);
        try self.listener.listen(128);

        log.info("listening for connections on: {}", .{try self.listener.getName()});
    }

    fn accept(self: *Node, allocator: *mem.Allocator, reactor: Reactor) !void {
        while (true) {
            var conn = try self.listener.accept(os.SOCK_CLOEXEC | os.SOCK_NONBLOCK);
            errdefer conn.socket.deinit();

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

        const entry = self.connections.swapRemove(address.any) orelse return false;
        return true;
    }

    fn acquire(self: *Node, allocator: *mem.Allocator, address: net.Address) !*Client {
        const held = self.lock.acquire();
        defer held.release();

        try self.clients.ensureCapacity(allocator, self.clients.capacity() + 1);

        const result = self.clients.getOrPutAssumeCapacity(address.any);
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

pub fn runExample(reactor: Reactor, node: *Node) !void {
    try node.write(hyperia.allocator, reactor, net.Address.initIp4(.{ 0, 0, 0, 0 }, 9001), "initial message\n");
    suspend;
}

pub fn runApp(reactor: Reactor, reactor_event: *Reactor.AutoResetEvent) !void {
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
                .run = call(runExample, .{ reactor, &node }),
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

    log.info("args positionals: {s}", .{args.positionals()});

    mpsc_node_pool = try hyperia.ObjectPool(mpsc.Queue([]const u8).Node, 4096).init(hyperia.allocator);
    defer mpsc_node_pool.deinit(hyperia.allocator);

    mpsc_sink_pool = try hyperia.ObjectPool(mpsc.Sink([]const u8).Node, 4096).init(hyperia.allocator);
    defer mpsc_sink_pool.deinit(hyperia.allocator);

    const reactor = try Reactor.init(os.EPOLL_CLOEXEC);
    defer reactor.deinit();

    var reactor_event = try Reactor.AutoResetEvent.init(os.EFD_CLOEXEC, reactor);
    defer reactor_event.deinit();

    try reactor.add(reactor_event.fd, &reactor_event.handle, .{});

    var frame = async runApp(reactor, &reactor_event);

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
