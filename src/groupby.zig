//! Group rows by one column and reduce another per group.
//!
//! Two passes, both over contiguous arrays. The first hashes every key into
//! a group id, so each row knows which group it belongs to; the second walks
//! a value column once, folding each row into its group's accumulator. The
//! hash map is the only part that is not a straight loop, and it only ever
//! holds one entry per distinct key.

const std = @import("std");
const agg = @import("agg.zig");
const frame = @import("frame.zig");

const Allocator = std.mem.Allocator;
const Column = frame.Column;
const DataFrame = frame.DataFrame;
const StringColumn = frame.StringColumn;

pub const GroupError = error{
    /// Asked for arithmetic on a string column.
    NotNumeric,
    /// A group's integer sum left the i64 range.
    SumOverflow,
};

/// Per-group reductions. Values are part of the ABI: append, never renumber.
pub const Func = enum(u8) {
    sum = 0,
    mean = 1,
    min = 2,
    max = 3,
    /// Rows per group. Takes any column, since it never reads the values.
    count = 4,
};

/// One output column: `func` applied to `column` within each group.
pub const Spec = struct {
    column: usize,
    func: Func,
};

/// Which group each row belongs to. Ids are dense and assigned in order of
/// first appearance, so group 0 is the key of row 0.
pub const Groups = struct {
    ids: []const u32,
    /// The row where each group was first seen; its key is the group's key.
    first_row: []const usize,

    pub fn count(self: Groups) usize {
        return self.first_row.len;
    }

    pub fn deinit(self: Groups, gpa: Allocator) void {
        gpa.free(self.ids);
        gpa.free(self.first_row);
    }
};

/// Assigns a group id to every row by the value in `key`.
pub fn assign(gpa: Allocator, key: Column) !Groups {
    const ids = try gpa.alloc(u32, key.len());
    errdefer gpa.free(ids);

    var first_row: std.ArrayList(usize) = .empty;
    errdefer first_row.deinit(gpa);

    switch (key) {
        .int => |values| try assignWith(i64, gpa, values, ids, &first_row),
        // Bit patterns make a fine hash key once -0.0 is folded into 0.0:
        // the columns never hold NaN, and every other value has one pattern.
        .float => |values| {
            const bits = try gpa.alloc(u64, values.len);
            defer gpa.free(bits);
            for (bits, values) |*slot, value| slot.* = @bitCast(if (value == 0) 0.0 else value);
            try assignWith(u64, gpa, bits, ids, &first_row);
        },
        .string => |values| try assignStrings(gpa, values, ids, &first_row),
    }

    return .{ .ids = ids, .first_row = try first_row.toOwnedSlice(gpa) };
}

fn assignWith(
    comptime K: type,
    gpa: Allocator,
    keys: []const K,
    ids: []u32,
    first_row: *std.ArrayList(usize),
) !void {
    var seen: std.AutoHashMapUnmanaged(K, u32) = .empty;
    defer seen.deinit(gpa);

    for (keys, ids, 0..) |key, *id, row| {
        const entry = try seen.getOrPut(gpa, key);
        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(first_row.items.len);
            try first_row.append(gpa, row);
        }
        id.* = entry.value_ptr.*;
    }
}

fn assignStrings(
    gpa: Allocator,
    keys: StringColumn,
    ids: []u32,
    first_row: *std.ArrayList(usize),
) !void {
    // Keys borrow from the column's data buffer, which outlives this call.
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    defer seen.deinit(gpa);

    for (ids, 0..) |*id, row| {
        const entry = try seen.getOrPut(gpa, keys.get(row));
        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(first_row.items.len);
            try first_row.append(gpa, row);
        }
        id.* = entry.value_ptr.*;
    }
}

