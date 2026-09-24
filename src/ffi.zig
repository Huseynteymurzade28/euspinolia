//! The C ABI surface Python calls through `ctypes`.
//!
//! Conventions, so the Python side can stay thin:
//!
//! - Every symbol is prefixed with `eus_`.
//! - A `DataFrame` crosses the boundary as an opaque pointer. It is created by
//!   `eus_read_csv` / `eus_parse_csv` / `eus_frame_from_columns` /
//!   `eus_frame_filter_*` / `eus_frame_select` / `eus_frame_sort` /
//!   `eus_frame_groupby` and must be released with `eus_frame_free`; nothing
//!   else owns it.
//! - Functions that can fail return an `i32` status (`Status`) and write their
//!   result through an out-parameter. Zig error sets do not survive the C ABI,
//!   so every error is mapped to a status code once, here.
//! - Column data is handed out as borrowed pointers into the frame's arena.
//!   They stay valid until `eus_frame_free`, and the caller must not write to
//!   or free them.
//! - The one buffer that is not borrowed is the CSV text from
//!   `eus_frame_to_csv`; it is released with `eus_bytes_free`.

const std = @import("std");
const builtin = @import("builtin");

const agg = @import("agg.zig");
const csv = @import("csv.zig");
const dtype = @import("dtype.zig");
const filter = @import("filter.zig");
const frame = @import("frame.zig");
const groupby = @import("groupby.zig");
const sort = @import("sort.zig");
const write = @import("write.zig");

const DataFrame = frame.DataFrame;

var debug_gpa: std.heap.DebugAllocator(.{}) = .init;

// `smp_allocator` keys its per-thread state on a `threadlocal`, and TLS in a
// DLL loaded through ctypes crashes on Windows/ARM64 with the current
// toolchain; the same general-purpose allocator with safety off, guarded by
// a mutex instead, stands in there. `Io.Threaded` has the same problem, so
// on that target the Python side reads files itself and calls
// `eus_parse_csv` rather than `eus_read_csv`.
const tls_is_broken = builtin.os.tag == .windows and builtin.cpu.arch == .aarch64;
var release_gpa: std.heap.DebugAllocator(.{ .safety = false }) = .init;

/// Frames outlive the call that created them, so they cannot come from a
/// scratch arena; this is the process-wide allocator behind the C ABI.
fn allocator() std.mem.Allocator {
    if (builtin.mode == .Debug) return debug_gpa.allocator();
    if (tls_is_broken) return release_gpa.allocator();
    return std.heap.smp_allocator;
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
    type_mismatch = 16,
    invalid_operator = 17,
    invalid_aggregate = 18,
    invalid_delimiter = 19,
    invalid_column_data = 20,
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
            .type_mismatch => "cannot compare text with a number",
            .invalid_operator => "unknown comparison operator",
            .invalid_aggregate => "unknown aggregate function",
            .invalid_delimiter => "the delimiter cannot be a quote or a line break",
            .invalid_column_data => "a column's type tag or string offsets are invalid",
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
        error.InvalidDelimiter => .invalid_delimiter,
        error.InvalidNumber => .invalid_number,
        error.NotNumeric => .not_numeric,
        error.EmptyColumn => .empty_column,
        error.SumOverflow => .sum_overflow,
        error.TypeMismatch => .type_mismatch,
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

/// Reads and parses a CSV file whose fields are separated by `delimiter`. On
/// success `out_frame` receives a frame the caller must release with
/// `eus_frame_free`; on failure it is left untouched.
export fn eus_read_csv(
    path_ptr: [*]const u8,
    path_len: usize,
    delimiter: u8,
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
        .{ .delimiter = delimiter },
    ) catch |err| return @intFromEnum(statusFor(err));

    return publish(gpa, parsed, out_frame);
}

/// Parses CSV text already in memory. The bytes are copied, so the caller may
/// free them as soon as this returns.
export fn eus_parse_csv(
    text_ptr: [*]const u8,
    text_len: usize,
    delimiter: u8,
    out_frame: *?*DataFrame,
) i32 {
    const gpa = allocator();
    const parsed = DataFrame.parse(gpa, text_ptr[0..text_len], .{ .delimiter = delimiter }) catch |err|
        return @intFromEnum(statusFor(err));

    return publish(gpa, parsed, out_frame);
}

