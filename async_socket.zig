const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia");
const Socket = @import("socket.zig").Socket;
const Reactor = @import("reactor.zig").Reactor;
const AsyncParker = @import("async_parker.zig").AsyncParker;

const os = std.os;
const testing = std.testing;

pub const AsyncSocket = struct {
    const Self = @This();

    socket: Socket,
    readable: AsyncParker = .{},
    writable: AsyncParker = .{},

    pub fn tryRead(self: *Self, buf: []u8) os.ReadError!usize {
        return self.socket.read(buf);
    }

    pub fn tryWrite(self: *Self, buf: []const u8) os.WriteError!usize {
        return self.socket.write(buf);
    }

    pub fn read(self: *Self, buf: []u8) (os.ReadError || AsyncParker.Error)!usize {
        while (true) {
            const num_bytes = self.socket.read(buf) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.readable.wait();
                    continue;
                },
                else => return err,
            };

            return num_bytes;
        }
    }

    pub fn write(self: *Self, buf: []const u8) (os.WriteError || AsyncParker.Error)!usize {
        while (true) {
            const num_bytes = self.socket.write(buf) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.writable.wait();
                    continue;
                },
                else => return err,
            };

            return num_bytes;
        }
    }

    pub fn cancel(self: *Self, how: enum { read, write, all }) void {
        switch (how) {
            .read => if (self.readable.cancel()) |runnable| hyperia.pool.schedule(.{}, runnable),
            .write => if (self.writable.cancel()) |runnable| hyperia.pool.schedule(.{}, runnable),
            .all => {
                var batch: zap.Pool.Batch = .{};
                if (self.writable.cancel()) |runnable| batch.push(runnable);
                if (self.readable.cancel()) |runnable| batch.push(runnable);
                hyperia.pool.schedule(.{}, batch);
            },
        }
    }

    pub fn onEvent(self: *Self, batch: *zap.Pool.Batch, event: Reactor.Event) void {
        if (event.is_readable) {
            if (self.readable.notify()) |runnable| {
                batch.push(runnable);
            }
        }

        if (event.is_writable) {
            if (self.writable.notify()) |runnable| {
                batch.push(runnable);
            }
        }

        if (event.is_hup) {
            if (self.readable.close()) |runnable| batch.push(runnable);
            if (self.writable.close()) |runnable| batch.push(runnable);
            // TODO(kenta): deinitialize resources for connection
        }
    }
};

test {
    testing.refAllDecls(@This());
}
