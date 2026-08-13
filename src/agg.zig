//! Reductions over a single column.
//!
//! These are what the columnar layout is for: each one is a straight walk over
//! one contiguous typed array, with no per-row indirection.

const std = @import("std");
const frame = @import("frame.zig");

const Column = frame.Column;

pub const AggError = error{
    /// Asked for arithmetic on a string column.
    NotNumeric,
    /// A column with no rows has no minimum, maximum or mean.
    EmptyColumn,
    /// An integer sum left the i64 range.
    SumOverflow,
};

/// The result of a reduction that keeps the column's type.
pub const Value = union(enum) {
    int: i64,
    float: f64,

    pub fn asFloat(self: Value) f64 {
        return switch (self) {
            .int => |v| @floatFromInt(v),
            .float => |v| v,
        };
    }
};

/// The total. An empty column sums to zero, the way an empty sum should.
pub fn sum(column: Column) AggError!Value {
    return switch (column) {
        .int => |values| .{ .int = try sumInts(values) },
        .float => |values| .{ .float = sumFloats(values) },
        .string => AggError.NotNumeric,
    };
}

/// The arithmetic mean, always as `f64`.
///
/// Integers are accumulated as `f64` here rather than `i64`: the mean of a
/// long column of large values is perfectly representable even when their
/// total is not, and failing on that would be surprising.
pub fn mean(column: Column) AggError!f64 {
    // Type before emptiness, so an empty string column still reports the type
    // that is actually wrong with it. Every reduction here agrees on that.
    const total = switch (column) {
        .int => |values| blk: {
            var acc: f64 = 0;
            for (values) |value| acc += @floatFromInt(value);
            break :blk acc;
        },
        .float => |values| sumFloats(values),
        .string => return AggError.NotNumeric,
    };

    const count = column.len();
    if (count == 0) return AggError.EmptyColumn;
    return total / @as(f64, @floatFromInt(count));
}

pub fn min(column: Column) AggError!Value {
    return extreme(column, .min);
}

pub fn max(column: Column) AggError!Value {
    return extreme(column, .max);
}

fn extreme(column: Column, comptime which: enum { min, max }) AggError!Value {
    return switch (column) {
        .int => |values| blk: {
            if (values.len == 0) return AggError.EmptyColumn;
            var best = values[0];
            for (values[1..]) |value| {
                const wins = if (which == .min) value < best else value > best;
                if (wins) best = value;
            }
            break :blk .{ .int = best };
        },
        .float => |values| blk: {
            if (values.len == 0) return AggError.EmptyColumn;
            var best = values[0];
            for (values[1..]) |value| {
                best = if (which == .min) @min(best, value) else @max(best, value);
            }
            break :blk .{ .float = best };
        },
        .string => AggError.NotNumeric,
    };
}

fn sumInts(values: []const i64) AggError!i64 {
    var total: i64 = 0;
    for (values) |value| {
        const result = @addWithOverflow(total, value);
        if (result[1] != 0) return AggError.SumOverflow;
        total = result[0];
    }
    return total;
}

fn sumFloats(values: []const f64) f64 {
    var total: f64 = 0;
    for (values) |value| total += value;
    return total;
}

const testing = std.testing;
const DataFrame = frame.DataFrame;

fn columnOf(text: []const u8) !DataFrame {
    return DataFrame.parse(testing.allocator, text);
}

test "sums an integer column" {
    var df = try columnOf("n\n1\n2\n3\n");
    defer df.deinit();

    try testing.expectEqual(Value{ .int = 6 }, try sum(df.column(0)));
}

test "sums a float column" {
    var df = try columnOf("x\n0.5\n1.25\n");
    defer df.deinit();

    try testing.expectEqual(Value{ .float = 1.75 }, try sum(df.column(0)));
}

