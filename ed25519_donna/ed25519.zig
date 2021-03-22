const std = @import("std");
const c = @cImport(@cInclude("ed25519.h"));

const crypto = std.crypto;

pub fn addTo(step: *std.build.LibExeObjStep, comptime dir: []const u8) void {
    step.linkLibC();

    step.addIncludeDir(dir ++ "/lib");

    comptime var defines: []const []const u8 = &[_][]const u8{ "-DED25519_CUSTOMRANDOM", "-DED25519_CUSTOMHASH" };

    if (comptime std.Target.x86.featureSetHas(std.Target.current.cpu.features, .sse2)) {
        defines = defines ++ [_][]const u8{"-DED25519_SSE2"};
    }

    step.addCSourceFile(dir ++ "/ed25519.c", defines);
}

export fn @"ed25519_randombytes_unsafe"(ptr: *c_void, len: usize) callconv(.C) void {
    crypto.random.bytes(@ptrCast([*]u8, ptr)[0..len]);
}

export fn @"ed25519_hash_init"(ctx: *crypto.hash.sha3.Sha3_512) callconv(.C) void {
    ctx.* = crypto.hash.sha3.Sha3_512.init(.{});
}

export fn @"ed25519_hash_update"(ctx: *crypto.hash.sha3.Sha3_512, ptr: [*]const u8, len: usize) callconv(.C) void {
    ctx.update(ptr[0..len]);
}

export fn @"ed25519_hash_final"(ctx: *crypto.hash.sha3.Sha3_512, hash: [*]u8) callconv(.C) void {
    ctx.final(@ptrCast(*[64]u8, hash));
}

export fn @"ed25519_hash"(hash: [*]u8, ptr: [*]const u8, len: usize) callconv(.C) void {
    crypto.hash.sha3.Sha3_512.hash(ptr[0..len], @ptrCast(*[64]u8, hash), .{});
}

test "ed25519_donna" {
    var sk: [32]u8 = undefined;
    crypto.random.bytes(&sk);

    var pk: [32]u8 = undefined;
    c.ed25519_publickey(&sk, &pk);

    var buf: [1024]u8 = undefined;
    var signature: [64]u8 = undefined;

    var t = try std.time.Timer.start();

    var i: usize = 0;
    while (i < 1_000) : (i += 1) {
        c.ed25519_sign(&buf, buf.len, &sk, &pk, &signature);
    }

    std.debug.print("Done! Took {d:.2} ns.\n", .{t.read()});
}
