const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia");
const Reactor = hyperia.Reactor;
const AsyncSocket = hyperia.AsyncSocket;
const AsyncAutoResetEvent = hyperia.AsyncAutoResetEvent;
const AsyncWaitGroupAllocator = hyperia.AsyncWaitGroupAllocator;

const os = std.os;
const net = std.net;
const mem = std.mem;
const log = std.log.scoped(.server);

var stopped: bool = false;

pub const Server = struct {
    pub const Connection = struct {
        server: *Server,
        socket: AsyncSocket,
        address: net.Address,
        frame: @Frame(Connection.start),

        pub fn start(self: *Connection) !void {
            defer if (self.server.close(self.address)) {
                suspend {
                    self.socket.deinit();
                    self.server.wga.allocator.destroy(self);
                }
            };

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
    frame: @Frame(Server.accept),

    wga: AsyncWaitGroupAllocator,
    lock: std.Thread.Mutex = .{},
    connections: std.AutoArrayHashMapUnmanaged(os.sockaddr, *Connection) = .{},

    pub fn init(allocator: *mem.Allocator) Server {
        return Server{
            .listener = undefined,
            .frame = undefined,
            .wga = .{ .backing_allocator = allocator },
        };
    }

    pub fn deinit(self: *Server, allocator: *mem.Allocator) void {
        self.listener.shutdown(.recv) catch {};
        await self.frame catch {};

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

    pub fn start(self: *Server, allocator: *mem.Allocator, reactor: Reactor, address: net.Address) !void {
        self.listener = try AsyncSocket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
        errdefer self.listener.deinit();

        try reactor.add(self.listener.socket.fd, &self.listener.handle, .{ .readable = true });

        try self.listener.setReuseAddress(true);
        try self.listener.bind(address);
        try self.listener.listen(128);

        log.info("listening for connections on: {}", .{try self.listener.getName()});

        self.frame = async self.accept(allocator, reactor);
    }

    fn accept(self: *Server, allocator: *mem.Allocator, reactor: Reactor) !void {
        while (true) {
            var conn = try self.listener.accept(os.SOCK_CLOEXEC | os.SOCK_NONBLOCK);
            errdefer conn.socket.deinit();

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

    fn close(self: *Server, address: net.Address) bool {
        const held = self.lock.acquire();
        defer held.release();

        const entry = self.connections.swapRemove(address.any) orelse return false;
        return true;
    }
};

pub fn runApp(reactor: Reactor, reactor_event: *AsyncAutoResetEvent) !void {
    defer {
        @atomicStore(bool, &stopped, true, .Release);
        reactor_event.post();
    }

    var server = Server.init(hyperia.allocator);
    defer server.deinit(hyperia.allocator);

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, 9000);
    try server.start(hyperia.allocator, reactor, address);

    hyperia.ctrl_c.wait();

    log.info("shutting down...", .{});
}

pub fn main() !void {
    hyperia.init();
    defer hyperia.deinit();

    hyperia.ctrl_c.init();
    defer hyperia.ctrl_c.deinit();

    const reactor = try Reactor.init(os.EPOLL_CLOEXEC);
    defer reactor.deinit();

    var reactor_event = try AsyncAutoResetEvent.init(os.EFD_CLOEXEC, reactor);
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
