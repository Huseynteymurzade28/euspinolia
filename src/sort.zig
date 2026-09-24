//! Row order by one column.
//!
//! Sorting is two steps, like filtering: `permutation` sorts row indices by
//! the key column, then `DataFrame.reorder` gathers every column in that
//! order. Sorting indices rather than rows means only one column is ever
//! compared, and the frame is copied exactly once.

const std = @import("std");
const frame = @import("frame.zig");

const Allocator = std.mem.Allocator;
const Column = frame.Column;
const DataFrame = frame.DataFrame;
const StringColumn = frame.StringColumn;

/// The row indices of `column` in sorted order. Caller owns the slice.
///
/// The sort is stable, descending included: rows with equal keys keep their
/// original order, so sorting by a second column and then by a first gives
/// a two-key order. Strings order bytewise, as in `filter`.
pub fn permutation(gpa: Allocator, column: Column, descending: bool) ![]usize {
    const order = try gpa.alloc(usize, column.len());
    for (order, 0..) |*slot, i| slot.* = i;

    switch (column) {
        .int => |values| try sortNumbers(i64, gpa, values, descending, order),
        .float => |values| try sortNumbers(f64, gpa, values, descending, order),
        .string => |values| std.mem.sort(usize, order, Strings{ .values = values, .descending = descending }, Strings.lessThan),
    }
    return order;
}

/// A new frame with the rows of `df` sorted by column `index`.
pub fn sortBy(gpa: Allocator, df: DataFrame, index: usize, descending: bool) !DataFrame {
    const order = try permutation(gpa, df.column(index), descending);
    defer gpa.free(order);
    return df.reorder(gpa, order);
}

/// Numbers skip comparisons entirely: each value becomes a `u64` whose
/// unsigned order is the numeric order, and an LSD radix sort orders the
/// `(key, row)` pairs one byte at a time, least significant first. Every
/// pass is a stable counting sort, so the whole is stable, and a pass whose
/// byte is the same for every key — the high bytes of small integers — is
/// skipped. Descending order is the same sort over the complemented keys.
fn sortNumbers(
    comptime T: type,
    gpa: Allocator,
    values: []const T,
    descending: bool,
    order: []usize,
) !void {
    const pairs = try gpa.alloc(Pair, values.len * 2);
    defer gpa.free(pairs);
    var from = pairs[0..values.len];
    var to = pairs[values.len..];

    var counts = std.mem.zeroes([8][256]usize);
    for (from, values, 0..) |*pair, value, row| {
        const key = sortKey(T, value);
        pair.* = .{ .key = if (descending) ~key else key, .row = row };
        for (&counts, 0..) |*count, digit| count[byteOf(pair.key, digit)] += 1;
    }

    for (&counts, 0..) |*count, digit| {
        if (std.mem.indexOfScalar(usize, count, values.len) != null) continue;

        var at: usize = 0;
        for (count) |*slot| {
            const n = slot.*;
            slot.* = at;
            at += n;
        }
        for (from) |pair| {
            const bucket = &count[byteOf(pair.key, digit)];
            to[bucket.*] = pair;
            bucket.* += 1;
        }
        std.mem.swap([]Pair, &from, &to);
    }

    for (order, from) |*slot, pair| slot.* = pair.row;
}

const Pair = struct { key: u64, row: usize };

fn byteOf(key: u64, digit: usize) u8 {
    return @truncate(key >> @intCast(digit * 8));
}

/// A `u64` that orders, unsigned, the way `value` orders numerically.
fn sortKey(comptime T: type, value: T) u64 {
    const sign: u64 = 1 << 63;
    switch (T) {
        // Two's complement is unsigned order with the sign bit's weight
        // reversed; flipping it moves negatives below positives.
        i64 => return @as(u64, @bitCast(value)) ^ sign,
        // IEEE 754 positives already order as their bits; negatives order
        // backwards, so all their bits flip. `-0.0` is folded into `0.0` first
        // so the two stay equal, and keep their order, as they compare.
        f64 => {
            const bits: u64 = @bitCast(if (value == 0) 0.0 else value);
            return if (bits & sign != 0) ~bits else bits | sign;
        },
        else => @compileError("no sort key for " ++ @typeName(T)),
    }
}

const Strings = struct {
    values: StringColumn,
    descending: bool,

    fn lessThan(self: Strings, a: usize, b: usize) bool {
        const lhs, const rhs = if (self.descending) .{ b, a } else .{ a, b };
        return std.mem.order(u8, self.values.get(lhs), self.values.get(rhs)) == .lt;
    }
};