/// Builds a frame from `column_count` caller-owned columns of `row_count`
/// values each; everything is copied, so the caller may free its buffers as
/// soon as this returns. For column `i`, `types[i]` is a `dtype.ColumnType`
/// tag, and `values[i]` points at `row_count` `i64`s or `f64`s — or, for a
/// string column, at `row_count + 1` offsets into `string_data[i]`, which is
/// `string_lens[i]` bytes long. `string_data` and `string_lens` are read only
/// for string columns.
export fn eus_frame_from_columns(
    column_count: usize,
    row_count: usize,
    name_ptrs: [*]const [*]const u8,
    name_lens: [*]const usize,
    types: [*]const u8,
    values: [*]const ?*const anyopaque,
    string_data: [*]const ?[*]const u8,
    string_lens: [*]const usize,
    out_frame: *?*DataFrame,
) i32 {
    const gpa = allocator();
    const names = gpa.alloc([]const u8, column_count) catch
        return @intFromEnum(Status.out_of_memory);
    defer gpa.free(names);
    const columns = gpa.alloc(frame.Column, column_count) catch
        return @intFromEnum(Status.out_of_memory);
    defer gpa.free(columns);

    for (names, columns, 0..) |*name, *column, i| {
        name.* = name_ptrs[i][0..name_lens[i]];
        column.* = borrowColumn(types[i], values[i], string_data[i], string_lens[i], row_count) orelse
            return @intFromEnum(Status.invalid_column_data);
    }

    const built = DataFrame.fromColumns(gpa, names, columns, row_count) catch |err|
        return @intFromEnum(statusFor(err));
    return publish(gpa, built, out_frame);
}

