const std = @import("std");
const csv = @import("csv.zig");
const dtype = @import("dtype.zig");

const Allocator = std.mem.Allocator;

pub const ConversionError = error{
    /// A cell did not parse as the type inferred for its column. Inference
    /// should rule this out, so it signals a bug rather than bad input.
    InvalidNumber,
};

/// Variable-length text in two buffers, the way Arrow lays it out: all bytes
/// packed back to back, plus `row_count + 1` offsets into them. Value `i` is
/// `data[offsets[i]..offsets[i + 1]]`, so the last offset is the total length
/// and an empty string costs nothing but a repeated offset.
pub const StringColumn = struct {
    offsets: []const usize,
    data: []const u8,

    pub fn len(self: StringColumn) usize {
        return self.offsets.len - 1;
    }

    pub fn get(self: StringColumn, row: usize) []const u8 {
        return self.data[self.offsets[row]..self.offsets[row + 1]];
    }
};

/// One column's values, laid out per type. Fixed-width types get a flat array;
/// strings get the offset+data pair above.
pub const Column = union(dtype.ColumnType) {
    int: []const i64,
    float: []const f64,
    string: StringColumn,

    pub fn len(self: Column) usize {
        return switch (self) {
            .int => |values| values.len,
            .float => |values| values.len,
            .string => |values| values.len(),
        };
    }

    pub fn columnType(self: Column) dtype.ColumnType {
        return self;
    }
};

/// A table held column by column (struct of arrays), owning all of its data.
///
/// The layout is what makes the later phases cheap: a filter or an aggregate
/// walks one contiguous typed array instead of hopping between per-row
/// allocations, and Python can read a column as a flat buffer without copying.
pub const DataFrame = struct {
    arena: std.heap.ArenaAllocator,
    names: []const []const u8,
    columns: []const Column,
    row_count: usize,

    /// Converts a parsed row-major table, inferring one type per column. The
    /// frame copies what it keeps, so `table` may be freed right after.
    pub fn fromTable(gpa: Allocator, table: csv.Table) !DataFrame {
        const types = try table.inferTypes(gpa);
        defer gpa.free(types);
        return fromTableWithTypes(gpa, table, types);
    }

    /// Same, with the column types chosen by the caller. A column forced to
    /// `.string` always succeeds; a narrower choice can fail with
    /// `InvalidNumber`.
    pub fn fromTableWithTypes(
        gpa: Allocator,
        table: csv.Table,
        types: []const dtype.ColumnType,
    ) !DataFrame {
        std.debug.assert(types.len == table.columnCount());

        var frame: DataFrame = .{
            .arena = .init(gpa),
            .names = &.{},
            .columns = &.{},
            .row_count = table.rowCount(),
        };
        errdefer frame.arena.deinit();
        const arena = frame.arena.allocator();

        const names = try arena.alloc([]const u8, table.columnCount());
        for (names, table.headers) |*name, header| name.* = try arena.dupe(u8, header);
        frame.names = names;

        const columns = try arena.alloc(Column, table.columnCount());
        for (columns, types, 0..) |*slot, column_type, index| {
            slot.* = switch (column_type) {
                .int => .{ .int = try buildInts(arena, table, index) },
                .float => .{ .float = try buildFloats(arena, table, index) },
                .string => .{ .string = try buildStrings(arena, table, index) },
            };
        }
        frame.columns = columns;

        return frame;
    }

    /// Parses an in-memory buffer straight into columnar form. The row-major
    /// table is a staging step and is released before returning.
    pub fn parse(gpa: Allocator, input: []const u8, options: csv.Options) !DataFrame {
        var table = try csv.Table.parse(gpa, input, options);
        defer table.deinit();
        return fromTable(gpa, table);
    }

    /// Reads a CSV file and returns it in columnar form.
    ///
    /// Pass `std.Io.Dir.cwd()` to resolve `path` against the working directory.
    pub fn parseFile(
        gpa: Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
        limit: std.Io.Limit,
        options: csv.Options,
    ) !DataFrame {
        var table = try csv.Table.parseFile(gpa, io, dir, path, limit, options);
        defer table.deinit();
        return fromTable(gpa, table);
    }

    /// A new frame holding the rows where `mask` is true, in their original
    /// order. The result owns its own copies, so either frame may be freed
    /// without affecting the other.
    ///
    /// This is the gather step behind `filter`; the column types are kept as
    /// they are, even when nothing survives.
    pub fn take(self: DataFrame, gpa: Allocator, mask: []const bool) !DataFrame {
        std.debug.assert(mask.len == self.row_count);

        var kept: usize = 0;
        for (mask) |keep| kept += @intFromBool(keep);

        var result: DataFrame = .{
            .arena = .init(gpa),
            .names = &.{},
            .columns = &.{},
            .row_count = kept,
        };
        errdefer result.arena.deinit();
        const arena = result.arena.allocator();

        const names = try arena.alloc([]const u8, self.columns.len);
        for (names, self.names) |*name, source| name.* = try arena.dupe(u8, source);
        result.names = names;

        const columns = try arena.alloc(Column, self.columns.len);
        for (columns, self.columns) |*slot, source| {
            slot.* = switch (source) {
                .int => |values| .{ .int = try gather(i64, arena, values, mask, kept) },
                .float => |values| .{ .float = try gather(f64, arena, values, mask, kept) },
                .string => |values| .{ .string = try gatherStrings(arena, values, mask, kept) },
            };
        }
        result.columns = columns;

        return result;
    }

    pub fn deinit(self: *DataFrame) void {
        self.arena.deinit();
    }

    pub fn columnCount(self: DataFrame) usize {
        return self.columns.len;
    }

    pub fn rowCount(self: DataFrame) usize {
        return self.row_count;
    }

    pub fn columnIndex(self: DataFrame, name: []const u8) ?usize {
        for (self.names, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, name)) return i;
        }
        return null;
    }

    pub fn column(self: DataFrame, index: usize) Column {
        return self.columns[index];
    }

    pub fn columnByName(self: DataFrame, name: []const u8) ?Column {
        return self.column(self.columnIndex(name) orelse return null);
    }

    pub fn columnType(self: DataFrame, index: usize) dtype.ColumnType {
        return self.columns[index].columnType();
    }

    /// The column's values as `i64`, or null if it holds something else.
    pub fn ints(self: DataFrame, index: usize) ?[]const i64 {
        return switch (self.columns[index]) {
            .int => |values| values,
            else => null,
        };
    }

    /// The column's values as `f64`, or null if it holds something else.
    pub fn floats(self: DataFrame, index: usize) ?[]const f64 {
        return switch (self.columns[index]) {
            .float => |values| values,
            else => null,
        };
    }

    /// The column's text buffers, or null if it holds numbers.
    pub fn strings(self: DataFrame, index: usize) ?StringColumn {
        return switch (self.columns[index]) {
            .string => |values| values,
            else => null,
        };
    }
};

