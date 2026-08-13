//! euspinolia core.
//!
//! The library layer lives in `csv`, `dtype` and `frame`; `ffi` exposes it
//! across the C ABI. The handful of exports here are the original bridge
//! smoke-tests, kept because `self_check` still uses them to catch a stale
//! library. Every exported symbol is prefixed with `eus_`.

const std = @import("std");

pub const csv = @import("csv.zig");
pub const dtype = @import("dtype.zig");
pub const frame = @import("frame.zig");
pub const ffi = @import("ffi.zig");

comptime {
    // The exports live in `ffi`; reference it so they are analysed and land in
    // the shared library.
    _ = ffi;
}

const version_string: [:0]const u8 = "0.1.0";

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

test {
    std.testing.refAllDecls(@This());
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
    try std.testing.expectEqualStrings("0.1.0", std.mem.span(eus_version()));
}
