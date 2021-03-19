const std = @import("std");
const zap = @import("zap");
const hyperia = @import("hyperia");
const Socket = @import("socket.zig").Socket;
const Reactor = @import("reactor.zig").Reactor;
const AsyncParker = @import("async_parker.zig").AsyncParker;

const os = std.os;
const net = std.net;
const testing = std.testing;

pub const AsyncSocket = struct {
    const Self = @This();

    socket: Socket,
    readable: AsyncParker = .{},
    writable: AsyncParker = .{},

    pub fn shutdown(self: *Self, how: os.ShutdownHow) !void {
        return self.socket.shutdown(how);
    }

    pub fn bind(self: *Self, address: net.Address) !void {
        return self.socket.bind(address);
    }

    pub fn listen(self: *Self, max_backlog_size: usize) !void {
        return self.socket.listen(max_backlog_size);
    }

    pub fn getName(self: *Self) !net.Address {
        return self.socket.getName();
    }

    pub fn getReadBufferSize(self: *Self) !u32 {
        return self.socket.getReadBufferSize();
    }

    pub fn getWriteBufferSize(self: *Self) !u32 {
        return self.socket.getWriteBufferSize();
    }

    pub fn setReadBufferSize(self: *Self, size: u32) !void {
        return self.socket.setReadBufferSize(size);
    }

    pub fn setWriteBufferSize(self: *Self, size: u32) !void {
        return self.socket.setWriteBufferSize(size);
    }

    pub fn setReadTimeout(self: *Self, milliseconds: usize) !void {
        return self.socket.setReadTimeout(milliseconds);
    }

    pub fn setWriteTimeout(self: *Self, milliseconds: usize) !void {
        return self.socket.setWriteTimeout(milliseconds);
    }

    pub fn tryRead(self: *Self, buf: []u8) os.ReadError!usize {
        return self.socket.read(buf);
    }

    pub fn tryWrite(self: *Self, buf: []const u8) os.WriteError!usize {
        return self.socket.write(buf);
    }

    pub fn tryConnect(self: *Self, address: net.Address) os.ConnectError!void {
        return self.socket.connect(address);
    }

    pub fn tryAccept(self: *Self, flags: u32) !Socket.Connection {
        return self.socket.accept(flags);
    }

    pub fn read(self: *Self, buf: []u8) (os.ReadError || AsyncParker.Error)!usize {
        while (true) {
            const num_bytes = self.tryRead(buf) catch |err| switch (err) {
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
            const num_bytes = self.tryWrite(buf) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.writable.wait();
                    continue;
                },
                else => return err,
            };

            return num_bytes;
        }
    }

    pub fn connect(self: *Self, address: net.Address) (os.ConnectError || AsyncParker.Error)!void {
        self.tryConnect(address) catch |err| switch (err) {
            error.WouldBlock => {
                try self.writable.wait();
            },
            else => return err,
        };

        return self.socket.getError();
    }

    pub fn accept(self: *Self, flags: u32) (os.AcceptError || AsyncParker.Error)!Socket.Connection {
        while (true) {
            const connection = self.tryAccept(flags) catch |err| switch (err) {
                error.WouldBlock => {
                    try self.readable.wait();
                    continue;
                },
                else => return err,
            };

            return connection;
        }
    }

    pub fn cancel(self: *Self, how: enum { read, write, connect, accept, all }) void {
        switch (how) {
            .read, .accept => {
                if (self.readable.cancel()) |runnable| {
                    hyperia.pool.schedule(.{}, runnable);
                }
            },
            .write, .connect => {
                if (self.writable.cancel()) |runnable| {
                    hyperia.pool.schedule(.{}, runnable);
                }
            },
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