fn buildInts(arena: Allocator, table: csv.Table, index: usize) ![]const i64 {
    const out = try arena.alloc(i64, table.rowCount());
    for (out, table.rows) |*slot, row| {
        slot.* = std.fmt.parseInt(i64, row[index], 10) catch return ConversionError.InvalidNumber;
    }
    return out;
}

fn buildFloats(arena: Allocator, table: csv.Table, index: usize) ![]const f64 {
    const out = try arena.alloc(f64, table.rowCount());
    for (out, table.rows) |*slot, row| {
        slot.* = std.fmt.parseFloat(f64, row[index]) catch return ConversionError.InvalidNumber;
    }
    return out;
}

fn buildStrings(arena: Allocator, table: csv.Table, index: usize) !StringColumn {
    var total: usize = 0;
    for (table.rows) |row| total += row[index].len;

    const data = try arena.alloc(u8, total);
    const offsets = try arena.alloc(usize, table.rowCount() + 1);

    var at: usize = 0;
    for (table.rows, 0..) |row, i| {
        const text = row[index];
        offsets[i] = at;
        @memcpy(data[at..][0..text.len], text);
        at += text.len;
    }
    offsets[table.rowCount()] = at;

    return .{ .offsets = offsets, .data = data };
}

fn gather(
    comptime T: type,
    arena: Allocator,
    values: []const T,
    mask: []const bool,
    kept: usize,
) ![]const T {
    // One slot of slack so the unconditional store is always in bounds:
    // writing every value and advancing only on `keep` avoids a branch the
    // CPU cannot predict when the mask is random.
    const out = try arena.alloc(T, kept + 1);
    var at: usize = 0;
    for (values, mask) |value, keep| {
        out[at] = value;
        at += @intFromBool(keep);
    }
    return out[0..kept];
}

