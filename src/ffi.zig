//! The C ABI surface Python calls through `ctypes`.
//!
//! Conventions, so the Python side can stay thin:
//!
//! - Every symbol is prefixed with `eus_`.
//! - A `DataFrame` crosses the boundary as an opaque pointer. It is created by
//!   `eus_read_csv` / `eus_parse_csv` and must be released with
//!   `eus_frame_free`; nothing else owns it.
//! - Functions that can fail return an `i32` status (`Status`) and write their
//!   result through an out-parameter. Zig error sets do not survive the C ABI,
//!   so every error is mapped to a status code once, here.
//! - Column data is handed out as borrowed pointers into the frame's arena.
//!   They stay valid until `eus_frame_free`, and the caller must not write to
//!   or free them.

const std = @import("std");
const builtin = @import("builtin");

const agg = @import("agg.zig");
const csv = @import("csv.zig");
const dtype = @import("dtype.zig");
const frame = @import("frame.zig");

const DataFrame = frame.DataFrame;

var debug_gpa: std.heap.DebugAllocator(.{}) = .init;

/// Frames outlive the call that created them, so they cannot come from a
/// scratch arena; this is the process-wide allocator behind the C ABI.
fn allocator() std.mem.Allocator {
    return if (builtin.mode == .Debug) debug_gpa.allocator() else std.heap.smp_allocator;
}

/// Status codes returned across the boundary. Values are part of the ABI:
/// append to the end, never renumber.
pub const Status = enum(i32) {
    ok = 0,
    out_of_memory = 1,
    file_not_found = 2,
    access_denied = 3,
    is_a_directory = 4,
    io_failed = 5,
    file_too_large = 6,
    unterminated_quote = 7,
    unexpected_character_after_quote = 8,
    inconsistent_field_count = 9,
    missing_header = 10,
    invalid_number = 11,
    column_out_of_range = 12,
    not_numeric = 13,
    empty_column = 14,
    sum_overflow = 15,
    unknown = 99,

    fn message(self: Status) [:0]const u8 {
        return switch (self) {
            .ok => "ok",
            .out_of_memory => "out of memory",
            .file_not_found => "no such file",
            .access_denied => "permission denied",
            .is_a_directory => "path is a directory",
            .io_failed => "the file could not be read",
            .file_too_large => "the file is larger than the read limit",
            .unterminated_quote => "a quoted field is never closed",
            .unexpected_character_after_quote => "unexpected character after a closing quote",
            .inconsistent_field_count => "a record has a different field count than the header",
            .missing_header => "the input has no header record",
            .invalid_number => "a cell did not parse as the type inferred for its column",
            .column_out_of_range => "no column at that position",
            .not_numeric => "this operation needs a numeric column",
            .empty_column => "a column with no rows has no value here",
            .sum_overflow => "the sum left the range of a 64-bit integer",
            .unknown => "unknown error",
        };
    }
};

fn statusFor(err: anyerror) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.FileNotFound => .file_not_found,
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.IsDir => .is_a_directory,
        error.StreamTooLong => .file_too_large,
        error.UnterminatedQuote => .unterminated_quote,
        error.UnexpectedCharacterAfterQuote => .unexpected_character_after_quote,
        error.InconsistentFieldCount => .inconsistent_field_count,
        error.MissingHeader => .missing_header,
        error.InvalidNumber => .invalid_number,
        error.NotNumeric => .not_numeric,
        error.EmptyColumn => .empty_column,
        error.SumOverflow => .sum_overflow,
        // Everything left is some flavour of read failure. Collapsing it keeps
        // the ABI small; the distinctions are not actionable from Python.
        else => .io_failed,
    };
}

/// Human-readable text for a status code. Statically allocated; do not free.
export fn eus_status_message(code: i32) [*:0]const u8 {
    const status = std.enums.fromInt(Status, code) orelse Status.unknown;
    return status.message().ptr;
}

/// Reads and parses a CSV file. On success `out_frame` receives a frame the
/// caller must release with `eus_frame_free`; on failure it is left untouched.
export fn eus_read_csv(
    path_ptr: [*]const u8,
    path_len: usize,
    out_frame: *?*DataFrame,
) i32 {
    const gpa = allocator();

    // A shared library has no `main` to own an event loop, so the caller's
    // thread runs the read itself.
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const parsed = DataFrame.parseFile(
        gpa,
        io,
        std.Io.Dir.cwd(),
        path_ptr[0..path_len],
        .unlimited,
    ) catch |err| return @intFromEnum(statusFor(err));

    return publish(gpa, parsed, out_frame);
}