const testing = std.testing;

fn expectOrder(column: Column, descending: bool, expected: []const usize) !void {
    const order = try permutation(testing.allocator, column, descending);
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(usize, expected, order);
}

test "orders integers both ways" {
    const column: Column = .{ .int = &.{ 3, -1, 2 } };
    try expectOrder(column, false, &.{ 1, 2, 0 });
    try expectOrder(column, true, &.{ 0, 2, 1 });
}

test "orders floats" {
    try expectOrder(.{ .float = &.{ 0.5, -2.5, 1e300 } }, false, &.{ 1, 0, 2 });
}

test "keys order across sign and magnitude" {
    const ints = [_]i64{ std.math.minInt(i64), -256, -1, 0, 1, 255, 256, std.math.maxInt(i64) };
    for (ints[0 .. ints.len - 1], ints[1..]) |a, b| try testing.expect(sortKey(i64, a) < sortKey(i64, b));

    const floats = [_]f64{ -std.math.floatMax(f64), -1.5, -1e-300, 0.0, 1e-300, 1.5, std.math.floatMax(f64) };
    for (floats[0 .. floats.len - 1], floats[1..]) |a, b| try testing.expect(sortKey(f64, a) < sortKey(f64, b));
    try testing.expectEqual(sortKey(f64, 0.0), sortKey(f64, -0.0));
}

test "negative zero ties with zero and keeps its place" {
    try expectOrder(.{ .float = &.{ 0.0, -0.0, -1.0, 0.0 } }, false, &.{ 2, 0, 1, 3 });
}

test "matches a comparison sort on scattered integers" {
    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();
    var values: [2000]i64 = undefined;
    // A narrow range forces many ties; the wide one exercises every byte.
    for (values[0..1000]) |*v| v.* = random.intRangeAtMost(i64, -20, 20);
    for (values[1000..]) |*v| v.* = random.int(i64);

    for ([_]bool{ false, true }) |descending| {
        const order = try permutation(testing.allocator, .{ .int = &values }, descending);
        defer testing.allocator.free(order);

        const expected = try testing.allocator.alloc(usize, values.len);
        defer testing.allocator.free(expected);
        for (expected, 0..) |*slot, i| slot.* = i;
        const Context = struct {
            values: []const i64,
            descending: bool,
            fn lessThan(self: @This(), a: usize, b: usize) bool {
                const x, const y = if (self.descending) .{ b, a } else .{ a, b };
                return self.values[x] < self.values[y];
            }
        };
        std.mem.sort(usize, expected, Context{ .values = &values, .descending = descending }, Context.lessThan);
        try testing.expectEqualSlices(usize, expected, order);
    }
}

test "orders strings bytewise" {
    var df = try DataFrame.parse(testing.allocator, "s\nb\nB\na\n\"\"\n", .{});
    defer df.deinit();
    // "" < "B" < "a" < "b": uppercase sorts before lowercase in ASCII.
    try expectOrder(df.column(0), false, &.{ 3, 1, 2, 0 });
}

test "equal keys keep their order, descending included" {
    const column: Column = .{ .int = &.{ 1, 2, 1, 2 } };
    try expectOrder(column, false, &.{ 0, 2, 1, 3 });
    try expectOrder(column, true, &.{ 1, 3, 0, 2 });
}

test "sortBy moves every column with its key" {
    var df = try DataFrame.parse(testing.allocator, "n,s,x\n3,c,0.3\n1,a,0.1\n2,,0.2\n", .{});
    var sorted = try sortBy(testing.allocator, df, 0, false);
    defer sorted.deinit();
    df.deinit();

    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, sorted.ints(0).?);
    try testing.expectEqualStrings("a", sorted.strings(1).?.get(0));
    try testing.expectEqualStrings("", sorted.strings(1).?.get(1));
    try testing.expectEqualStrings("c", sorted.strings(1).?.get(2));
    try testing.expectEqualSlices(f64, &.{ 0.1, 0.2, 0.3 }, sorted.floats(2).?);
}

test "sorting an empty frame gives an empty frame" {
    var df = try DataFrame.parse(testing.allocator, "n\n", .{});
    defer df.deinit();
    var sorted = try sortBy(testing.allocator, df, 0, true);
    defer sorted.deinit();
    try testing.expectEqual(@as(usize, 0), sorted.rowCount());
}
