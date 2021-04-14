const std = @import("std");
const c = @cImport(@cInclude("blake3.h"));

const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;

pub fn addTo(step: *std.build.LibExeObjStep, comptime dir: []const u8) void {
    step.linkLibC();

    step.addIncludeDir(dir ++ "/lib/c");

    var defines: std.ArrayListUnmanaged([]const u8) = .{};
    defer defines.deinit(step.builder.allocator);

    if (std.Target.x86.featureSetHas(step.target.getCpuFeatures(), .sse2)) {
        step.addAssemblyFile(dir ++ "/lib/c/blake3_sse2_x86-64_unix.S");
    } else {
        defines.append(step.builder.allocator, "-DBLAKE3_NO_SSE2") catch unreachable;
    }

    if (std.Target.x86.featureSetHas(step.target.getCpuFeatures(), .sse4_1)) {
        step.addAssemblyFile(dir ++ "/lib/c/blake3_sse41_x86-64_unix.S");
    } else {
        defines.append(step.builder.allocator, "-DBLAKE3_NO_SSE41") catch unreachable;
    }

    if (std.Target.x86.featureSetHas(step.target.getCpuFeatures(), .avx2)) {
        step.addAssemblyFile(dir ++ "/lib/c/blake3_avx2_x86-64_unix.S");
    } else {
        defines.append(step.builder.allocator, "-DBLAKE3_NO_AVX2") catch unreachable;
    }

    if (std.Target.x86.featureSetHasAll(step.target.getCpuFeatures(), .{ .avx512f, .avx512vl })) {
        step.addAssemblyFile(dir ++ "/lib/c/blake3_avx512_x86-64_unix.S");
    } else {
        defines.append(step.builder.allocator, "-DBLAKE3_NO_AVX512") catch unreachable;
    }

    step.addCSourceFile(dir ++ "/lib/c/blake3.c", defines.items);
    step.addCSourceFile(dir ++ "/lib/c/blake3_dispatch.c", defines.items);
    step.addCSourceFile(dir ++ "/lib/c/blake3_portable.c", defines.items);
}

pub const Hasher = struct {
    state: c.blake3_hasher = undefined,

    pub fn init() callconv(.Inline) Hasher {
        var state: c.blake3_hasher = undefined;
        c.blake3_hasher_init(&state);

        return Hasher{ .state = state };
    }

    pub fn update(self: *Hasher, buf: []const u8) callconv(.Inline) void {
        c.blake3_hasher_update(&self.state, buf.ptr, buf.len);
    }

    pub fn final(self: *Hasher, dst: []u8) callconv(.Inline) void {
        c.blake3_hasher_finalize(&self.state, dst.ptr, dst.len);
    }
};

pub fn hash(buf: []const u8) callconv(.Inline) [32]u8 {
    var hasher = Hasher.init();
    hasher.update(buf);

    var dst: [32]u8 = undefined;
    hasher.final(&dst);

    return dst;
}

test "blake3: hash 'hello world" {
    try testing.expectFmt("d74981efa70a0c880b8d8c1985d075dbcbf679b99a5f9914e5aaf96b831a9e24", "{s}", .{fmt.fmtSliceHexLower(&hash("hello world"))});
}
