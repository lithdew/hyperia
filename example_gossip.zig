const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia");

const Reactor = hyperia.Reactor;
const AsyncSocket = hyperia.AsyncSocket;
const AsyncWaitGroupAllocator = hyperia.AsyncWaitGroupAllocator;

const os = std.os;
const net = std.net;
const mem = std.mem;
const mpsc = hyperia.mpsc;
const oneshot = hyperia.oneshot;
const log = std.log.scoped(.gossip);

usingnamespace hyperia.select;

pub const log_level = .debug;

var stopped: bool = false;

var mpsc_node_pool: hyperia.ObjectPool(mpsc.Sink([]const u8).Node, 4096) = undefined;

// get_client()
//      if (pooling strategy wants to create new connection)
//          return connect()
//      return existing_connection

// connect()
//      if (client connected before s.t. connection being retried)
//          oneshot channel wait
//          return oneshot channel result (connection or error)
//      status = connect()
//      if (status == fail)
//          return status.error
//      spawn client()
//      return connection

// client()
//      while (true)
//          spawn read and write workers
//          wait until either read or write worker closes
//          cleanup pending messages/requests/etc.
//          if (is_last_connection_in_pool)
//              while (true) : (reconnection_attempt += 1)
//                  status = connect()
//                  if (status == success)
//                      break
//                  if (reconnection_attempt >= max_attempts)
//                      report to oneshot channel
//                      return

pub const Client = struct {
    const Self = @This();

    pub const Connection = struct {
        client: *Self,
        socket: AsyncSocket,
        frame: @Frame(Connection.start),
        queue: mpsc.AsyncSink([]const u8),
        status: oneshot.Channel(AsyncSocket.ConnectError!void),

        pub fn start(self: *Connection) !void {
            self.socket.connect(self.client.address) catch |err| {
                if (self.status.set()) {
                    self.status.commit(err);
                }
                return err;
            };

            if (self.status.set()) {
                self.status.commit({});
            }

            defer {
                if (self.client.release(self)) {
                    suspend {
                        self.cleanup();
                        self.socket.deinit();
                        self.client.wga.allocator.destroy(self);
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
                mpsc_node_pool.release(hyperia.allocator, first);
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
        {
            const held = self.lock.acquire();
            defer held.release();

            for (self.pool[0..self.pos]) |conn, i| {
                log.info("closing [{d}] {}", .{ i, self.address });
                conn.socket.shutdown(.both) catch {};
            }
        }

        self.wga.wait();
        allocator.destroy(@ptrCast(*const [capacity]*Connection, self.pool));
    }

    fn connect(self: *Self, reactor: Reactor) !*Connection {
        const conn = try self.wga.allocator.create(Connection);
        errdefer self.wga.allocator.destroy(conn);

        conn.client = self;
        conn.queue = .{};
        conn.status = .{};

        conn.socket = try AsyncSocket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
        errdefer conn.socket.deinit();

        try reactor.add(conn.socket.socket.fd, &conn.socket.handle, .{ .readable = true, .writable = true });

        self.pool[self.pos] = conn;
        self.pos += 1;

        conn.frame = async conn.start();

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
        const pooled_conn: *Connection = connect: {
            const held = self.lock.acquire();
            defer held.release();

            const pool = self.pool[0..self.pos];
            if (pool.len == 0) {
                break :connect try self.connect(reactor);
            }

            var min_conn = pool[0];
            var min_pending: usize = 0; // pending queued writes
            if (min_pending == 0) break :connect min_conn;

            for (pool[1..]) |conn| {
                const pending: usize = 0; // pending queued writes
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

        try pooled_conn.status.wait();

        return pooled_conn;
    }

    pub fn write(self: *Self, reactor: Reactor, buf: []const u8) !void {
        const conn = try self.acquire(reactor);
        try conn.write(buf);
    }
};

pub const Node = struct {
    pub const Connection = struct {};

    listener: AsyncSocket,

    wga: AsyncWaitGroupAllocator,
    lock: std.Thread.Mutex = .{},
    connections: std.AutoArrayHashMapUnmanaged(os.sockaddr, *Connection) = .{},

    pub fn init(allocator: *mem.Allocator) Node {
        return Node{ .listener = undefined, .wga = .{ .backing_allocator = allocator } };
    }

    pub fn deinit(self: *Node, allocator: *mem.Allocator) void {
        {
            const held = self.lock.acquire();
            defer held.release();
        }

        self.wga.wait();
        self.connections.deinit(allocator);
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
            // errdefer conn.socket.deinit();
            defer conn.socket.deinit();

            log.info("got connection: {}", .{conn.address});

            const wga_allocator = &self.wga.allocator;

            // const connection = try wga_allocator.create(Connection);
            // errdefer wga_allocator.destroy(connection);

            // connection.server = self;
            // connection.socket = AsyncSocket.from(conn.socket);
            // connection.address = conn.address;
            // connection.queue = .{};

            // try reactor.add(conn.socket.fd, &connection.socket.handle, .{ .readable = true, .writable = true });

            // {
            //     const held = self.lock.acquire();
            //     defer held.release();

            //     try self.connections.put(allocator, connection.address.any, connection);
            // }

            // connection.frame = async connection.start();
        }
    }

    fn deregister(self: *Server, address: net.Address) bool {
        const held = self.lock.acquire();
        defer held.release();

        const entry = self.connections.swapRemove(address.any) orelse return false;
        return true;
    }
};

pub fn runClient(reactor: Reactor, client: *Client) !void {
    try client.write(reactor, "initial message\n");
    suspend;
}

pub fn runApp(reactor: Reactor, reactor_event: *Reactor.AutoResetEvent) !void {
    defer {
        log.info("shutting down...", .{});
        @atomicStore(bool, &stopped, true, .Release);
        reactor_event.post();
    }

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, 9000);

    var client = try Client.init(hyperia.allocator, address);
    defer client.deinit(hyperia.allocator);

    const Cases = struct {
        client: struct {
            run: Case(runClient),
        },
        ctrl_c: struct {
            run: Case(hyperia.ctrl_c.wait),
            cancel: Case(hyperia.ctrl_c.cancel),
        },
    };

    switch (select(
        Cases{
            .client = .{
                .run = call(runClient, .{ reactor, &client }),
            },
            .ctrl_c = .{
                .run = call(hyperia.ctrl_c.wait, .{}),
                .cancel = call(hyperia.ctrl_c.cancel, .{}),
            },
        },
    )) {
        .client => |result| return result,
        .ctrl_c => |result| return result,
    }
}

pub fn main() !void {
    hyperia.init();
    defer hyperia.deinit();

    hyperia.ctrl_c.init();
    defer hyperia.ctrl_c.deinit();

    mpsc_node_pool = try hyperia.ObjectPool(mpsc.Sink([]const u8).Node, 4096).init(hyperia.allocator);
    defer mpsc_node_pool.deinit(hyperia.allocator);

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
