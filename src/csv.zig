const std = @import("std");
const dtype = @import("dtype.zig");

const Allocator = std.mem.Allocator;

pub const ParseError = error{
    UnterminatedQuote,
    UnexpectedCharacterAfterQuote,
    InconsistentFieldCount,
    MissingHeader,
};

pub const Field = struct {
    text: []const u8,
    last_in_record: bool,
};

/// Field-level scanner over an in-memory CSV buffer.
///
/// Supported subset of RFC 4180: quoted fields may contain the delimiter,
/// newlines and `""` escapes; both `\n` and `\r\n` end a record; blank lines
/// are skipped. Whitespace is never trimmed.
pub const Scanner = struct {
    input: []const u8,
    pos: usize = 0,
    delimiter: u8 = ',',
    at_record_start: bool = true,

    pub fn init(input: []const u8) Scanner {
        return .{ .input = input };
    }

    /// Returns the next field, or null once the input is exhausted.
    ///
    /// Field text borrows from `input`; only fields carrying `""` escapes are
    /// copied into `arena`.
    pub fn next(self: *Scanner, arena: Allocator) !?Field {
        if (self.at_record_start) self.skipBlankLines();

        if (self.pos >= self.input.len) {
            // A trailing delimiter still owes us one empty field.
            if (self.at_record_start) return null;
            self.at_record_start = true;
            return Field{ .text = "", .last_in_record = true };
        }

        if (self.input[self.pos] == '"') return try self.quotedField(arena);
        return self.plainField();
    }

    fn skipBlankLines(self: *Scanner) void {
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '\n') {
                self.pos += 1;
            } else if (self.input[self.pos] == '\r' and
                self.pos + 1 < self.input.len and
                self.input[self.pos + 1] == '\n')
            {
                self.pos += 2;
            } else break;
        }
    }

    fn plainField(self: *Scanner) Field {
        const start = self.pos;
        while (self.pos < self.input.len) : (self.pos += 1) {
            const c = self.input[self.pos];
            if (c == self.delimiter or c == '\n') break;
        }

        var end = self.pos;
        if (self.pos < self.input.len and
            self.input[self.pos] == '\n' and
            end > start and
            self.input[end - 1] == '\r') end -= 1;

        return self.finish(self.input[start..end]);
    }

    fn quotedField(self: *Scanner, arena: Allocator) !Field {
        self.pos += 1;
        const start = self.pos;

        var escapes: usize = 0;
        while (true) {
            if (self.pos >= self.input.len) return ParseError.UnterminatedQuote;
            if (self.input[self.pos] != '"') {
                self.pos += 1;
                continue;
            }
            if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '"') {
                escapes += 1;
                self.pos += 2;
                continue;
            }
            break;
        }

        const raw = self.input[start..self.pos];
        self.pos += 1;

        if (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '\r' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\n') {
                self.pos += 1;
            } else if (c != self.delimiter and c != '\n') {
                return ParseError.UnexpectedCharacterAfterQuote;
            }
        }

        const text = if (escapes == 0) raw else try unescape(arena, raw, escapes);
        return self.finish(text);
    }

    fn finish(self: *Scanner, text: []const u8) Field {
        var last = true;
        if (self.pos < self.input.len) {
            if (self.input[self.pos] == self.delimiter) last = false;
            self.pos += 1;
        }
        self.at_record_start = last;
        return .{ .text = text, .last_in_record = last };
    }
};

fn unescape(arena: Allocator, raw: []const u8, escapes: usize) ![]const u8 {
    const out = try arena.alloc(u8, raw.len - escapes);
    var read: usize = 0;
    var write: usize = 0;
    while (read < raw.len) : (write += 1) {
        out[write] = raw[read];
        read += if (raw[read] == '"') 2 else 1;
    }
    return out;
}

