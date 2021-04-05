const std = @import("std");

const testing = std.testing;

pub const SpinLock = struct {
    pub const Held = struct {
        self: *SpinLock,

        pub fn release(held: Held) void {
            @atomicStore(bool, &held.self.locked, false, .Release);
        }
    };

    locked: bool = false,

    pub fn acquire(self: *SpinLock) Held {
        while (@atomicRmw(bool, &self.locked, .Xchg, true, .Acquire)) {
            std.Thread.spinLoopHint();
        }
        return Held{ .self = self };
    }
};

test {
    testing.refAllDecls(@This());
}

test "sync/spin_lock: acquire and release" {
    var lock: SpinLock = .{};

    const held = lock.acquire();
    defer held.release();
}