/// Parses CSV text already in memory. The bytes are copied, so the caller may
/// free them as soon as this returns.
export fn eus_parse_csv(
    text_ptr: [*]const u8,
    text_len: usize,
    out_frame: *?*DataFrame,
) i32 {
    const gpa = allocator();
    const parsed = DataFrame.parse(gpa, text_ptr[0..text_len]) catch |err|
        return @intFromEnum(statusFor(err));

    return publish(gpa, parsed, out_frame);
}

/// Moves a frame onto the heap so it can outlive this call.
fn publish(gpa: std.mem.Allocator, parsed: DataFrame, out_frame: *?*DataFrame) i32 {
    const handle = gpa.create(DataFrame) catch {
        var owned = parsed;
        owned.deinit();
        return @intFromEnum(Status.out_of_memory);
    };
    handle.* = parsed;
    out_frame.* = handle;
    return @intFromEnum(Status.ok);
}

/// Releases a frame and every buffer handed out for it. Ignores null.
export fn eus_frame_free(handle: ?*DataFrame) void {
    const df = handle orelse return;
    df.deinit();
    allocator().destroy(df);
}

export fn eus_frame_rows(handle: *const DataFrame) usize {
    return handle.rowCount();
}

export fn eus_frame_columns(handle: *const DataFrame) usize {
    return handle.columnCount();
}

/// The column's type as a `dtype.ColumnType` tag, or -1 if `index` is out of
/// range.
export fn eus_frame_column_type(handle: *const DataFrame, index: usize) i32 {
    if (index >= handle.columnCount()) return -1;
    return @intFromEnum(handle.columnType(index));
}

/// Borrowed, *not* null-terminated: the name is `out_len` bytes long. Returns
/// null if `index` is out of range.
export fn eus_frame_column_name(
    handle: *const DataFrame,
    index: usize,
    out_len: *usize,
) ?[*]const u8 {
    if (index >= handle.columnCount()) return null;
    const name = handle.names[index];
    out_len.* = name.len;
    return name.ptr;
}

/// The column's position, or -1 if no column carries that name.
export fn eus_frame_column_index(
    handle: *const DataFrame,
    name_ptr: [*]const u8,
    name_len: usize,
) isize {
    const index = handle.columnIndex(name_ptr[0..name_len]) orelse return -1;
    return @intCast(index);
}

/// Borrowed pointer to `eus_frame_rows` values, or null if the column is out
/// of range or holds something other than integers.
export fn eus_frame_ints(handle: *const DataFrame, index: usize) ?[*]const i64 {
    if (index >= handle.columnCount()) return null;
    return (handle.ints(index) orelse return null).ptr;
}

/// Borrowed pointer to `eus_frame_rows` values, or null if the column is out
/// of range or holds something other than floats.
export fn eus_frame_floats(handle: *const DataFrame, index: usize) ?[*]const f64 {
    if (index >= handle.columnCount()) return null;
    return (handle.floats(index) orelse return null).ptr;
}

/// Borrowed pointer to `eus_frame_rows + 1` offsets into the buffer returned by
/// `eus_frame_string_data`. Null unless the column holds strings.
export fn eus_frame_string_offsets(handle: *const DataFrame, index: usize) ?[*]const usize {
    if (index >= handle.columnCount()) return null;
    return (handle.strings(index) orelse return null).offsets.ptr;
}

/// Borrowed pointer to the packed text of a string column, `out_len` bytes
/// long. Null unless the column holds strings.
///
/// The buffer is empty when every value is, in which case the pointer may be
/// null with a zero length — read it only through the offsets.
export fn eus_frame_string_data(
    handle: *const DataFrame,
    index: usize,
    out_len: *usize,
) ?[*]const u8 {
    if (index >= handle.columnCount()) return null;
    const column = handle.strings(index) orelse return null;
    out_len.* = column.data.len;
    return column.data.ptr;
}

