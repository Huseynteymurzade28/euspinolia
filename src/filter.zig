//! Row selection by comparing one column against a value.
//!
//! A filter is two passes over the frame: `compare` walks one typed column and
//! writes a boolean per row, then `DataFrame.take` gathers the rows that
//! passed. Keeping the mask explicit means several conditions can be combined
//! before anything is copied.

const std = @import("std");
const frame = @import("frame.zig");

const Allocator = std.mem.Allocator;
const Column = frame.Column;
const DataFrame = frame.DataFrame;

pub const FilterError = error{
    /// Compared text against a number, or a number against text.
    TypeMismatch,
};

/// Comparison operators. Values are part of the ABI: append, never renumber.
pub const Op = enum(u8) {
    eq = 0,
    ne = 1,
    lt = 2,
    le = 3,
    gt = 4,
    ge = 5,

    fn holds(self: Op, comptime T: type, lhs: T, rhs: T) bool {
        return switch (self) {
            .eq => lhs == rhs,
            .ne => lhs != rhs,
            .lt => lhs < rhs,
            .le => lhs <= rhs,
            .gt => lhs > rhs,
            .ge => lhs >= rhs,
        };
    }

    fn holdsOrder(self: Op, order: std.math.Order) bool {
        return switch (self) {
            .eq => order == .eq,
            .ne => order != .eq,
            .lt => order == .lt,
            .le => order != .gt,
            .gt => order == .gt,
            .ge => order != .lt,
        };
    }
};

/// The right-hand side of a comparison.
pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
};

/// Writes `column <op> value` for every row into `mask`.
///
/// Numbers compare across `int` and `float` the way arithmetic would, by
/// widening the integer side to `f64`. Strings compare bytewise, which is
/// lexicographic for ASCII and a consistent total order for anything else.
/// Text against a number is `TypeMismatch` rather than a silent "never
/// equal": that comparison is almost always a mistake worth hearing about.
pub fn compare(column: Column, op: Op, value: Value, mask: []bool) FilterError!void {
    std.debug.assert(mask.len == column.len());

    switch (column) {
        .int => |values| switch (value) {
            .int => |rhs| fill(i64, values, op, rhs, mask),
            .float => |rhs| for (values, mask) |lhs, *out| {
                out.* = op.holds(f64, @floatFromInt(lhs), rhs);
            },
            .string => return FilterError.TypeMismatch,
        },
        .float => |values| switch (value) {
            .int => |rhs| fill(f64, values, op, @floatFromInt(rhs), mask),
            .float => |rhs| fill(f64, values, op, rhs, mask),
            .string => return FilterError.TypeMismatch,
        },
        .string => |values| switch (value) {
            .string => |rhs| for (mask, 0..) |*out, i| {
                out.* = op.holdsOrder(std.mem.order(u8, values.get(i), rhs));
            },
            else => return FilterError.TypeMismatch,
        },
    }
}

fn fill(comptime T: type, values: []const T, op: Op, rhs: T, mask: []bool) void {
    for (values, mask) |lhs, *out| out.* = op.holds(T, lhs, rhs);
}

/// A new frame holding the rows where `column <op> value` holds.
pub fn filter(gpa: Allocator, df: DataFrame, index: usize, op: Op, value: Value) !DataFrame {
    const mask = try gpa.alloc(bool, df.rowCount());
    defer gpa.free(mask);

    try compare(df.column(index), op, value, mask);
    return df.take(gpa, mask);
}

const testing = std.testing;

fn maskOf(column: Column, op: Op, value: Value) ![]bool {
    const mask = try testing.allocator.alloc(bool, column.len());
    errdefer testing.allocator.free(mask);
    try compare(column, op, value, mask);
    return mask;
}

test "every operator on an integer column" {
    const column: Column = .{ .int = &.{ 1, 2, 3 } };
    const expectations = [_]struct { Op, [3]bool }{
        .{ .eq, .{ false, true, false } },
        .{ .ne, .{ true, false, true } },
        .{ .lt, .{ true, false, false } },
        .{ .le, .{ true, true, false } },
        .{ .gt, .{ false, false, true } },
        .{ .ge, .{ false, true, true } },
    };

    for (expectations) |case| {
        const mask = try maskOf(column, case[0], .{ .int = 2 });
        defer testing.allocator.free(mask);
        try testing.expectEqualSlices(bool, &case[1], mask);
    }
}

test "every operator on a string column" {
    var df = try DataFrame.parse(testing.allocator, "s\nada\nbob\ncy\n", .{});
    defer df.deinit();

    const expectations = [_]struct { Op, [3]bool }{
        .{ .eq, .{ false, true, false } },
        .{ .ne, .{ true, false, true } },
        .{ .lt, .{ true, false, false } },
        .{ .le, .{ true, true, false } },
        .{ .gt, .{ false, false, true } },
        .{ .ge, .{ false, true, true } },
    };

    for (expectations) |case| {
        const mask = try maskOf(df.column(0), case[0], .{ .string = "bob" });
        defer testing.allocator.free(mask);
        try testing.expectEqualSlices(bool, &case[1], mask);
    }
}

