//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    line: usize, // 1-based
};

pub const ErrorKind = enum {
    leading_whitespace,
    missing_equals,
    invalid_key,
    whitespace_around_equals,
    invalid_unquoted_char, // with a hint: wrap the value in single quotes
    double_quotes,
    unterminated_quote,
    trailing_characters, // after the closing quote, or a trailing comment/whitespace
    duplicate_key,
    carriage_return, // CRLF line endings are not supported
};

pub const Diagnostic = struct {
    line: usize, // 1-based
    column: usize, // 1-based
    kind: ErrorKind,
};

/// Entries are in file order. Keys and values are slices into `source`, so
/// `source` must outlive the returned entries. Caller frees the returned slice
/// with `gpa.free`.
///
/// Blank lines (including whitespace-only lines) and comment lines (including
/// indented ones) are ignored.
///
/// On error.Invalid, `diag` (if given) says where and why.
pub fn parse(gpa: std.mem.Allocator, source: []const u8, diag: ?*Diagnostic) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    var seen_keys = std.StringHashMap(void).init(gpa);
    defer seen_keys.deinit();

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 1;
    while (lines.next()) |line| : (line_number += 1) {
        if (std.mem.indexOfScalar(u8, line, '\r')) |i| {
            return fail(diag, line_number, i + 1, .carriage_return);
        }

        const content = std.mem.trimStart(u8, line, " \t");
        if (content.len == 0 or content[0] == '#') continue;
        if (content.len != line.len) return fail(diag, line_number, 1, .leading_whitespace);

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse
            return fail(diag, line_number, line.len + 1, .missing_equals);
        const key = line[0..eq];
        const value_start = eq + 1;
        const value = line[value_start..];

        if (key.len > 0 and isBlank(key[key.len - 1])) {
            const ws_start = std.mem.trimEnd(u8, key, " \t").len;
            return fail(diag, line_number, ws_start + 1, .whitespace_around_equals);
        }
        if (value.len > 0 and isBlank(value[0])) {
            return fail(diag, line_number, value_start + 1, .whitespace_around_equals);
        }

        if (invalidKeyIndex(key)) |i| return fail(diag, line_number, i + 1, .invalid_key);

        const parsed_value = try parseValue(value, line_number, value_start + 1, diag);

        const gop = try seen_keys.getOrPut(key);
        if (gop.found_existing) return fail(diag, line_number, 1, .duplicate_key);

        try entries.append(gpa, .{
            .key = key,
            .value = parsed_value,
            .line = line_number,
        });
    }

    return entries.toOwnedSlice(gpa);
}

fn fail(diag: ?*Diagnostic, line: usize, column: usize, kind: ErrorKind) error{Invalid} {
    if (diag) |d| d.* = .{ .line = line, .column = column, .kind = kind };
    return error.Invalid;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Returns the index of the first invalid character in `key`, or null if the
/// key is valid. An empty key is reported at index 0.
fn invalidKeyIndex(key: []const u8) ?usize {
    if (key.len == 0) return 0;
    for (key, 0..) |c, i| {
        const ok = c == '_' or (if (i == 0) std.ascii.isAlphabetic(c) else std.ascii.isAlphanumeric(c));
        if (!ok) return i;
    }
    return null;
}

/// Characters allowed in an unquoted value: `A-Z a-z 0-9 _ - . / : @ % + , =`.
fn isUnquotedChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '_', '-', '.', '/', ':', '@', '%', '+', ',', '=' => true,
        else => false,
    };
}

/// `value_col` is the 1-based column of `value[0]` within its line.
fn parseValue(value: []const u8, line: usize, value_col: usize, diag: ?*Diagnostic) error{Invalid}![]const u8 {
    if (value.len == 0) return value;

    switch (value[0]) {
        '\'' => {
            const close = std.mem.indexOfScalarPos(u8, value, 1, '\'') orelse
                return fail(diag, line, value_col, .unterminated_quote);
            if (close + 1 < value.len) {
                return fail(diag, line, value_col + close + 1, .trailing_characters);
            }
            return value[1..close];
        },
        '"' => return fail(diag, line, value_col, .double_quotes),
        else => {
            for (value, 0..) |c, i| {
                if (isUnquotedChar(c)) continue;
                // Whitespace followed by nothing, or by a `#` comment, is trailing
                // junk; anything else is a bad character that needs quoting.
                const rest = std.mem.trimStart(u8, value[i..], " \t");
                const trailing = isBlank(c) and (rest.len == 0 or rest[0] == '#');
                return fail(diag, line, value_col + i, if (trailing) .trailing_characters else .invalid_unquoted_char);
            }
            return value;
        },
    }
}

