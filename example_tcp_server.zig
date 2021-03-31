const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia");
const Reactor = hyperia.Reactor;
const AsyncSocket = hyperia.AsyncSocket;
const AsyncWaitGroupAllocator = hyperia.AsyncWaitGroupAllocator;

const os = std.os;
const net = std.net;
const mem = std.mem;
const builtin = std.builtin;
const log = std.log.scoped(.server);

usingnamespace hyperia.select;

pub const log_level = .debug;

var stopped: bool = false;

pub const Server = struct {
    pub const Connection = struct {
        server: *Server,
        socket: AsyncSocket,
        address: net.Address,
        frame: @Frame(Connection.start),

        pub fn start(self: *Connection) !void {
            defer {
                log.info("{} has disconnected", .{self.address});

                if (self.server.deregister(self.address)) {
                    suspend {
                        self.socket.deinit();
                        self.server.wga.allocator.destroy(self);
                    }
                }
            }

            var buf: [4096]u8 = undefined;
            while (true) {
                const num_bytes = try self.socket.read(&buf);
                if (num_bytes == 0) return;

                const message = mem.trim(u8, buf[0..num_bytes], "\r\n");
                log.info("got message from {}: '{s}'", .{ self.address, message });
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

    fn accept(self: *Server, allocator: *mem.Allocator, reactor: Reactor) callconv(.Async) !void {
        while (true) {
            var conn = try self.listener.accept(os.SOCK_CLOEXEC | os.SOCK_NONBLOCK);
            errdefer conn.socket.deinit();

            try conn.socket.setNoDelay(true);

            log.info("got connection: {}", .{conn.address});

            const wga_allocator = &self.wga.allocator;

            const connection = try wga_allocator.create(Connection);
            errdefer wga_allocator.destroy(connection);

            connection.server = self;
            connection.socket = AsyncSocket.from(conn.socket);
            connection.address = conn.address;

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