/// A parsed CSV file held row-major, owning all of its text.
///
/// Row-major is a deliberate stopgap: it keeps the parser honest and testable
/// on its own. Columnar storage replaces `rows` in the next phase.
pub const Table = struct {
    arena: std.heap.ArenaAllocator,
    headers: [][]const u8,
    rows: [][][]const u8,

    /// Parses an in-memory buffer. The table copies what it needs, so the
    /// caller may free `input` immediately.
    pub fn parse(gpa: Allocator, input: []const u8) !Table {
        var table = empty(gpa);
        errdefer table.arena.deinit();

        const owned = try table.arena.allocator().dupe(u8, input);
        try table.fill(owned);
        return table;
    }

    /// Reads the whole file into memory, then parses it. Fine for files that
    /// comfortably fit in RAM; streaming is a later concern.
    ///
    /// Pass `std.Io.Dir.cwd()` to resolve `path` against the working directory.
    pub fn parseFile(
        gpa: Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
        limit: std.Io.Limit,
    ) !Table {
        var table = empty(gpa);
        errdefer table.arena.deinit();

        // Read straight into the table's arena to avoid a second full copy.
        const bytes = try dir.readFileAlloc(io, path, table.arena.allocator(), limit);
        try table.fill(bytes);
        return table;
    }

    pub fn deinit(self: *Table) void {
        self.arena.deinit();
    }

    pub fn columnCount(self: Table) usize {
        return self.headers.len;
    }

    pub fn rowCount(self: Table) usize {
        return self.rows.len;
    }

    pub fn get(self: Table, row: usize, column: usize) []const u8 {
        return self.rows[row][column];
    }

    pub fn columnIndex(self: Table, name: []const u8) ?usize {
        for (self.headers, 0..) |header, i| {
            if (std.mem.eql(u8, header, name)) return i;
        }
        return null;
    }

    /// Infers one type per column. Caller owns the returned slice.
    pub fn inferTypes(self: Table, gpa: Allocator) ![]dtype.ColumnType {
        const types = try gpa.alloc(dtype.ColumnType, self.headers.len);
        errdefer gpa.free(types);

        for (types, 0..) |*slot, column| {
            var result: dtype.ColumnType = if (self.rows.len == 0) .string else .int;
            for (self.rows) |row| {
                result = dtype.widen(result, dtype.inferValue(row[column]));
                if (result == .string) break;
            }
            slot.* = result;
        }
        return types;
    }

    fn empty(gpa: Allocator) Table {
        return .{
            .arena = .init(gpa),
            .headers = &.{},
            .rows = &.{},
        };
    }

    /// `owned` must already live in this table's arena.
    fn fill(self: *Table, owned: []const u8) !void {
        const arena = self.arena.allocator();
        var scanner = Scanner.init(owned);

        var record: std.ArrayList([]const u8) = .empty;
        if (!try readRecord(&scanner, arena, &record)) return ParseError.MissingHeader;
        self.headers = try arena.dupe([]const u8, record.items);

        var rows: std.ArrayList([][]const u8) = .empty;
        while (try readRecord(&scanner, arena, &record)) {
            if (record.items.len != self.headers.len) return ParseError.InconsistentFieldCount;
            try rows.append(arena, try arena.dupe([]const u8, record.items));
        }
        self.rows = try rows.toOwnedSlice(arena);
    }
};

fn readRecord(scanner: *Scanner, arena: Allocator, out: *std.ArrayList([]const u8)) !bool {
    out.clearRetainingCapacity();
    while (try scanner.next(arena)) |field| {
        try out.append(arena, field.text);
        if (field.last_in_record) return true;
    }
    return false;
}

const testing = std.testing;

fn expectRow(table: Table, row: usize, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, table.columnCount());
    for (expected, 0..) |cell, column| {
        try testing.expectEqualStrings(cell, table.get(row, column));
    }
}

test "parses a minimal table" {
    var table = try Table.parse(testing.allocator, "a,b,c\n1,2,3\n4,5,6\n");
    defer table.deinit();

    try testing.expectEqual(@as(usize, 3), table.columnCount());
    try testing.expectEqual(@as(usize, 2), table.rowCount());
    try expectRow(table, 0, &.{ "1", "2", "3" });
    try expectRow(table, 1, &.{ "4", "5", "6" });
}

test "does not require a trailing newline" {
    var table = try Table.parse(testing.allocator, "a,b\n1,2");
    defer table.deinit();

    try testing.expectEqual(@as(usize, 1), table.rowCount());
    try expectRow(table, 0, &.{ "1", "2" });
}

test "handles empty fields including a trailing one" {
    var table = try Table.parse(testing.allocator, "a,b,c\n,2,\n");
    defer table.deinit();

    try expectRow(table, 0, &.{ "", "2", "" });
}

test "handles CRLF line endings" {
    var table = try Table.parse(testing.allocator, "a,b\r\n1,2\r\n");
    defer table.deinit();

    try testing.expectEqual(@as(usize, 1), table.rowCount());
    try expectRow(table, 0, &.{ "1", "2" });
}