/// Reductions keep the column's type, so `sum`, `min` and `max` write through
/// whichever out-parameter matches it. The caller already knows the type from
/// `eus_frame_column_type`, and this keeps integer results exact instead of
/// rounding them through `f64`.
fn reduce(
    handle: *const DataFrame,
    index: usize,
    comptime operation: fn (frame.Column) agg.AggError!agg.Value,
    out_int: *i64,
    out_float: *f64,
) i32 {
    if (index >= handle.columnCount()) return @intFromEnum(Status.column_out_of_range);

    const value = operation(handle.column(index)) catch |err|
        return @intFromEnum(statusFor(err));

    switch (value) {
        .int => |v| out_int.* = v,
        .float => |v| out_float.* = v,
    }
    return @intFromEnum(Status.ok);
}

export fn eus_column_sum(
    handle: *const DataFrame,
    index: usize,
    out_int: *i64,
    out_float: *f64,
) i32 {
    return reduce(handle, index, agg.sum, out_int, out_float);
}

export fn eus_column_min(
    handle: *const DataFrame,
    index: usize,
    out_int: *i64,
    out_float: *f64,
) i32 {
    return reduce(handle, index, agg.min, out_int, out_float);
}

export fn eus_column_max(
    handle: *const DataFrame,
    index: usize,
    out_int: *i64,
    out_float: *f64,
) i32 {
    return reduce(handle, index, agg.max, out_int, out_float);
}

/// The mean is always a float, whatever the column holds.
export fn eus_column_mean(handle: *const DataFrame, index: usize, out: *f64) i32 {
    if (index >= handle.columnCount()) return @intFromEnum(Status.column_out_of_range);

    out.* = agg.mean(handle.column(index)) catch |err| return @intFromEnum(statusFor(err));
    return @intFromEnum(Status.ok);
}

const testing = std.testing;

/// Mirrors what the Python layer does: parse, then read back through the ABI.
fn parseForTest(text: []const u8) !*DataFrame {
    var handle: ?*DataFrame = null;
    const code = eus_parse_csv(text.ptr, text.len, &handle);
    try testing.expectEqual(@as(i32, 0), code);
    return handle.?;
}

test "parse and free round trip" {
    const df = try parseForTest("id,name\n1,ada\n2,grace\n");
    defer eus_frame_free(df);

    try testing.expectEqual(@as(usize, 2), eus_frame_rows(df));
    try testing.expectEqual(@as(usize, 2), eus_frame_columns(df));
}

test "freeing null is a no-op" {
    eus_frame_free(null);
}

test "column metadata crosses the boundary" {
    const df = try parseForTest("id,ratio,name\n1,0.5,ada\n");
    defer eus_frame_free(df);

    var len: usize = 0;
    const name = eus_frame_column_name(df, 1, &len).?;
    try testing.expectEqualStrings("ratio", name[0..len]);

    try testing.expectEqual(@intFromEnum(dtype.ColumnType.int), eus_frame_column_type(df, 0));
    try testing.expectEqual(@intFromEnum(dtype.ColumnType.float), eus_frame_column_type(df, 1));
    try testing.expectEqual(@intFromEnum(dtype.ColumnType.string), eus_frame_column_type(df, 2));

    try testing.expectEqual(@as(isize, 2), eus_frame_column_index(df, "name", 4));
    try testing.expectEqual(@as(isize, -1), eus_frame_column_index(df, "missing", 7));
}

test "out-of-range columns report themselves instead of trapping" {
    const df = try parseForTest("a\n1\n");
    defer eus_frame_free(df);

    var len: usize = 0;
    try testing.expectEqual(@as(i32, -1), eus_frame_column_type(df, 9));
    try testing.expect(eus_frame_column_name(df, 9, &len) == null);
    try testing.expect(eus_frame_ints(df, 9) == null);
    try testing.expect(eus_frame_floats(df, 9) == null);
    try testing.expect(eus_frame_string_offsets(df, 9) == null);
    try testing.expect(eus_frame_string_data(df, 9, &len) == null);
}

test "numeric columns are readable through raw pointers" {
    const df = try parseForTest("n,x\n1,0.5\n2,1.5\n");
    defer eus_frame_free(df);

    const ints = eus_frame_ints(df, 0).?;
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, ints[0..eus_frame_rows(df)]);

    const floats = eus_frame_floats(df, 1).?;
    try testing.expectEqualSlices(f64, &.{ 0.5, 1.5 }, floats[0..eus_frame_rows(df)]);

    // Asking for the wrong type is a null, not a reinterpretation.
    try testing.expect(eus_frame_floats(df, 0) == null);
    try testing.expect(eus_frame_ints(df, 1) == null);
    try testing.expect(eus_frame_string_offsets(df, 0) == null);
}