/// Views one caller-owned column, or null if the tag is unknown, a needed
/// pointer is missing, or string offsets do not describe the data buffer.
fn borrowColumn(
    tag: u8,
    values: ?*const anyopaque,
    data: ?[*]const u8,
    data_len: usize,
    row_count: usize,
) ?frame.Column {
    const column_type = std.enums.fromInt(dtype.ColumnType, tag) orelse return null;
    const pointer = values orelse return null;
    switch (column_type) {
        .int => return .{ .int = @as([*]const i64, @ptrCast(@alignCast(pointer)))[0..row_count] },
        .float => return .{ .float = @as([*]const f64, @ptrCast(@alignCast(pointer)))[0..row_count] },
        .string => {
            const offsets = @as([*]const usize, @ptrCast(@alignCast(pointer)))[0 .. row_count + 1];
            if (offsets[0] != 0 or offsets[row_count] != data_len) return null;
            for (offsets[0..row_count], offsets[1..]) |start, end| {
                if (start > end) return null;
            }
            const bytes: []const u8 = if (data_len == 0) "" else (data orelse return null)[0..data_len];
            return .{ .string = .{ .offsets = offsets, .data = bytes } };
        },
    }
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

/// Builds a new frame from the rows where `column <op> value` holds. `op` is
/// a `filter.Op` tag. The result is independent of `handle` and must be
/// released with `eus_frame_free`; on failure `out_frame` is left untouched.
fn filterInto(
    handle: *const DataFrame,
    index: usize,
    op: u8,
    value: filter.Value,
    out_frame: *?*DataFrame,
) i32 {
    if (index >= handle.columnCount()) return @intFromEnum(Status.column_out_of_range);
    const operator = std.enums.fromInt(filter.Op, op) orelse
        return @intFromEnum(Status.invalid_operator);

    const gpa = allocator();
    const kept = filter.filter(gpa, handle.*, index, operator, value) catch |err|
        return @intFromEnum(statusFor(err));

    return publish(gpa, kept, out_frame);
}

export fn eus_frame_filter_int(
    handle: *const DataFrame,
    index: usize,
    op: u8,
    value: i64,
    out_frame: *?*DataFrame,
) i32 {
    return filterInto(handle, index, op, .{ .int = value }, out_frame);
}

export fn eus_frame_filter_float(
    handle: *const DataFrame,
    index: usize,
    op: u8,
    value: f64,
    out_frame: *?*DataFrame,
) i32 {
    return filterInto(handle, index, op, .{ .float = value }, out_frame);
}

/// The value is borrowed only for the duration of the call.
export fn eus_frame_filter_string(
    handle: *const DataFrame,
    index: usize,
    op: u8,
    value_ptr: [*]const u8,
    value_len: usize,
    out_frame: *?*DataFrame,
) i32 {
    return filterInto(handle, index, op, .{ .string = value_ptr[0..value_len] }, out_frame);
}

/// Builds a new frame from `count` columns of `handle`, in the order given.
/// The result is independent of `handle` and must be released with
/// `eus_frame_free`; on failure `out_frame` is left untouched.
export fn eus_frame_select(
    handle: *const DataFrame,
    indices: [*]const usize,
    count: usize,
    out_frame: *?*DataFrame,
) i32 {
    for (indices[0..count]) |index| {
        if (index >= handle.columnCount()) return @intFromEnum(Status.column_out_of_range);
    }

    const gpa = allocator();
    const picked = handle.select(gpa, indices[0..count]) catch |err|
        return @intFromEnum(statusFor(err));

    return publish(gpa, picked, out_frame);
}

/// Builds a new frame with the rows sorted by column `index`, stably;
/// `descending` is 0 or 1. The result is independent of `handle` and must be
/// released with `eus_frame_free`; on failure `out_frame` is left untouched.
export fn eus_frame_sort(
    handle: *const DataFrame,
    index: usize,
    descending: u8,
    out_frame: *?*DataFrame,
) i32 {
    if (index >= handle.columnCount()) return @intFromEnum(Status.column_out_of_range);

    const gpa = allocator();
    const sorted = sort.sortBy(gpa, handle.*, index, descending != 0) catch |err|
        return @intFromEnum(statusFor(err));

    return publish(gpa, sorted, out_frame);
}

/// Groups by column `key` and reduces `spec_count` columns per group, one
/// output column per `(columns[i], funcs[i])` pair; `funcs` are `groupby.Func`
/// tags. The result is a new frame — see `groupby.groupBy` for its shape —
/// independent of `handle`, released with `eus_frame_free`. On failure
/// `out_frame` is left untouched.
export fn eus_frame_groupby(
    handle: *const DataFrame,
    key: usize,
    columns: [*]const usize,
    funcs: [*]const u8,
    spec_count: usize,
    out_frame: *?*DataFrame,
) i32 {
    if (key >= handle.columnCount()) return @intFromEnum(Status.column_out_of_range);

    const gpa = allocator();
    const specs = gpa.alloc(groupby.Spec, spec_count) catch
        return @intFromEnum(Status.out_of_memory);
    defer gpa.free(specs);

    for (specs, columns[0..spec_count], funcs[0..spec_count]) |*spec, column, func| {
        if (column >= handle.columnCount()) return @intFromEnum(Status.column_out_of_range);
        spec.* = .{
            .column = column,
            .func = std.enums.fromInt(groupby.Func, func) orelse
                return @intFromEnum(Status.invalid_aggregate),
        };
    }

    const grouped = groupby.groupBy(gpa, handle.*, key, specs) catch |err|
        return @intFromEnum(statusFor(err));

    return publish(gpa, grouped, out_frame);
}

/// Serialises a frame to CSV text separated by `delimiter`. On success
/// `out_ptr` / `out_len` describe a buffer the caller must release with
/// `eus_bytes_free`; on failure they are left untouched. The text is not
/// null-terminated.
export fn eus_frame_to_csv(
    handle: *const DataFrame,
    delimiter: u8,
    out_ptr: *?[*]u8,
    out_len: *usize,
) i32 {
    const text = write.toOwnedSlice(allocator(), handle.*, .{ .delimiter = delimiter }) catch |err|
        return @intFromEnum(statusFor(err));
    out_ptr.* = text.ptr;
    out_len.* = text.len;
    return @intFromEnum(Status.ok);
}

/// Releases a buffer from `eus_frame_to_csv`. Ignores null.
export fn eus_bytes_free(ptr: ?[*]u8, len: usize) void {
    const bytes = ptr orelse return;
    allocator().free(bytes[0..len]);
}

const testing = std.testing;

/// Mirrors what the Python layer does: parse, then read back through the ABI.
fn parseForTest(text: []const u8) !*DataFrame {
    var handle: ?*DataFrame = null;
    const code = eus_parse_csv(text.ptr, text.len, ',', &handle);
    try testing.expectEqual(@as(i32, 0), code);
    return handle.?;
}

test "a frame can be built from caller-owned columns" {
    const ints = [_]i64{ 7, 8 };
    const offsets = [_]usize{ 0, 2, 2 };
    const data = "hi";
    const names = [_][*]const u8{ "n", "s" };
    const name_lens = [_]usize{ 1, 1 };
    const types = [_]u8{ @intFromEnum(dtype.ColumnType.int), @intFromEnum(dtype.ColumnType.string) };
    const values = [_]?*const anyopaque{ &ints, &offsets };
    const string_data = [_]?[*]const u8{ null, data };
    const string_lens = [_]usize{ 0, data.len };

    var handle: ?*DataFrame = null;
    try testing.expectEqual(@as(i32, 0), eus_frame_from_columns(
        2,
        2,
        &names,
        &name_lens,
        &types,
        &values,
        &string_data,
        &string_lens,
        &handle,
    ));
    defer eus_frame_free(handle);

    try testing.expectEqualSlices(i64, &.{ 7, 8 }, eus_frame_ints(handle.?, 0).?[0..2]);
    try testing.expectEqualSlices(usize, &.{ 0, 2, 2 }, eus_frame_string_offsets(handle.?, 1).?[0..3]);
}

test "inconsistent columns are refused" {
    const offsets = [_]usize{ 0, 3, 2 };
    const names = [_][*]const u8{"s"};
    const name_lens = [_]usize{1};
    const string_tag = [_]u8{@intFromEnum(dtype.ColumnType.string)};
    const values = [_]?*const anyopaque{&offsets};
    const string_data = [_]?[*]const u8{"abc"};

    var handle: ?*DataFrame = null;
    // Offsets that run backwards, then a last offset that misses the data length.
    try testing.expectEqual(@intFromEnum(Status.invalid_column_data), eus_frame_from_columns(
        1,
        2,
        &names,
        &name_lens,
        &string_tag,
        &values,
        &string_data,
        &[_]usize{2},
        &handle,
    ));
    try testing.expectEqual(@intFromEnum(Status.invalid_column_data), eus_frame_from_columns(
        1,
        2,
        &names,
        &name_lens,
        &string_tag,
        &values,
        &string_data,
        &[_]usize{3},
        &handle,
    ));
    // An unknown type tag.
    try testing.expectEqual(@intFromEnum(Status.invalid_column_data), eus_frame_from_columns(
        1,
        2,
        &names,
        &name_lens,
        &[_]u8{9},
        &values,
        &string_data,
        &[_]usize{2},
        &handle,
    ));
    try testing.expect(handle == null);
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

    const missing_header = eus_parse_csv("", 0, ',', &handle);
    try testing.expectEqual(@intFromEnum(Status.missing_header), missing_header);

    const bad = "a,b\n1,2,3\n";
    const ragged = eus_parse_csv(bad.ptr, bad.len, ',', &handle);

    const quote = eus_parse_csv(bad.ptr, bad.len, '"', &handle);
    try testing.expectEqual(@intFromEnum(Status.invalid_delimiter), quote);
    try testing.expectEqual(@intFromEnum(Status.inconsistent_field_count), ragged);

    // The out-parameter must be left alone on failure.
    try testing.expect(handle == null);
}

test "a missing file reports file_not_found" {
    var handle: ?*DataFrame = null;
    const path = "definitely-not-here.csv";
    const code = eus_read_csv(path.ptr, path.len, ',', &handle);

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

test "filters cross the boundary as new, independent frames" {
    const df = try parseForTest("name,age\nada,36\ngrace,45\njohn,29\n");

    var handle: ?*DataFrame = null;
    const gt: u8 = @intFromEnum(filter.Op.gt);
    try testing.expectEqual(@as(i32, 0), eus_frame_filter_int(df, 1, gt, 30, &handle));
    const adults = handle.?;
    defer eus_frame_free(adults);

    // Free the source first: the result must not borrow from it.
    eus_frame_free(df);

    try testing.expectEqual(@as(usize, 2), eus_frame_rows(adults));
    try testing.expectEqualSlices(i64, &.{ 36, 45 }, eus_frame_ints(adults, 1).?[0..2]);

    var len: usize = 0;
    const name = eus_frame_column_name(adults, 0, &len).?;
    try testing.expectEqualStrings("name", name[0..len]);
}

test "each filter entry point takes its own value type" {
    const df = try parseForTest("n,x,s\n1,0.5,ada\n2,1.5,grace\n");
    defer eus_frame_free(df);

    const eq: u8 = @intFromEnum(filter.Op.eq);
    var handle: ?*DataFrame = null;

    try testing.expectEqual(@as(i32, 0), eus_frame_filter_float(df, 1, eq, 1.5, &handle));
    eus_frame_free(handle);
    handle = null;

    try testing.expectEqual(@as(i32, 0), eus_frame_filter_string(df, 2, eq, "ada", 3, &handle));
    try testing.expectEqual(@as(usize, 1), eus_frame_rows(handle.?));
    eus_frame_free(handle);
}

test "filter failures come back as status codes" {
    const df = try parseForTest("n,s\n1,ada\n");
    defer eus_frame_free(df);

    var handle: ?*DataFrame = null;
    const eq: u8 = @intFromEnum(filter.Op.eq);

    try testing.expectEqual(
        @intFromEnum(Status.column_out_of_range),
        eus_frame_filter_int(df, 9, eq, 1, &handle),
    );
    try testing.expectEqual(
        @intFromEnum(Status.invalid_operator),
        eus_frame_filter_int(df, 0, 42, 1, &handle),
    );
    try testing.expectEqual(
        @intFromEnum(Status.type_mismatch),
        eus_frame_filter_int(df, 1, eq, 1, &handle),
    );
    try testing.expectEqual(
        @intFromEnum(Status.type_mismatch),
        eus_frame_filter_string(df, 0, eq, "1", 1, &handle),
    );
    try testing.expect(handle == null);
}

test "select crosses the boundary as a new, independent frame" {
    const df = try parseForTest("a,b,c\n1,x,0.5\n");

    var handle: ?*DataFrame = null;
    const indices = [_]usize{ 2, 0 };
    try testing.expectEqual(@as(i32, 0), eus_frame_select(df, &indices, indices.len, &handle));
    const picked = handle.?;
    defer eus_frame_free(picked);
    eus_frame_free(df);

    try testing.expectEqual(@as(usize, 2), eus_frame_columns(picked));
    try testing.expectEqualSlices(f64, &.{0.5}, eus_frame_floats(picked, 0).?[0..1]);
    try testing.expectEqualSlices(i64, &.{1}, eus_frame_ints(picked, 1).?[0..1]);
}

test "select refuses an out-of-range column" {
    const df = try parseForTest("a\n1\n");
    defer eus_frame_free(df);

    var handle: ?*DataFrame = null;
    try testing.expectEqual(
        @intFromEnum(Status.column_out_of_range),
        eus_frame_select(df, &[_]usize{ 0, 1 }, 2, &handle),
    );
    try testing.expect(handle == null);
}

test "sort crosses the boundary as a new, independent frame" {
    const df = try parseForTest("n,s\n2,b\n1,a\n3,c\n");

    var handle: ?*DataFrame = null;
    try testing.expectEqual(@as(i32, 0), eus_frame_sort(df, 0, 1, &handle));
    const sorted = handle.?;
    defer eus_frame_free(sorted);
    eus_frame_free(df);

    try testing.expectEqualSlices(i64, &.{ 3, 2, 1 }, eus_frame_ints(sorted, 0).?[0..3]);

    try testing.expectEqual(
        @intFromEnum(Status.column_out_of_range),
        eus_frame_sort(sorted, 5, 0, &handle),
    );
}

test "groupby crosses the boundary as a new, independent frame" {
    const df = try parseForTest("city,n\nparis,1\nrome,2\nparis,3\n");

    var handle: ?*DataFrame = null;
    const columns = [_]usize{ 1, 1 };
    const funcs = [_]u8{ @intFromEnum(groupby.Func.sum), @intFromEnum(groupby.Func.count) };
    try testing.expectEqual(
        @as(i32, 0),
        eus_frame_groupby(df, 0, &columns, &funcs, columns.len, &handle),
    );
    const grouped = handle.?;
    defer eus_frame_free(grouped);

    eus_frame_free(df);

    try testing.expectEqual(@as(usize, 2), eus_frame_rows(grouped));
    try testing.expectEqual(@as(usize, 3), eus_frame_columns(grouped));
    try testing.expectEqualSlices(i64, &.{ 4, 2 }, eus_frame_ints(grouped, 1).?[0..2]);
    try testing.expectEqualSlices(i64, &.{ 2, 1 }, eus_frame_ints(grouped, 2).?[0..2]);

    var len: usize = 0;
    const name = eus_frame_column_name(grouped, 2, &len).?;
    try testing.expectEqualStrings("count", name[0..len]);
}

test "groupby with no specs is allowed and the pointers are never read" {
    const df = try parseForTest("k\na\nb\na\n");
    defer eus_frame_free(df);

    var handle: ?*DataFrame = null;
    try testing.expectEqual(@as(i32, 0), eus_frame_groupby(df, 0, undefined, undefined, 0, &handle));
    defer eus_frame_free(handle);
    try testing.expectEqual(@as(usize, 2), eus_frame_rows(handle.?));
    try testing.expectEqual(@as(usize, 1), eus_frame_columns(handle.?));
}

test "groupby failures come back as status codes" {
    const df = try parseForTest("k,s\na,x\n");
    defer eus_frame_free(df);

    var handle: ?*DataFrame = null;
    const sum: u8 = @intFromEnum(groupby.Func.sum);

    try testing.expectEqual(
        @intFromEnum(Status.column_out_of_range),
        eus_frame_groupby(df, 9, &[_]usize{0}, &[_]u8{sum}, 1, &handle),
    );
    try testing.expectEqual(
        @intFromEnum(Status.column_out_of_range),
        eus_frame_groupby(df, 0, &[_]usize{9}, &[_]u8{sum}, 1, &handle),
    );
    try testing.expectEqual(
        @intFromEnum(Status.invalid_aggregate),
        eus_frame_groupby(df, 0, &[_]usize{1}, &[_]u8{42}, 1, &handle),
    );
    try testing.expectEqual(
        @intFromEnum(Status.not_numeric),
        eus_frame_groupby(df, 0, &[_]usize{1}, &[_]u8{sum}, 1, &handle),
    );
    try testing.expect(handle == null);
}

test "aggregate tags are the numbers Python expects" {
    // euspinolia/__init__.py hardcodes these in `_AGGREGATES`.
    try testing.expectEqual(@as(u8, 0), @intFromEnum(groupby.Func.sum));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(groupby.Func.mean));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(groupby.Func.min));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(groupby.Func.max));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(groupby.Func.count));
}