test "numbers compare across int and float" {
    const ints: Column = .{ .int = &.{ 1, 2, 3 } };
    const floats: Column = .{ .float = &.{ 1.0, 2.5, 3.0 } };

    const int_vs_float = try maskOf(ints, .gt, .{ .float = 1.5 });
    defer testing.allocator.free(int_vs_float);
    try testing.expectEqualSlices(bool, &.{ false, true, true }, int_vs_float);

    const float_vs_int = try maskOf(floats, .eq, .{ .int = 3 });
    defer testing.allocator.free(float_vs_int);
    try testing.expectEqualSlices(bool, &.{ false, false, true }, float_vs_int);
}

test "string order is bytewise, so a prefix sorts first" {
    var df = try DataFrame.parse(testing.allocator, "s\nab\nabc\na\n", .{});
    defer df.deinit();

    const mask = try maskOf(df.column(0), .lt, .{ .string = "abc" });
    defer testing.allocator.free(mask);
    try testing.expectEqualSlices(bool, &.{ true, false, true }, mask);
}

test "comparing across text and numbers is an error" {
    var df = try DataFrame.parse(testing.allocator, "n,s\n1,ada\n", .{});
    defer df.deinit();
    var mask: [1]bool = undefined;

    try testing.expectError(FilterError.TypeMismatch, compare(df.column(0), .eq, .{ .string = "1" }, &mask));
    try testing.expectError(FilterError.TypeMismatch, compare(df.column(1), .eq, .{ .int = 1 }, &mask));
    try testing.expectError(FilterError.TypeMismatch, compare(df.column(1), .eq, .{ .float = 1 }, &mask));
}

test "a NaN on the right matches nothing but ne" {
    // The columns never hold NaN, but a caller can pass one in. IEEE says it
    // compares unequal to everything, including itself; keep that rather than
    // inventing an order for it.
    const column: Column = .{ .float = &.{ 1.0, 2.0 } };
    const nan = std.math.nan(f64);

    const eq = try maskOf(column, .eq, .{ .float = nan });
    defer testing.allocator.free(eq);
    try testing.expectEqualSlices(bool, &.{ false, false }, eq);

    const ne = try maskOf(column, .ne, .{ .float = nan });
    defer testing.allocator.free(ne);
    try testing.expectEqualSlices(bool, &.{ true, true }, ne);

    const lt = try maskOf(column, .lt, .{ .float = nan });
    defer testing.allocator.free(lt);
    try testing.expectEqualSlices(bool, &.{ false, false }, lt);
}

test "filter returns a frame with only the matching rows" {
    var df = try DataFrame.parse(testing.allocator, "name,age\nada,36\ngrace,45\njohn,29\n", .{});
    defer df.deinit();

    var adults = try filter(testing.allocator, df, 1, .ge, .{ .int = 35 });
    defer adults.deinit();

    try testing.expectEqual(@as(usize, 2), adults.rowCount());
    try testing.expectEqualSlices(i64, &.{ 36, 45 }, adults.ints(1).?);
    try testing.expectEqualStrings("grace", adults.strings(0).?.get(1));
    // The source is untouched.
    try testing.expectEqual(@as(usize, 3), df.rowCount());
}

test "filter can match nothing or everything" {
    var df = try DataFrame.parse(testing.allocator, "n\n1\n2\n", .{});
    defer df.deinit();

    var none = try filter(testing.allocator, df, 0, .gt, .{ .int = 5 });
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.rowCount());
    try testing.expectEqual(.int, none.columnType(0));

    var all = try filter(testing.allocator, df, 0, .gt, .{ .int = 0 });
    defer all.deinit();
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, all.ints(0).?);
}

test "filter on an empty frame is an empty frame" {
    var df = try DataFrame.parse(testing.allocator, "a\n", .{});
    defer df.deinit();

    var out = try filter(testing.allocator, df, 0, .eq, .{ .string = "x" });
    defer out.deinit();
    try testing.expectEqual(@as(usize, 0), out.rowCount());
}

test "filter propagates a type mismatch" {
    var df = try DataFrame.parse(testing.allocator, "s\nada\n", .{});
    defer df.deinit();

    try testing.expectError(
        FilterError.TypeMismatch,
        filter(testing.allocator, df, 0, .eq, .{ .int = 1 }),
    );
}

test "filters a large frame" {
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "n\n");

    var buf: [32]u8 = undefined;
    for (0..10_000) |i| try text.appendSlice(gpa, try std.fmt.bufPrint(&buf, "{d}\n", .{i}));

    var df = try DataFrame.parse(gpa, text.items, .{});
    defer df.deinit();

    var out = try filter(gpa, df, 0, .ge, .{ .int = 9_000 });
    defer out.deinit();

    try testing.expectEqual(@as(usize, 1_000), out.rowCount());
    try testing.expectEqual(@as(i64, 9_000), out.ints(0).?[0]);
    try testing.expectEqual(@as(i64, 9_999), out.ints(0).?[999]);
}