/// Reduces `column` within each group. The result has one value per group
/// and keeps the column's type for `sum`, `min` and `max`; `mean` is always
/// float and `count` always int. Allocated in `arena`.
pub fn reduce(arena: Allocator, groups: Groups, column: Column, func: Func) !Column {
    const n = groups.count();

    if (func == .count) {
        const counts = try arena.alloc(i64, n);
        @memset(counts, 0);
        for (groups.ids) |id| counts[id] += 1;
        return .{ .int = counts };
    }

    return switch (column) {
        .int => |values| switch (func) {
            .sum => .{ .int = try sumInts(arena, groups, values) },
            .mean => .{ .float = try meanOf(arena, groups, values) },
            .min => .{ .int = try extreme(i64, arena, groups, values, .min) },
            .max => .{ .int = try extreme(i64, arena, groups, values, .max) },
            .count => unreachable,
        },
        .float => |values| switch (func) {
            .sum => .{ .float = try sumFloats(arena, groups, values) },
            .mean => .{ .float = try meanOf(arena, groups, values) },
            .min => .{ .float = try extreme(f64, arena, groups, values, .min) },
            .max => .{ .float = try extreme(f64, arena, groups, values, .max) },
            .count => unreachable,
        },
        .string => GroupError.NotNumeric,
    };
}

fn sumInts(arena: Allocator, groups: Groups, values: []const i64) ![]const i64 {
    const totals = try arena.alloc(i64, groups.count());
    @memset(totals, 0);
    for (values, groups.ids) |value, id| {
        const result = @addWithOverflow(totals[id], value);
        if (result[1] != 0) return GroupError.SumOverflow;
        totals[id] = result[0];
    }
    return totals;
}

fn sumFloats(arena: Allocator, groups: Groups, values: []const f64) ![]const f64 {
    const totals = try arena.alloc(f64, groups.count());
    @memset(totals, 0);
    for (values, groups.ids) |value, id| totals[id] += value;
    return totals;
}

/// Accumulates as f64 whatever the input, for the same reason `agg.mean`
/// does: a mean is representable even when the total is not.
fn meanOf(arena: Allocator, groups: Groups, values: anytype) ![]const f64 {
    const n = groups.count();
    const totals = try arena.alloc(f64, n);
    @memset(totals, 0);

    const counts = try arena.alloc(f64, n);
    @memset(counts, 0);

    for (values, groups.ids) |value, id| {
        totals[id] += switch (@TypeOf(value)) {
            i64 => @as(f64, @floatFromInt(value)),
            f64 => value,
            else => unreachable,
        };
        counts[id] += 1;
    }
    // Every group has at least the row that created it, so no division by zero.
    for (totals, counts) |*total, count| total.* /= count;
    return totals;
}

fn extreme(
    comptime T: type,
    arena: Allocator,
    groups: Groups,
    values: []const T,
    comptime which: enum { min, max },
) ![]const T {
    const best = try arena.alloc(T, groups.count());
    // Seeding with each group's first value avoids a sentinel that would
    // have to be larger than any real one.
    for (best, groups.first_row) |*slot, row| slot.* = values[row];

    for (values, groups.ids) |value, id| {
        const wins = if (which == .min) value < best[id] else value > best[id];
        if (wins) best[id] = value;
    }
    return best;
}

/// `df.groupby(key).agg(specs)`: a new frame with one row per distinct key,
/// in order of first appearance. The first column is the key, under its own
/// name; then one column per spec, named after the column it reduces, except
/// `count`, which is named "count".
pub fn groupBy(gpa: Allocator, df: DataFrame, key: usize, specs: []const Spec) !DataFrame {
    const groups = try assign(gpa, df.column(key));
    defer groups.deinit(gpa);

    var result: DataFrame = .{
        .arena = .init(gpa),
        .names = &.{},
        .columns = &.{},
        .row_count = groups.count(),
    };
    errdefer result.arena.deinit();
    const arena = result.arena.allocator();

    const names = try arena.alloc([]const u8, specs.len + 1);
    names[0] = try arena.dupe(u8, df.names[key]);
    for (names[1..], specs) |*name, spec| {
        name.* = try arena.dupe(u8, if (spec.func == .count) "count" else df.names[spec.column]);
    }
    result.names = names;

    const columns = try arena.alloc(Column, specs.len + 1);
    columns[0] = try pick(arena, df.column(key), groups.first_row);
    for (columns[1..], specs) |*slot, spec| {
        slot.* = try reduce(arena, groups, df.column(spec.column), spec.func);
    }
    result.columns = columns;

    return result;
}