test "string columns cross as offsets plus a data buffer" {
    const df = try parseForTest("s,n\nada,1\n,2\nlovelace,3\n");
    defer eus_frame_free(df);

    const rows = eus_frame_rows(df);
    const offsets = eus_frame_string_offsets(df, 0).?[0 .. rows + 1];
    var len: usize = 0;
    const data = eus_frame_string_data(df, 0, &len).?[0..len];

    try testing.expectEqualSlices(usize, &.{ 0, 3, 3, 11 }, offsets);
    try testing.expectEqualStrings("adalovelace", data);
    try testing.expectEqualStrings("lovelace", data[offsets[2]..offsets[3]]);
}

test "parse failures come back as status codes" {
    var handle: ?*DataFrame = null;

    const missing_header = eus_parse_csv("", 0, &handle);
    try testing.expectEqual(@intFromEnum(Status.missing_header), missing_header);

    const bad = "a,b\n1,2,3\n";
    const ragged = eus_parse_csv(bad.ptr, bad.len, &handle);
    try testing.expectEqual(@intFromEnum(Status.inconsistent_field_count), ragged);

    // The out-parameter must be left alone on failure.
    try testing.expect(handle == null);
}

test "a missing file reports file_not_found" {
    var handle: ?*DataFrame = null;
    const path = "definitely-not-here.csv";
    const code = eus_read_csv(path.ptr, path.len, &handle);

    try testing.expectEqual(@intFromEnum(Status.file_not_found), code);
    try testing.expect(handle == null);
}

test "reductions cross the boundary in the column's own type" {
    const df = try parseForTest("n,x\n3,0.5\n-1,2.5\n");
    defer eus_frame_free(df);

    var as_int: i64 = 0;
    var as_float: f64 = 0;

    try testing.expectEqual(@as(i32, 0), eus_column_sum(df, 0, &as_int, &as_float));
    try testing.expectEqual(@as(i64, 2), as_int);

    try testing.expectEqual(@as(i32, 0), eus_column_min(df, 0, &as_int, &as_float));
    try testing.expectEqual(@as(i64, -1), as_int);

    try testing.expectEqual(@as(i32, 0), eus_column_max(df, 1, &as_int, &as_float));
    try testing.expectEqual(@as(f64, 2.5), as_float);

    try testing.expectEqual(@as(i32, 0), eus_column_mean(df, 1, &as_float));
    try testing.expectEqual(@as(f64, 1.5), as_float);
}

test "reductions report the reason they cannot run" {
    const df = try parseForTest("s\nada\n");
    defer eus_frame_free(df);

    var as_int: i64 = 0;
    var as_float: f64 = 0;

    try testing.expectEqual(
        @intFromEnum(Status.not_numeric),
        eus_column_sum(df, 0, &as_int, &as_float),
    );
    try testing.expectEqual(
        @intFromEnum(Status.column_out_of_range),
        eus_column_min(df, 9, &as_int, &as_float),
    );
    try testing.expectEqual(
        @intFromEnum(Status.column_out_of_range),
        eus_column_mean(df, 9, &as_float),
    );
    try testing.expectEqual(@intFromEnum(Status.not_numeric), eus_column_mean(df, 0, &as_float));
}

test "column type tags are the numbers Python expects" {
    // euspinolia/_ffi.py hardcodes these as ColumnType. Reordering the enum
    // would silently relabel every column, so pin the values here.
    try testing.expectEqual(@as(i32, 0), @intFromEnum(dtype.ColumnType.int));
    try testing.expectEqual(@as(i32, 1), @intFromEnum(dtype.ColumnType.float));
    try testing.expectEqual(@as(i32, 2), @intFromEnum(dtype.ColumnType.string));
}

test "every status has a message" {
    for (std.enums.values(Status)) |status| {
        const text = std.mem.span(eus_status_message(@intFromEnum(status)));
        try testing.expect(text.len > 0);
    }
    try testing.expectEqualStrings("unknown error", std.mem.span(eus_status_message(4242)));
}