const valid_example =
    \\# Valid
    \\DATABASE_URL=mysql://user:pa%40ss@db.example.com:3306/app
    \\TOKEN=YWJjZA==
    \\GREETING='hello world'
    \\PASSWORD='p$a#ss"word'
    \\EMPTY=
    \\ALSO_EMPTY=''
;

test "parse valid example" {
    const allocator = std.testing.allocator;
    const entries = try parse(allocator, valid_example, null);
    defer allocator.free(entries);

    const expected = [_]struct { []const u8, []const u8, usize }{
        .{ "DATABASE_URL", "mysql://user:pa%40ss@db.example.com:3306/app", 2 },
        .{ "TOKEN", "YWJjZA==", 3 },
        .{ "GREETING", "hello world", 4 },
        .{ "PASSWORD", "p$a#ss\"word", 5 },
        .{ "EMPTY", "", 6 },
        .{ "ALSO_EMPTY", "", 7 },
    };
    try std.testing.expectEqual(expected.len, entries.len);
    for (expected, entries) |exp, entry| {
        try std.testing.expectEqualStrings(exp[0], entry.key);
        try std.testing.expectEqualStrings(exp[1], entry.value);
        try std.testing.expectEqual(exp[2], entry.line);
    }
}

test "parse skips blank, whitespace-only, and comment lines" {
    const allocator = std.testing.allocator;
    const source = "\n   \n\t\n# comment\n  # indented comment\nA=1\n";
    const entries = try parse(allocator, source, null);
    defer allocator.free(entries);

    try std.testing.expectEqual(1, entries.len);
    try std.testing.expectEqualStrings("A", entries[0].key);
    try std.testing.expectEqualStrings("1", entries[0].value);
    try std.testing.expectEqual(6, entries[0].line);
}

const InvalidCase = struct {
    source: []const u8,
    line: usize,
    column: usize,
};

const invalid_entries = std.EnumArray(ErrorKind, []const InvalidCase).init(.{
    .leading_whitespace = &.{
        .{ .source = "  KEY=value", .line = 1, .column = 1 },
        .{ .source = "\tKEY=value", .line = 1, .column = 1 },
    },
    .missing_equals = &.{
        .{ .source = "KEY", .line = 1, .column = 4 },
    },
    .invalid_key = &.{
        .{ .source = "export KEY=value", .line = 1, .column = 7 },
        .{ .source = "=value", .line = 1, .column = 1 },
        .{ .source = "1KEY=value", .line = 1, .column = 1 },
    },
    .whitespace_around_equals = &.{
        .{ .source = "KEY = value", .line = 1, .column = 4 },
        .{ .source = "KEY =value", .line = 1, .column = 4 },
        .{ .source = "KEY= value", .line = 1, .column = 5 },
    },
    .invalid_unquoted_char = &.{
        .{ .source = "KEY=hello world", .line = 1, .column = 10 },
        .{ .source = "KEY=a$b", .line = 1, .column = 6 },
    },
    .double_quotes = &.{
        .{ .source = "KEY=\"value\"", .line = 1, .column = 5 },
    },
    .unterminated_quote = &.{
        .{ .source = "KEY='unterminated", .line = 1, .column = 5 },
        .{ .source = "KEY='", .line = 1, .column = 5 },
        .{ .source = "A=1\nB='x y\nC=3", .line = 2, .column = 3 },
    },
    .trailing_characters = &.{
        .{ .source = "KEY='it''s'", .line = 1, .column = 9 },
        .{ .source = "KEY='abc'def", .line = 1, .column = 10 },
        .{ .source = "KEY='x'  ", .line = 1, .column = 8 },
        .{ .source = "KEY=value  ", .line = 1, .column = 10 },
        .{ .source = "KEY=value # comment", .line = 1, .column = 10 },
    },
    .duplicate_key = &.{
        .{ .source = "KEY=value\nKEY=another", .line = 2, .column = 1 },
        .{ .source = "A=1\nB=2\nA=3", .line = 3, .column = 1 },
    },
    .carriage_return = &.{
        .{ .source = "KEY=value\r", .line = 1, .column = 10 },
        .{ .source = "A=1\r\nB=2", .line = 1, .column = 4 },
    },
});

test "parse invalid entries" {
    const allocator = std.testing.allocator;

    for (std.enums.values(ErrorKind)) |kind| {
        for (invalid_entries.get(kind)) |case| {
            errdefer std.debug.print("case ({t}): {f}\n", .{ kind, std.zig.fmtString(case.source) });

            var diag: Diagnostic = undefined;
            if (parse(allocator, case.source, &diag)) |entries| {
                allocator.free(entries);
                return error.TestExpectedError;
            } else |err| try std.testing.expectEqual(error.Invalid, err);

            try std.testing.expectEqual(kind, diag.kind);
            try std.testing.expectEqual(case.line, diag.line);
            try std.testing.expectEqual(case.column, diag.column);
        }
    }
}
