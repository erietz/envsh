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
};

pub const Diagnostic = struct {
    line: usize, // 1-based
    column: usize, // 1-based
    kind: ErrorKind,
};

/// Entries are in file order. Caller frees the returned slice with `gpa.free`.
/// On error.Invalid, `diag` (if given) says where and why.
pub fn parse(gpa: std.mem.Allocator, source: []const u8, diag: ?*Diagnostic) ![]Entry {
    _ = gpa; // TODO: use gpa
    _ = source; // TODO: use source
    _ = diag; // TODO: use diag
    return error.Invalid;
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

const invalid_entries = std.EnumArray(ErrorKind, []const []const u8).init(.{
    .leading_whitespace = &.{
        "  KEY=value",
    },
    .missing_equals = &.{
        "KEY",
    },
    .invalid_key = &.{
        "export KEY=value",
    },
    .whitespace_around_equals = &.{
        "KEY = value",
    },
    .invalid_unquoted_char = &.{
        "KEY=hello world",
    },
    .double_quotes = &.{
        "KEY=\"value\"",
    },
    .unterminated_quote = &.{
        "KEY='unterminated",
    },
    .trailing_characters = &.{
        "KEY='it''s'",
    },
    .duplicate_key = &.{
        "KEY=value\nKEY=another",
    },
});

test "parse valid example" {
    const allocator = std.testing.allocator;

    const entries = try parse(allocator, valid_example, null);
    defer allocator.free(entries);

    try std.testing.expect(entries.len == 6);
    try std.testing.expect(std.mem.eql(u8, entries[0].key, "DATABASE_URL"));
    try std.testing.expect(std.mem.eql(u8, entries[0].value, "mysql://user:pa%40ss@db.example.com:3306/app"));
    try std.testing.expect(std.mem.eql(u8, entries[1].key, "TOKEN"));
    try std.testing.expect(std.mem.eql(u8, entries[1].value, "YWJjZA=="));
    try std.testing.expect(std.mem.eql(u8, entries[2].key, "GREETING"));
    try std.testing.expect(std.mem.eql(u8, entries[2].value, "hello world"));
    try std.testing.expect(std.mem.eql(u8, entries[3].key, "PASSWORD"));
    try std.testing.expect(std.mem.eql(u8, entries[3].value, "p$a#ss\"word"));
    try std.testing.expect(std.mem.eql(u8, entries[4].key, "EMPTY"));
    try std.testing.expect(std.mem.eql(u8, entries[4].value, ""));
    try std.testing.expect(std.mem.eql(u8, entries[5].key, "ALSO_EMPTY"));
    try std.testing.expect(std.mem.eql(u8, entries[5].value, ""));
}

test "parse invalid entries" {
    const allocator = std.testing.allocator;

    for (std.enums.values(ErrorKind)) |kind| {
        for (invalid_entries.get(kind)) |source| {
            var diag: Diagnostic = undefined;
            try std.testing.expectError(error.Invalid, parse(allocator, source, &diag));
            try std.testing.expectEqual(kind, diag.kind);
        }
    }
}
