const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia");
const picohttp = @import("picohttp");
const Reactor = hyperia.Reactor;
const AsyncSocket = hyperia.AsyncSocket;
const AsyncWaitGroupAllocator = hyperia.AsyncWaitGroupAllocator;

const os = std.os;
const net = std.net;
const mem = std.mem;
const math = std.math;
const mpsc = hyperia.mpsc;
const log = std.log.scoped(.server);

usingnamespace hyperia.select;

pub const log_level = .debug;

var stopped: bool = false;

var pool: hyperia.ObjectPool(mpsc.Sink([]const u8).Node, 4096) = undefined;

pub const Server = struct {
    pub const Connection = struct {
        server: *Server,
        socket: AsyncSocket,
        address: net.Address,
        frame: @Frame(Connection.start),
        queue: mpsc.AsyncSink([]const u8) = .{},

        pub fn start(self: *Connection) !void {
            defer {
                // log.info("{} has disconnected", .{self.address});

                if (self.server.deregister(self.address)) {
                    suspend {
                        self.cleanup();
                        self.socket.deinit();
                        self.server.wga.allocator.destroy(self);
                    }
                }
            }

            const Cases = struct {
                write: struct {
                    run: Case(Connection.writeLoop),
                    cancel: Case(mpsc.AsyncSink([]const u8).close),
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
                        .cancel = call(mpsc.AsyncSink([]const u8).close, .{&self.queue}),
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

            while (true) {
                var num_items = self.queue.tryPopBatch(&first, &last);
                if (num_items == 0) break;

                while (num_items > 0) : (num_items -= 1) {
                    const next = first.next;
                    pool.release(hyperia.allocator, first);
                    first = next orelse continue;
                }
            }
        }

        pub fn writeLoop(self: *Connection) !void {
            var first: *mpsc.Sink([]const u8).Node = undefined;
            var last: *mpsc.Sink([]const u8).Node = undefined;

            while (true) {
                const num_items = self.queue.popBatch(&first, &last);
                if (num_items == 0) return;

                var i: usize = 0;
                defer while (i < num_items) : (i += 1) {
                    const next = first.next;
                    pool.release(hyperia.allocator, first);
                    first = next orelse continue;
                };

                while (i < num_items) : (i += 1) {
                    var index: usize = 0;
                    while (index < first.value.len) {
                        index += try self.socket.send(first.value[index..], os.MSG_NOSIGNAL);
                    }

                    const next = first.next;
                    pool.release(hyperia.allocator, first);
                    first = next orelse continue;
                }
            }
        }

        pub fn readLoop(self: *Connection) !void {
            var buf = std.ArrayList(u8).init(hyperia.allocator);
            defer buf.deinit();

            var headers: [128]picohttp.Header = undefined;

            while (true) {
                const old_len = buf.items.len;
                try buf.ensureCapacity(4096);
                buf.items.len = buf.capacity;

                const num_bytes = try self.socket.recv(buf.items[old_len..], os.MSG_NOSIGNAL);
                if (num_bytes == 0) return;

                buf.items.len = old_len + num_bytes;

                const end_idx = mem.indexOf(u8, buf.items[old_len - math.min(old_len, 4) ..], "\r\n\r\n") orelse continue;

                const req = try picohttp.Request.parse(buf.items[0 .. end_idx + 4], &headers);

                // std.debug.print("Method: {s}\n", .{req.method});
                // std.debug.print("Path: {s}\n", .{req.path});
                // std.debug.print("Minor Version: {}\n", .{req.minor_version});

                // for (req.headers) |header| {
                //     std.debug.print("{}\n", .{header});
                // }

                const RES = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 12\r\n\r\nHello world!";

                const node = try pool.acquire(hyperia.allocator);
                node.* = .{ .value = RES };
                self.queue.push(node);

                buf.items.len = 0;
            }
        }
    };

    listener: AsyncSocket,

    wga: AsyncWaitGroupAllocator,
    lock: std.Thread.Mutex = .{},
    connections: std.AutoArrayHashMapUnmanaged(os.sockaddr, *Connection) = .{},

    pub fn init(allocator: *mem.Allocator) Server {
        return Server{
            .listener = undefined,
            .wga = .{ .backing_allocator = allocator },
        };
    }

    pub fn deinit(self: *Server, allocator: *mem.Allocator) void {
        {
            const held = self.lock.acquire();
            defer held.release();

            for (self.connections.items()) |entry| {
                log.info("closing {}", .{entry.value.address});
                entry.value.socket.shutdown(.both) catch {};
            }
        }

        self.wga.wait();
        self.connections.deinit(allocator);
    }

    pub fn close(self: *Server) void {
        self.listener.shutdown(.recv) catch {};
    }

    pub fn start(self: *Server, reactor: Reactor, address: net.Address) !void {
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

    fn accept(self: *Server, allocator: *mem.Allocator, reactor: Reactor) !void {
        while (true) {
            var conn = try self.listener.accept(os.SOCK_CLOEXEC | os.SOCK_NONBLOCK);
            errdefer conn.socket.deinit();

            try conn.socket.setNoDelay(true);

            // log.info("got connection: {}", .{conn.address});

            const wga_allocator = &self.wga.allocator;

            const connection = try wga_allocator.create(Connection);
            errdefer wga_allocator.destroy(connection);

            connection.server = self;
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

    fn deregister(self: *Server, address: net.Address) bool {
        const held = self.lock.acquire();
        defer held.release();

        const entry = self.connections.swapRemove(address.any) orelse return false;
        return true;
    }
};

pub fn runApp(reactor: Reactor, reactor_event: *Reactor.AutoResetEvent) !void {
    defer {
        log.info("shutting down...", .{});
        @atomicStore(bool, &stopped, true, .Release);
        reactor_event.post();
    }

    var server = Server.init(hyperia.allocator);
    defer server.deinit(hyperia.allocator);

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, 9000);
    try server.start(reactor, address);

    const Cases = struct {
        accept: struct {
            run: Case(Server.accept),
            cancel: Case(Server.close),
        },
        ctrl_c: struct {
            run: Case(hyperia.ctrl_c.wait),
            cancel: Case(hyperia.ctrl_c.cancel),
        },
    };

    switch (select(
        Cases{
            .accept = .{
                .run = call(Server.accept, .{ &server, hyperia.allocator, reactor }),
                .cancel = call(Server.close, .{&server}),
            },
            .ctrl_c = .{
                .run = call(hyperia.ctrl_c.wait, .{}),
                .cancel = call(hyperia.ctrl_c.cancel, .{}),
            },
        },
    )) {
        .accept => |result| return result,
        .ctrl_c => |result| return result,
    }
}

pub fn main() !void {
    hyperia.init();
    defer hyperia.deinit();

    hyperia.ctrl_c.init();
    defer hyperia.ctrl_c.deinit();

    pool = try hyperia.ObjectPool(mpsc.Sink([]const u8).Node, 4096).init(hyperia.allocator);
    defer pool.deinit(hyperia.allocator);

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
