const std = @import("std");

/// Element type inferred for a column from its raw CSV text.
pub const ColumnType = enum {
    int,
    float,
    string,

    fn rank(self: ColumnType) u2 {
        return switch (self) {
            .int => 0,
            .float => 1,
            .string => 2,
        };
    }
};

/// The type that can hold both inputs. Widening order: int < float < string.
pub fn widen(a: ColumnType, b: ColumnType) ColumnType {
    return if (a.rank() >= b.rank()) a else b;
}

/// Infers the type of a single cell.
///
/// An empty cell infers as `.string`. This library has no missing-data
/// semantics, so a blank keeps the column textual instead of inventing a null.
pub fn inferValue(text: []const u8) ColumnType {
    if (text.len == 0) return .string;
    if (usesZigLiteralSyntax(text)) return .string;

    if (std.fmt.parseInt(i64, text, 10)) |_| {
        return .int;
    } else |_| {}

    if (std.fmt.parseFloat(f64, text)) |f| {
        // "nan" and "inf" parse successfully; keep them textual since
        // non-finite values are out of scope.
        if (std.math.isFinite(f)) return .float;
    } else |_| {}

    return .string;
}

/// Zig's parsers accept source-literal syntax that CSV data does not use:
/// `1_000` digit separators and `0x10` hex floats. Rejecting them keeps
/// inference aligned with what a spreadsheet would call a number.
fn usesZigLiteralSyntax(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, "_xX") != null;
}

/// Infers the type covering every value. An empty column infers as `.string`.
pub fn inferColumn(values: []const []const u8) ColumnType {
    if (values.len == 0) return .string;

    var result: ColumnType = .int;
    for (values) |value| {
        result = widen(result, inferValue(value));
        if (result == .string) break;
    }
    return result;
}

test "inferValue recognises integers" {
    try std.testing.expectEqual(.int, inferValue("0"));
    try std.testing.expectEqual(.int, inferValue("42"));
    try std.testing.expectEqual(.int, inferValue("-7"));
    try std.testing.expectEqual(.int, inferValue("+7"));
}

test "inferValue recognises floats" {
    try std.testing.expectEqual(.float, inferValue("1.5"));
    try std.testing.expectEqual(.float, inferValue("-0.25"));
    try std.testing.expectEqual(.float, inferValue("1e9"));
}

test "inferValue falls back to string" {
    try std.testing.expectEqual(.string, inferValue(""));
    try std.testing.expectEqual(.string, inferValue("abc"));
    try std.testing.expectEqual(.string, inferValue("12abc"));
    try std.testing.expectEqual(.string, inferValue(" 12"));
}

test "inferValue rejects Zig-only numeric syntax" {
    try std.testing.expectEqual(.string, inferValue("0x10"));
    try std.testing.expectEqual(.string, inferValue("1_000"));
}

test "inferValue treats non-finite floats as text" {
    try std.testing.expectEqual(.string, inferValue("nan"));
    try std.testing.expectEqual(.string, inferValue("inf"));
}

test "inferColumn widens to the common type" {
    try std.testing.expectEqual(.int, inferColumn(&.{ "1", "2", "3" }));
    try std.testing.expectEqual(.float, inferColumn(&.{ "1", "2.5" }));
    try std.testing.expectEqual(.string, inferColumn(&.{ "1", "2.5", "x" }));
    try std.testing.expectEqual(.string, inferColumn(&.{ "1", "" }));
    try std.testing.expectEqual(.string, inferColumn(&.{}));
}