test "skips blank lines" {
    var table = try Table.parse(testing.allocator, "a,b\n\n1,2\n\n\n3,4\n\n");
    defer table.deinit();

    try testing.expectEqual(@as(usize, 2), table.rowCount());
    try expectRow(table, 1, &.{ "3", "4" });
}

test "quoted fields carry delimiters, newlines and escaped quotes" {
    const input =
        \\name,note
        \\"Doe, John","said ""hi"""
        \\plain,"two
        \\lines"
        \\
    ;
    var table = try Table.parse(testing.allocator, input);
    defer table.deinit();

    try testing.expectEqual(@as(usize, 2), table.rowCount());
    try expectRow(table, 0, &.{ "Doe, John", "said \"hi\"" });
    try expectRow(table, 1, &.{ "plain", "two\nlines" });
}

test "empty quoted field stays empty" {
    var table = try Table.parse(testing.allocator, "a,b\n\"\",x\n");
    defer table.deinit();

    try expectRow(table, 0, &.{ "", "x" });
}

test "rejects an unterminated quote" {
    try testing.expectError(ParseError.UnterminatedQuote, Table.parse(testing.allocator, "a\n\"oops\n"));
}

test "rejects stray characters after a closing quote" {
    try testing.expectError(
        ParseError.UnexpectedCharacterAfterQuote,
        Table.parse(testing.allocator, "a,b\n\"x\"y,2\n"),
    );
}

test "rejects rows that disagree with the header" {
    try testing.expectError(ParseError.InconsistentFieldCount, Table.parse(testing.allocator, "a,b\n1,2,3\n"));
}

test "rejects input without a header" {
    try testing.expectError(ParseError.MissingHeader, Table.parse(testing.allocator, ""));
}

test "header-only input yields zero rows" {
    var table = try Table.parse(testing.allocator, "a,b\n");
    defer table.deinit();

    try testing.expectEqual(@as(usize, 2), table.columnCount());
    try testing.expectEqual(@as(usize, 0), table.rowCount());
}

test "columnIndex finds columns by name" {
    var table = try Table.parse(testing.allocator, "id,name\n1,ada\n");
    defer table.deinit();

    try testing.expectEqual(@as(?usize, 0), table.columnIndex("id"));
    try testing.expectEqual(@as(?usize, 1), table.columnIndex("name"));
    try testing.expectEqual(@as(?usize, null), table.columnIndex("missing"));
}

test "infers a type per column" {
    const input =
        \\id,ratio,name,mixed
        \\1,0.5,ada,1
        \\2,1.25,grace,x
        \\
    ;
    var table = try Table.parse(testing.allocator, input);
    defer table.deinit();

    const types = try table.inferTypes(testing.allocator);
    defer testing.allocator.free(types);

    try testing.expectEqualSlices(dtype.ColumnType, &.{ .int, .float, .string, .string }, types);
}

test "an integer column with one float widens to float" {
    var table = try Table.parse(testing.allocator, "n\n1\n2\n3.5\n");
    defer table.deinit();

    const types = try table.inferTypes(testing.allocator);
    defer testing.allocator.free(types);

    try testing.expectEqualSlices(dtype.ColumnType, &.{.float}, types);
}

test "parses from a file on disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "people.csv", .data = "id,name\n1,ada\n2,grace\n" });

    var table = try Table.parseFile(testing.allocator, testing.io, tmp.dir, "people.csv", .unlimited);
    defer table.deinit();

    try testing.expectEqual(@as(usize, 2), table.rowCount());
    try expectRow(table, 1, &.{ "2", "grace" });
}

test "parses a medium file" {
    const gpa = testing.allocator;
    const row_count = 5000;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "id,name,score\n");

    var buf: [64]u8 = undefined;
    for (0..row_count) |i| {
        try text.appendSlice(gpa, try std.fmt.bufPrint(&buf, "{d},user{d},{d}.5\n", .{ i, i, i }));
    }

    var table = try Table.parse(gpa, text.items);
    defer table.deinit();

    try testing.expectEqual(@as(usize, row_count), table.rowCount());
    try testing.expectEqualStrings("user4999", table.get(row_count - 1, 1));

    const types = try table.inferTypes(gpa);
    defer gpa.free(types);
    try testing.expectEqualSlices(dtype.ColumnType, &.{ .int, .string, .float }, types);
}
