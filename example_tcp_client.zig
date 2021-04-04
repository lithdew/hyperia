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
const log = std.log.scoped(.client);

var stopped: bool = false;

var reactor_event: Reactor.AutoResetEvent = undefined;

pub const Client = struct {
    pub const capacity = 1;

    pub const Connection = struct {
        client: *Client,
        socket: AsyncSocket,
        connected: bool = false,
        frame: @Frame(Connection.run),

        pub fn deinit(self: *Connection) void {
            self.client.wga.allocator.destroy(self);
        }

        pub fn run(self: *Connection) !void {
            self.connect() catch |err| {
                log.warn("got an error: {}", .{err});
                return err;
            };

            log.info("successfully connected", .{});
        }

        fn connect(self: *Connection) !void {
            self.socket = try AsyncSocket.init(os.AF_INET, os.SOCK_STREAM | os.SOCK_CLOEXEC, os.IPPROTO_TCP);
            errdefer self.socket.deinit();

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

    pub fn acquire(self: *Client) !*Connection {
        const held = self.lock.acquire();
        defer held.release();

        if (self.len == 0) {
            const conn = try self.wga.allocator.create(Connection);
            errdefer self.wga.allocator.destroy(conn);

            conn.* = .{ .client = self, .socket = undefined, .frame = undefined };

            self.pool[self.len] = conn;
            self.len += 1;
        }

        return self.pool[0];
    }
};

fn runApp(reactor: Reactor) !void {
    defer {
        @atomicStore(bool, &stopped, true, .Release);
        reactor_event.post();
    }

    var client = try Client.init(hyperia.allocator, reactor, net.Address.initIp4(.{ 0, 0, 0, 0 }, 9000));
    defer client.deinit(hyperia.allocator);

    var conn = try client.acquire();
    defer conn.deinit();

    conn.frame = async conn.run();

    hyperia.ctrl_c.wait();
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
}
