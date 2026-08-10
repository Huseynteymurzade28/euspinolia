//! euspinolia core.
//!
//! Phase 0: no data structures yet — these exports only prove that Python can
//! load the library and call across the C ABI. Every exported symbol is
//! prefixed with `eus_`.

const std = @import("std");

const version_string: [:0]const u8 = "0.0.1";

/// Signature value returned by `eus_ping`; mismatches mean a stale library.
pub const magic: i32 = 0xE05;

export fn eus_ping() i32 {
    return magic;
}

export fn eus_add(a: i64, b: i64) i64 {
    return a +% b;
}

/// Null-terminated, statically allocated. The caller must not free it.
export fn eus_version() [*:0]const u8 {
    return version_string.ptr;
}

test "ping returns the magic signature" {
    try std.testing.expectEqual(magic, eus_ping());
}

test "add handles basic arithmetic" {
    try std.testing.expectEqual(@as(i64, 7), eus_add(3, 4));
    try std.testing.expectEqual(@as(i64, -1), eus_add(-4, 3));
}

test "add wraps on overflow" {
    try std.testing.expectEqual(std.math.minInt(i64), eus_add(std.math.maxInt(i64), 1));
}

test "version is a readable string" {
    try std.testing.expectEqualStrings("0.0.1", std.mem.span(eus_version()));
}
