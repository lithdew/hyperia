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
const log = std.log.scoped(.gossip);

usingnamespace hyperia.select;

pub const log_level = .debug;

var stopped: bool = false;

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

pub fn runApp(reactor: Reactor, reactor_event: *Reactor.AutoResetEvent) !void {
    defer {
        log.info("shutting down...", .{});
        @atomicStore(bool, &stopped, true, .Release);
        reactor_event.post();
    }

    var node = Node.init(hyperia.allocator);
    defer node.deinit(hyperia.allocator);

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, 9000);
    try node.start(reactor, address);

    const Cases = struct {
        accept: struct {
            run: Case(Node.accept),
            cancel: Case(Node.close),
        },
        ctrl_c: struct {
            run: Case(hyperia.ctrl_c.wait),
            cancel: Case(hyperia.ctrl_c.cancel),
        },
    };

    switch (select(
        Cases{
            .accept = .{
                .run = call(Node.accept, .{ &node, hyperia.allocator, reactor }),
                .cancel = call(Node.close, .{&node}),
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