test "a frame crosses back out as CSV text" {
    const df = try parseForTest("id,name\n1,\"a,b\"\n2,grace\n");
    defer eus_frame_free(df);

    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    try testing.expectEqual(@as(i32, 0), eus_frame_to_csv(df, ',', &ptr, &len));
    defer eus_bytes_free(ptr, len);

    try testing.expectEqualStrings("id,name\n1,\"a,b\"\n2,grace\n", ptr.?[0..len]);
}

test "the delimiter crosses the boundary both ways" {
    var handle: ?*DataFrame = null;
    const text = "id\tname\n1\ta,b\n";
    try testing.expectEqual(@as(i32, 0), eus_parse_csv(text.ptr, text.len, '\t', &handle));
    defer eus_frame_free(handle);
    try testing.expectEqual(@as(usize, 2), eus_frame_columns(handle.?));

    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    try testing.expectEqual(@as(i32, 0), eus_frame_to_csv(handle.?, ';', &ptr, &len));
    defer eus_bytes_free(ptr, len);
    try testing.expectEqualStrings("id;name\n1;a,b\n", ptr.?[0..len]);

    try testing.expectEqual(
        @intFromEnum(Status.invalid_delimiter),
        eus_frame_to_csv(handle.?, '\n', &ptr, &len),
    );
}

test "freeing null bytes is a no-op" {
    eus_bytes_free(null, 0);
}

test "operator tags are the numbers Python expects" {
    // euspinolia/__init__.py hardcodes these in `_OPERATORS`.
    try testing.expectEqual(@as(u8, 0), @intFromEnum(filter.Op.eq));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(filter.Op.ne));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(filter.Op.lt));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(filter.Op.le));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(filter.Op.gt));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(filter.Op.ge));
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
