const std = @import("std");
const hyperia = @import("hyperia.zig");

const mem = std.mem;
const meta = std.meta;
const builtin = std.builtin;
const oneshot = hyperia.oneshot;

pub fn ResultUnionOf(comptime Cases: type) type {
    var union_fields: [@typeInfo(Cases).Struct.fields.len]builtin.TypeInfo.UnionField = undefined;
    var union_tag = meta.FieldEnum(Cases);

    inline for (@typeInfo(Cases).Struct.fields) |field, i| {
        const run = meta.fieldInfo(field.field_type, .run).field_type;
        const return_type = @typeInfo(@typeInfo(run).Struct.decls[0].data.Var).Fn.return_type.?;
        const field_alignment = if (@sizeOf(return_type) > 0) @alignOf(return_type) else 0;

        union_fields[i] = .{
            .name = field.name,
            .field_type = return_type,
            .alignment = field_alignment,
        };
    }

    return @Type(builtin.TypeInfo{
        .Union = .{
            .layout = .Auto,
            .tag_type = union_tag,
            .fields = &union_fields,
            .decls = &.{},
        },
    });
}

pub fn select(cases: anytype) ResultUnionOf(@TypeOf(cases)) {
    const ResultUnion = ResultUnionOf(@TypeOf(cases));
    const Channel = oneshot.Channel(ResultUnion);

    const Memoized = struct {
        pub fn Closure(
            comptime C: type,
            comptime case_name: []const u8,
        ) type {
            return struct {
                fn call(channel: *Channel, case: C) callconv(.Async) void {
                    const result = @call(.{}, C.function, case.args);
                    const result_union = @unionInit(ResultUnion, case_name, result);
                    if (channel.set()) channel.commit(result_union);
                }
            };
        }
    };

    comptime var types: []const type = &[_]type{};
    inline for (@typeInfo(@TypeOf(cases)).Struct.fields) |field| {
        const C = Memoized.Closure(@TypeOf(@field(@field(cases, field.name), "run")), field.name);
        types = types ++ [_]type{@Frame(C.call)};
    }

    var frames: meta.Tuple(types) = undefined;
    var channel: Channel = .{};

    inline for (@typeInfo(@TypeOf(cases)).Struct.fields) |field, i| {
        const C = Memoized.Closure(@TypeOf(@field(@field(cases, field.name), "run")), field.name);
        frames[i] = async C.call(&channel, @field(@field(cases, field.name), "run"));
    }

    const result = channel.wait();
    const result_idx = @enumToInt(result);

    inline for (@typeInfo(@TypeOf(cases)).Struct.fields) |field, i| {
        if (i != result_idx) {
            if (comptime @hasField(@TypeOf(@field(cases, field.name)), "cancel")) {
                const cancel = @field(@field(cases, field.name), "cancel");
                @call(comptime .{}, @TypeOf(cancel).function, cancel.args);
            }
        }
        await frames[i];
    }

    return result;
}

pub fn Case(comptime Function: anytype) type {
    return struct {
        pub const function = Function;
        args: meta.ArgsTuple(@TypeOf(Function)),
    };
}

pub fn call(comptime Function: anytype, arguments: anytype) Case(Function) {
    var args: meta.ArgsTuple(@TypeOf(Function)) = undefined;
    mem.copy(u8, mem.asBytes(&args), mem.asBytes(&arguments));
    return .{ .args = args };
}