fn gatherStrings(
    arena: Allocator,
    column: StringColumn,
    mask: []const bool,
    kept: usize,
) !StringColumn {
    // Same branchless shape as `gather`: copy every row, advance only on
    // `keep`. The slack is the longest value, so a dropped row's copy always
    // lands inside the buffer (and is overwritten by the next kept one).
    var total: usize = 0;
    var longest: usize = 0;
    for (mask, 0..) |keep, i| {
        const len = column.get(i).len;
        total += len * @intFromBool(keep);
        longest = @max(longest, len);
    }

    const data = try arena.alloc(u8, total + longest);
    const offsets = try arena.alloc(usize, kept + 1);

    var row: usize = 0;
    var at: usize = 0;
    for (mask, 0..) |keep, i| {
        const text = column.get(i);
        offsets[row] = at;
        @memcpy(data[at..][0..text.len], text);
        at += text.len * @intFromBool(keep);
        row += @intFromBool(keep);
    }
    offsets[kept] = at;

    return .{ .offsets = offsets, .data = data[0..total] };
}

const testing = std.testing;

test "builds one typed column per header" {
    var frame = try DataFrame.parse(testing.allocator, "id,ratio,name\n1,0.5,ada\n2,1.25,grace\n", .{});
    defer frame.deinit();

    try testing.expectEqual(@as(usize, 3), frame.columnCount());
    try testing.expectEqual(@as(usize, 2), frame.rowCount());

    try testing.expectEqual(.int, frame.columnType(0));
    try testing.expectEqual(.float, frame.columnType(1));
    try testing.expectEqual(.string, frame.columnType(2));

    try testing.expectEqualSlices(i64, &.{ 1, 2 }, frame.ints(0).?);
    try testing.expectEqualSlices(f64, &.{ 0.5, 1.25 }, frame.floats(1).?);

    const names = frame.strings(2).?;
    try testing.expectEqualStrings("ada", names.get(0));
    try testing.expectEqualStrings("grace", names.get(1));
}

test "column names survive the conversion" {
    var frame = try DataFrame.parse(testing.allocator, "id,name\n1,ada\n", .{});
    defer frame.deinit();

    try testing.expectEqualStrings("id", frame.names[0]);
    try testing.expectEqual(@as(?usize, 1), frame.columnIndex("name"));
    try testing.expectEqual(@as(?usize, null), frame.columnIndex("missing"));
    try testing.expect(frame.columnByName("id") != null);
    try testing.expect(frame.columnByName("missing") == null);
}

test "typed accessors reject the wrong type" {
    var frame = try DataFrame.parse(testing.allocator, "n,s\n1,ada\n", .{});
    defer frame.deinit();

    try testing.expect(frame.floats(0) == null);
    try testing.expect(frame.strings(0) == null);
    try testing.expect(frame.ints(1) == null);
}

test "an int column with one float becomes a float column" {
    var frame = try DataFrame.parse(testing.allocator, "n\n1\n2\n3.5\n", .{});
    defer frame.deinit();

    try testing.expectEqualSlices(f64, &.{ 1, 2, 3.5 }, frame.floats(0).?);
}

test "string offsets are contiguous and cover the data buffer" {
    // The second column keeps the middle record from looking like a blank
    // line, which the parser would skip.
    var frame = try DataFrame.parse(testing.allocator, "s,n\nada,1\n,2\nlovelace,3\n", .{});
    defer frame.deinit();

    const column = frame.strings(0).?;
    try testing.expectEqual(@as(usize, 3), column.len());
    try testing.expectEqualSlices(usize, &.{ 0, 3, 3, 11 }, column.offsets);
    try testing.expectEqualStrings("adalovelace", column.data);
    try testing.expectEqualStrings("", column.get(1));
}

test "a header-only file yields empty columns" {
    var frame = try DataFrame.parse(testing.allocator, "a,b\n", .{});
    defer frame.deinit();

    try testing.expectEqual(@as(usize, 2), frame.columnCount());
    try testing.expectEqual(@as(usize, 0), frame.rowCount());
    // With no values to inspect, inference leaves both columns textual.
    try testing.expectEqual(.string, frame.columnType(0));
    try testing.expectEqual(@as(usize, 0), frame.strings(0).?.len());
}

test "the frame outlives the table it came from" {
    var table = try csv.Table.parse(testing.allocator, "id,name\n7,ada\n", .{});
    var frame = try DataFrame.fromTable(testing.allocator, table);
    defer frame.deinit();
    table.deinit();

    try testing.expectEqualSlices(i64, &.{7}, frame.ints(0).?);
    try testing.expectEqualStrings("name", frame.names[1]);
    try testing.expectEqualStrings("ada", frame.strings(1).?.get(0));
}