/// The values at `rows`, as a new column of the same type.
fn pick(arena: Allocator, column: Column, rows: []const usize) !Column {
    return switch (column) {
        .int => |values| blk: {
            const out = try arena.alloc(i64, rows.len);
            for (out, rows) |*slot, row| slot.* = values[row];
            break :blk .{ .int = out };
        },
        .float => |values| blk: {
            const out = try arena.alloc(f64, rows.len);
            for (out, rows) |*slot, row| slot.* = values[row];
            break :blk .{ .float = out };
        },
        .string => |values| blk: {
            var total: usize = 0;
            for (rows) |row| total += values.get(row).len;

            const data = try arena.alloc(u8, total);
            const offsets = try arena.alloc(usize, rows.len + 1);
            var at: usize = 0;
            for (rows, 0..) |row, i| {
                const text = values.get(row);
                offsets[i] = at;
                @memcpy(data[at..][0..text.len], text);
                at += text.len;
            }
            offsets[rows.len] = at;
            break :blk .{ .string = .{ .offsets = offsets, .data = data } };
        },
    };
}

const testing = std.testing;

const sample =
    \\city,n,x
    \\paris,1,0.5
    \\rome,2,1.5
    \\paris,3,2.5
    \\berlin,4,3.5
    \\rome,5,4.5
    \\
;

test "assign gives dense ids in order of first appearance" {
    var df = try DataFrame.parse(testing.allocator, sample, .{});
    defer df.deinit();

    const groups = try assign(testing.allocator, df.column(0));
    defer groups.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), groups.count());
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0, 2, 1 }, groups.ids);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, groups.first_row);
}

test "assign works on every key type" {
    var df = try DataFrame.parse(testing.allocator, "n,x\n1,0.5\n2,0.5\n1,1.5\n", .{});
    defer df.deinit();

    const by_int = try assign(testing.allocator, df.column(0));
    defer by_int.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0 }, by_int.ids);

    const by_float = try assign(testing.allocator, df.column(1));
    defer by_float.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1 }, by_float.ids);
}

test "negative zero groups with zero" {
    const column: Column = .{ .float = &.{ 0.0, -0.0, 1.0 } };
    const groups = try assign(testing.allocator, column);
    defer groups.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1 }, groups.ids);
}

test "empty strings are a key like any other" {
    var df = try DataFrame.parse(testing.allocator, "s,n\n,1\na,2\n,3\n", .{});
    defer df.deinit();

    const groups = try assign(testing.allocator, df.column(0));
    defer groups.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0 }, groups.ids);
}

test "groupBy with every reduction" {
    var df = try DataFrame.parse(testing.allocator, sample, .{});
    defer df.deinit();

    var out = try groupBy(testing.allocator, df, 0, &.{
        .{ .column = 1, .func = .sum },
        .{ .column = 1, .func = .mean },
        .{ .column = 2, .func = .min },
        .{ .column = 2, .func = .max },
        .{ .column = 0, .func = .count },
    });
    defer out.deinit();

    try testing.expectEqual(@as(usize, 3), out.rowCount());
    try testing.expectEqual(@as(usize, 6), out.columnCount());

    try testing.expectEqualStrings("city", out.names[0]);
    try testing.expectEqualStrings("n", out.names[1]);
    try testing.expectEqualStrings("x", out.names[3]);
    try testing.expectEqualStrings("count", out.names[5]);

    const keys = out.strings(0).?;
    try testing.expectEqualStrings("paris", keys.get(0));
    try testing.expectEqualStrings("rome", keys.get(1));
    try testing.expectEqualStrings("berlin", keys.get(2));

    try testing.expectEqualSlices(i64, &.{ 4, 7, 4 }, out.ints(1).?);
    try testing.expectEqualSlices(f64, &.{ 2, 3.5, 4 }, out.floats(2).?);
    try testing.expectEqualSlices(f64, &.{ 0.5, 1.5, 3.5 }, out.floats(3).?);
    try testing.expectEqualSlices(f64, &.{ 2.5, 4.5, 3.5 }, out.floats(4).?);
    try testing.expectEqualSlices(i64, &.{ 2, 2, 1 }, out.ints(5).?);
}

test "sum, min and max keep the column's type" {
    var df = try DataFrame.parse(testing.allocator, sample, .{});
    defer df.deinit();

    var out = try groupBy(testing.allocator, df, 0, &.{
        .{ .column = 1, .func = .min },
        .{ .column = 2, .func = .sum },
    });
    defer out.deinit();

    try testing.expectEqual(.int, out.columnType(1));
    try testing.expectEqual(.float, out.columnType(2));
    try testing.expectEqualSlices(i64, &.{ 1, 2, 4 }, out.ints(1).?);
    try testing.expectEqualSlices(f64, &.{ 3, 6, 3.5 }, out.floats(2).?);
}

