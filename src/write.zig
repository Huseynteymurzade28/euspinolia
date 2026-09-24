//! Serialise a `DataFrame` back to CSV.
//!
//! The output is the subset of RFC 4180 the parser reads: a header record,
//! `\n` line endings, and a field quoted only when it needs to be — when it
//! holds the delimiter, a quote, or a line break. Reading the result back
//! with the same delimiter yields the same frame, types included.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const csv = @import("csv.zig");
const frame = @import("frame.zig");
const DataFrame = frame.DataFrame;

/// Writes `df` as CSV to `w`. `options` must already be valid.
pub fn write(df: DataFrame, w: *Writer, options: csv.Options) Writer.Error!void {
    const delimiter = options.delimiter;
    for (df.names, 0..) |name, i| {
        if (i > 0) try w.writeByte(delimiter);
        try writeField(w, name, delimiter);
    }
    try w.writeByte('\n');

    for (0..df.rowCount()) |row| {
        for (df.columns, 0..) |column, i| {
            if (i > 0) try w.writeByte(delimiter);
            switch (column) {
                .int => |values| try w.print("{d}", .{values[row]}),
                .float => |values| try writeFloat(w, values[row]),
                .string => |values| try writeField(w, values.get(row), delimiter),
            }
        }
        try w.writeByte('\n');
    }
}

/// `df` as CSV in a buffer the caller owns and frees with `gpa`.
pub fn toOwnedSlice(gpa: Allocator, df: DataFrame, options: csv.Options) ![]u8 {
    try options.validate();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    write(df, &out.writer, options) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeField(w: *Writer, text: []const u8, delimiter: u8) Writer.Error!void {
    const special = [_]u8{ delimiter, '"', '\r', '\n' };
    if (std.mem.indexOfAny(u8, text, &special) == null) return w.writeAll(text);

    try w.writeByte('"');
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '"')) |at| {
        try w.writeAll(rest[0 .. at + 1]);
        try w.writeByte('"');
        rest = rest[at + 1 ..];
    }
    try w.writeAll(rest);
    try w.writeByte('"');
}

/// The shortest decimal that reads back as the same value, always with a
/// `.` or an exponent so the column is inferred as float again. Very large
/// and very small magnitudes go scientific rather than spelling out hundreds
/// of digits.
fn writeFloat(w: *Writer, value: f64) Writer.Error!void {
    const magnitude = @abs(value);
    if (magnitude >= 1e16 or (magnitude != 0 and magnitude < 1e-4)) {
        return w.print("{e}", .{value});
    }

    var buf: [32]u8 = undefined;
    var fixed: Writer = .fixed(&buf);
    fixed.print("{d}", .{value}) catch unreachable;
    const text = fixed.buffered();

    try w.writeAll(text);
    if (std.mem.indexOfScalar(u8, text, '.') == null) try w.writeAll(".0");
}

const testing = std.testing;

fn roundTrip(text: []const u8) ![]u8 {
    var df = try DataFrame.parse(testing.allocator, text, .{});
    defer df.deinit();
    return toOwnedSlice(testing.allocator, df, .{});
}

test "writes a header and one record per row" {
    const out = try roundTrip("name,age,score\nada,36,91.5\ngrace,45,88.0\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("name,age,score\nada,36,91.5\ngrace,45,88.0\n", out);
}

test "a header alone is still a record" {
    const out = try roundTrip("a,b\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a,b\n", out);
}

test "quotes only the fields that need it" {
    const out = try roundTrip("s\n\"Doe, John\"\n\"say \"\"hi\"\"\"\n\"two\nlines\"\nplain\n\"\"\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("s\n\"Doe, John\"\n\"say \"\"hi\"\"\"\n\"two\nlines\"\nplain\n\n", out);
}

test "quotes a header that needs it" {
    const out = try roundTrip("\"a,b\",c\n1,2\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\"a,b\",c\n1,2\n", out);
}

test "floats keep their type across a round trip" {
    const out = try roundTrip("x\n88.0\n-0.0\n0.1\n1e300\n0.00001\n123456789.25\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("x\n88.0\n-0.0\n0.1\n1e300\n1e-5\n123456789.25\n", out);

    var again = try DataFrame.parse(testing.allocator, out, .{});
    defer again.deinit();
    try testing.expectEqualSlices(f64, &.{ 88.0, -0.0, 0.1, 1e300, 0.00001, 123456789.25 }, again.floats(0).?);
}

test "a written frame parses back to the same frame" {
    var df = try DataFrame.parse(testing.allocator, "n,x,s\n1,0.5,\"a,b\"\n-2,2.5,\n3,-1.25,q\"q\n", .{});
    defer df.deinit();
    const out = try toOwnedSlice(testing.allocator, df, .{});
    defer testing.allocator.free(out);

    var again = try DataFrame.parse(testing.allocator, out, .{});
    defer again.deinit();

    try testing.expectEqualSlices(i64, df.ints(0).?, again.ints(0).?);
    try testing.expectEqualSlices(f64, df.floats(1).?, again.floats(1).?);
    try testing.expectEqualStrings(df.strings(2).?.data, again.strings(2).?.data);
    try testing.expectEqualSlices(usize, df.strings(2).?.offsets, again.strings(2).?.offsets);
}

test "writes with another delimiter, quoting only what now needs it" {
    var df = try DataFrame.parse(testing.allocator, "name,note\nada,\"a,b\"\ngrace,x;y\n", .{});
    defer df.deinit();
    const out = try toOwnedSlice(testing.allocator, df, .{ .delimiter = ';' });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("name;note\nada;a,b\ngrace;\"x;y\"\n", out);

    var again = try DataFrame.parse(testing.allocator, out, .{ .delimiter = ';' });
    defer again.deinit();
    try testing.expectEqualStrings("a,b", again.strings(1).?.get(0));
    try testing.expectEqualStrings("x;y", again.strings(1).?.get(1));
}

test "refuses a delimiter the format reserves" {
    var df = try DataFrame.parse(testing.allocator, "a\n1\n", .{});
    defer df.deinit();
    try testing.expectError(error.InvalidDelimiter, toOwnedSlice(testing.allocator, df, .{ .delimiter = '"' }));
}