test "an empty column sums to zero but has no mean or extremes" {
    var df = try columnOf("a,b\n");
    defer df.deinit();

    // A header-only file infers as string, so build an empty int column by
    // hand to reduce over.
    const empty: Column = .{ .int = &.{} };
    try testing.expectEqual(Value{ .int = 0 }, try sum(empty));
    try testing.expectError(AggError.EmptyColumn, mean(empty));
    try testing.expectError(AggError.EmptyColumn, min(empty));
    try testing.expectError(AggError.EmptyColumn, max(empty));
}

test "averages a column" {
    var df = try columnOf("n\n1\n2\n4\n");
    defer df.deinit();

    try testing.expectEqual(@as(f64, 7.0 / 3.0), try mean(df.column(0)));
}

test "the mean survives values whose total would not" {
    const huge = std.math.maxInt(i64);
    const column: Column = .{ .int = &.{ huge, huge } };

    try testing.expectError(AggError.SumOverflow, sum(column));
    try testing.expectEqual(@as(f64, @floatFromInt(huge)), try mean(column));
}

test "finds the smallest and largest value" {
    var df = try columnOf("n,x\n3,0.5\n-1,2.25\n7,1.0\n");
    defer df.deinit();

    try testing.expectEqual(Value{ .int = -1 }, try min(df.column(0)));
    try testing.expectEqual(Value{ .int = 7 }, try max(df.column(0)));
    try testing.expectEqual(Value{ .float = 0.5 }, try min(df.column(1)));
    try testing.expectEqual(Value{ .float = 2.25 }, try max(df.column(1)));
}

test "a single-row column is its own minimum and maximum" {
    var df = try columnOf("n\n42\n");
    defer df.deinit();

    try testing.expectEqual(Value{ .int = 42 }, try min(df.column(0)));
    try testing.expectEqual(Value{ .int = 42 }, try max(df.column(0)));
    try testing.expectEqual(@as(f64, 42), try mean(df.column(0)));
}

test "an empty string column reports its type, not its emptiness" {
    // Every reduction must agree on which complaint comes first, or the same
    // column would explain itself differently depending on the question.
    const column: Column = .{ .string = .{ .offsets = &.{0}, .data = "" } };

    try testing.expectError(AggError.NotNumeric, sum(column));
    try testing.expectError(AggError.NotNumeric, mean(column));
    try testing.expectError(AggError.NotNumeric, min(column));
    try testing.expectError(AggError.NotNumeric, max(column));
}

test "string columns refuse arithmetic" {
    var df = try columnOf("s\nada\n");
    defer df.deinit();

    try testing.expectError(AggError.NotNumeric, sum(df.column(0)));
    try testing.expectError(AggError.NotNumeric, mean(df.column(0)));
    try testing.expectError(AggError.NotNumeric, min(df.column(0)));
    try testing.expectError(AggError.NotNumeric, max(df.column(0)));
}

test "an integer sum that leaves the i64 range is an error, not a wrap" {
    const column: Column = .{ .int = &.{ std.math.maxInt(i64), 1 } };
    try testing.expectError(AggError.SumOverflow, sum(column));

    const negative: Column = .{ .int = &.{ std.math.minInt(i64), -1 } };
    try testing.expectError(AggError.SumOverflow, sum(negative));
}

test "Value converts to float for callers that want one type" {
    try testing.expectEqual(@as(f64, 3), (Value{ .int = 3 }).asFloat());
    try testing.expectEqual(@as(f64, 0.5), (Value{ .float = 0.5 }).asFloat());
}

test "reduces a large column" {
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "n\n");

    var buf: [32]u8 = undefined;
    for (1..10_001) |i| try text.appendSlice(gpa, try std.fmt.bufPrint(&buf, "{d}\n", .{i}));

    var df = try DataFrame.parse(gpa, text.items);
    defer df.deinit();

    try testing.expectEqual(Value{ .int = 10_000 * 10_001 / 2 }, try sum(df.column(0)));
    try testing.expectEqual(Value{ .int = 1 }, try min(df.column(0)));
    try testing.expectEqual(Value{ .int = 10_000 }, try max(df.column(0)));
    try testing.expectEqual(@as(f64, 5000.5), try mean(df.column(0)));
}