test "a numeric key stays numeric in the result" {
    var df = try DataFrame.parse(testing.allocator, "n,x\n2,0.5\n1,1.5\n2,2.5\n", .{});
    defer df.deinit();

    var out = try groupBy(testing.allocator, df, 0, &.{.{ .column = 1, .func = .sum }});
    defer out.deinit();

    try testing.expectEqualSlices(i64, &.{ 2, 1 }, out.ints(0).?);
    try testing.expectEqualSlices(f64, &.{ 3, 1.5 }, out.floats(1).?);
}

test "just the key column, with no specs, is the distinct keys" {
    var df = try DataFrame.parse(testing.allocator, sample, .{});
    defer df.deinit();

    var out = try groupBy(testing.allocator, df, 0, &.{});
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1), out.columnCount());
    try testing.expectEqual(@as(usize, 3), out.rowCount());
}

test "count ignores the column it is given" {
    var df = try DataFrame.parse(testing.allocator, sample, .{});
    defer df.deinit();

    var out = try groupBy(testing.allocator, df, 0, &.{.{ .column = 0, .func = .count }});
    defer out.deinit();

    try testing.expectEqualSlices(i64, &.{ 2, 2, 1 }, out.ints(1).?);
}

test "an empty frame groups into an empty frame" {
    var df = try DataFrame.parse(testing.allocator, "s,n\n", .{});
    defer df.deinit();

    var out = try groupBy(testing.allocator, df, 0, &.{.{ .column = 1, .func = .count }});
    defer out.deinit();

    try testing.expectEqual(@as(usize, 0), out.rowCount());
    try testing.expectEqual(@as(usize, 2), out.columnCount());
    try testing.expectEqual(.int, out.columnType(1));
}

test "the result outlives its source" {
    var df = try DataFrame.parse(testing.allocator, sample, .{});
    var out = try groupBy(testing.allocator, df, 0, &.{.{ .column = 1, .func = .sum }});
    defer out.deinit();
    df.deinit();

    try testing.expectEqualStrings("rome", out.strings(0).?.get(1));
    try testing.expectEqualSlices(i64, &.{ 4, 7, 4 }, out.ints(1).?);
}

test "arithmetic on a string column is an error" {
    var df = try DataFrame.parse(testing.allocator, sample, .{});
    defer df.deinit();

    for ([_]Func{ .sum, .mean, .min, .max }) |func| {
        try testing.expectError(
            GroupError.NotNumeric,
            groupBy(testing.allocator, df, 1, &.{.{ .column = 0, .func = func }}),
        );
    }
}

test "a group whose sum overflows is an error" {
    const huge = std.math.maxInt(i64);
    const groups: Groups = .{ .ids = &.{ 0, 1, 0 }, .first_row = &.{ 0, 1 } };
    const column: Column = .{ .int = &.{ huge, 1, 1 } };

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(GroupError.SumOverflow, reduce(arena.allocator(), groups, column, .sum));
    const means = (try reduce(arena.allocator(), groups, column, .mean)).float;
    try testing.expectEqual(@as(f64, (@as(f64, @floatFromInt(huge)) + 1) / 2), means[0]);
}

test "groups a large frame" {
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "k,n\n");

    var buf: [32]u8 = undefined;
    for (0..10_000) |i| {
        try text.appendSlice(gpa, try std.fmt.bufPrint(&buf, "{d},{d}\n", .{ i % 7, i }));
    }

    var df = try DataFrame.parse(gpa, text.items, .{});
    defer df.deinit();

    var out = try groupBy(gpa, df, 0, &.{
        .{ .column = 1, .func = .count },
        .{ .column = 1, .func = .max },
    });
    defer out.deinit();

    try testing.expectEqual(@as(usize, 7), out.rowCount());
    try testing.expectEqualSlices(i64, &.{ 0, 1, 2, 3, 4, 5, 6 }, out.ints(0).?);
    // 10,000 = 7 * 1428 + 4, so keys 0..3 get one extra row.
    try testing.expectEqualSlices(i64, &.{ 1429, 1429, 1429, 1429, 1428, 1428, 1428 }, out.ints(1).?);
    try testing.expectEqual(@as(i64, 9_999), out.ints(2).?[9_999 % 7]);
}
