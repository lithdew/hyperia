const std = @import("std");
const c = @cImport(@cInclude("ed25519.h"));

const crypto = std.crypto;
const testing = std.testing;

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

pub fn addTo(step: *std.build.LibExeObjStep, comptime dir: []const u8) void {
    step.linkLibC();

    step.addIncludeDir(dir ++ "/lib");

    comptime var defines: []const []const u8 = &[_][]const u8{ "-DED25519_CUSTOMRANDOM", "-DED25519_CUSTOMHASH" };

    if (comptime std.Target.x86.featureSetHas(std.Target.current.cpu.features, .sse2)) {
        defines = defines ++ [_][]const u8{"-DED25519_SSE2"};
    }

    step.addCSourceFile(dir ++ "/ed25519.c", defines);
}

pub fn derivePublicKey(secret_key: [32]u8) [32]u8 {
    var public_key: [32]u8 = undefined;
    c.ed25519_publickey(&secret_key, &public_key);
    return public_key;
}

pub fn sign(msg: []const u8, secret_key: [32]u8, public_key: [32]u8) [64]u8 {
    var signature: [64]u8 = undefined;
    c.ed25519_sign(msg.ptr, msg.len, &secret_key, &public_key, &signature);
    return signature;
}

pub fn open(msg: []const u8, public_key: [32]u8, signature: [64]u8) bool {
    return c.ed25519_sign_open(msg.ptr, msg.len, &public_key, &signature) == 0;
}

test "ed25519_donna" {
    var secret_key: [32]u8 = undefined;
    crypto.random.bytes(&secret_key);

    var public_key: [32]u8 = derivePublicKey(secret_key);
    var buf: [1024]u8 = undefined;

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        testing.expect(open(&buf, public_key, sign(&buf, secret_key, public_key)));
    }
}