test "caller-chosen types override inference" {
    var table = try csv.Table.parse(testing.allocator, "n\n1\n2\n", .{});
    defer table.deinit();

    var as_float = try DataFrame.fromTableWithTypes(testing.allocator, table, &.{.float});
    defer as_float.deinit();
    try testing.expectEqualSlices(f64, &.{ 1, 2 }, as_float.floats(0).?);

    var as_text = try DataFrame.fromTableWithTypes(testing.allocator, table, &.{.string});
    defer as_text.deinit();
    try testing.expectEqualStrings("2", as_text.strings(0).?.get(1));
}

test "a type the data cannot hold is an error" {
    var table = try csv.Table.parse(testing.allocator, "s\nada\n", .{});
    defer table.deinit();

    try testing.expectError(
        ConversionError.InvalidNumber,
        DataFrame.fromTableWithTypes(testing.allocator, table, &.{.int}),
    );
}

test "parses a file into columns" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "people.csv",
        .data = "id,name\n1,ada\n2,grace\n",
    });

    var frame = try DataFrame.parseFile(testing.allocator, testing.io, tmp.dir, "people.csv", .unlimited, .{});
    defer frame.deinit();

    try testing.expectEqualSlices(i64, &.{ 1, 2 }, frame.ints(0).?);
    try testing.expectEqualStrings("grace", frame.strings(1).?.get(1));
}

test "converts a medium file" {
    const gpa = testing.allocator;
    const row_count = 5000;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "id,name,score\n");

    var buf: [64]u8 = undefined;
    for (0..row_count) |i| {
        try text.appendSlice(gpa, try std.fmt.bufPrint(&buf, "{d},user{d},{d}.5\n", .{ i, i, i }));
    }

    var frame = try DataFrame.parse(gpa, text.items, .{});
    defer frame.deinit();

    try testing.expectEqual(@as(usize, row_count), frame.rowCount());
    try testing.expectEqual(@as(i64, row_count - 1), frame.ints(0).?[row_count - 1]);
    try testing.expectEqual(@as(f64, row_count - 1) + 0.5, frame.floats(2).?[row_count - 1]);
    try testing.expectEqualStrings("user4999", frame.strings(1).?.get(row_count - 1));
}

test "take keeps the masked rows in order, across every column type" {
    var df = try DataFrame.parse(testing.allocator, "n,x,s\n1,0.5,ada\n2,1.5,grace\n3,2.5,\n4,3.5,mary\n", .{});
    defer df.deinit();

    var kept = try df.take(testing.allocator, &.{ true, false, true, true });
    defer kept.deinit();

    try testing.expectEqual(@as(usize, 3), kept.rowCount());
    try testing.expectEqual(@as(usize, 3), kept.columnCount());
    try testing.expectEqualStrings("s", kept.names[2]);

    try testing.expectEqualSlices(i64, &.{ 1, 3, 4 }, kept.ints(0).?);
    try testing.expectEqualSlices(f64, &.{ 0.5, 2.5, 3.5 }, kept.floats(1).?);

    const names = kept.strings(2).?;
    try testing.expectEqualSlices(usize, &.{ 0, 3, 3, 7 }, names.offsets);
    try testing.expectEqualStrings("adamary", names.data);
    try testing.expectEqualStrings("", names.get(1));
}

test "take drops a trailing string longer than everything kept" {
    var df = try DataFrame.parse(testing.allocator, "s\nab\nmuch longer\n", .{});
    defer df.deinit();

    var kept = try df.take(testing.allocator, &.{ true, false });
    defer kept.deinit();

    const names = kept.strings(0).?;
    try testing.expectEqualSlices(usize, &.{ 0, 2 }, names.offsets);
    try testing.expectEqualStrings("ab", names.data);
}

test "take with nothing kept preserves the column types" {
    var df = try DataFrame.parse(testing.allocator, "n,s\n1,ada\n", .{});
    defer df.deinit();

    var empty = try df.take(testing.allocator, &.{false});
    defer empty.deinit();

    try testing.expectEqual(@as(usize, 0), empty.rowCount());
    // Unlike a header-only parse, an emptied frame remembers what it held.
    try testing.expectEqual(.int, empty.columnType(0));
    try testing.expectEqual(@as(usize, 0), empty.ints(0).?.len);
    try testing.expectEqualSlices(usize, &.{0}, empty.strings(1).?.offsets);
}

test "the taken frame outlives its source" {
    var df = try DataFrame.parse(testing.allocator, "n,s\n1,ada\n2,grace\n", .{});
    var kept = try df.take(testing.allocator, &.{ false, true });
    defer kept.deinit();
    df.deinit();

    try testing.expectEqualSlices(i64, &.{2}, kept.ints(0).?);
    try testing.expectEqualStrings("grace", kept.strings(1).?.get(0));
    try testing.expectEqualStrings("n", kept.names[0]);
}
