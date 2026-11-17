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
    var entires: std.ArrayList(Entry) = .empty;
    defer entires.deinit(gpa);
    var seen_keys = std.StringHashMap(bool).init(gpa);
    defer seen_keys.deinit();
    var lines = std.mem.splitScalar(u8, source, '\n');

    var line_number: usize = 1;
    while (lines.next()) |line| : (line_number += 1) {
        const column: usize = 1;

        if (std.mem.startsWith(u8, line, " ") or std.mem.startsWith(u8, line, "\t")) {
            if (diag) |d| {
                d.* = Diagnostic{
                    .line = line_number,
                    .column = column,
                    .kind = ErrorKind.leading_whitespace,
                };
            }
            return error.Invalid;
        }
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue; // skip empty lines
        if (std.mem.startsWith(u8, trimmed, "#")) continue; // skip comments

        const eq_index = std.mem.indexOf(u8, trimmed, "=");
        if (eq_index == null) {
            if (diag) |d| {
                d.* = Diagnostic{
                    .line = line_number,
                    .column = column,
                    .kind = ErrorKind.missing_equals,
                };
            }
            return error.Invalid;
        }

        const key = trimmed[0..eq_index.?];
        const value_start = eq_index.? + 1;
        const value = trimmed[value_start..];

        if (std.mem.endsWith(u8, key, " ") or std.mem.endsWith(u8, key, "\t") or
            std.mem.startsWith(u8, value, " ") or std.mem.startsWith(u8, value, "\t"))
        {
            if (diag) |d| {
                d.* = Diagnostic{
                    .line = line_number,
                    .column = column,
                    .kind = ErrorKind.whitespace_around_equals,
                };
            }
            return error.Invalid;
        }

        // Validate key
        if (!isValidKey(key)) {
            if (diag) |d| {
                d.* = Diagnostic{
                    .line = line_number,
                    .column = column,
                    .kind = ErrorKind.invalid_key,
                };
            }
            return error.Invalid;
        }

        // Validate value
        const parsed_value = try parseValue(value, diag);

        // Check for duplicate keys
        if (seen_keys.get(key)) |exists| {
            if (exists) {
                if (diag) |d| {
                    d.* = Diagnostic{
                        .line = line_number,
                        .column = column,
                        .kind = ErrorKind.duplicate_key,
                    };
                }
                return error.Invalid;
            }
        } else {
            _ = try seen_keys.put(key, true);
        }

        try entires.append(gpa, Entry{
            .key = key,
            .value = parsed_value,
            .line = line_number,
        });
    }

    return entires.toOwnedSlice(gpa);
}

fn isValidKey(key: []const u8) bool {
    if (key.len == 0) return false;

    for (key, 0..) |char, i| {
        if (i == 0) {
            if (!std.ascii.isAlphabetic(char) and char != '_') return false;
        } else {
            if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
        }
    }

    return true;
}

fn isValidValue(value: []const u8) bool {
    if (value.len == 0) return true; // empty value is valid

    if (std.mem.startsWith(u8, value, "'")) {
        // Quoted value
        if (!std.mem.endsWith(u8, value, "'")) return false; // unterminated quote
        // Check for trailing characters after the closing quote
        const closing_quote_index = std.mem.indexOf(u8, value[1..], "'") orelse return false;
        if (closing_quote_index + 2 < value.len) return false; // trailing characters after closing quote
        return true;
    } else {
        // Unquoted value
        // One or more characters from `A-Z a-z 0-9 _ - . / : @ % + , =`. Nothing else.
        for (value) |char| {
            if (!std.ascii.isAlphanumeric(char) and
                char != '_' and
                char != '-' and
                char != '.' and
                char != '/' and
                char != ':' and
                char != '@' and
                char != '%' and
                char != '+' and
                char != ',' and
                char != '=')
            {
                return false;
            }
        }
        return true;
    }
}

fn parseValue(value: []const u8, diag: ?*Diagnostic) ![]const u8 {
    if (value.len == 0) return value; // empty value is valid

    // Quoted value
    if (std.mem.startsWith(u8, value, "'")) {
        if (!std.mem.endsWith(u8, value, "'")) {
            // unterminated quote
            if (diag) |d| {
                d.* = Diagnostic{
                    .line = 0, // line number is not available here
                    .column = 0, // column number is not available here
                    .kind = ErrorKind.unterminated_quote,
                };
            }
            return error.Invalid;
        }

        // Check for trailing characters after the closing quote
        const closing_quote_index = std.mem.indexOf(u8, value[1..], "'") orelse {
            if (diag) |d| {
                d.* = Diagnostic{
                    .line = 0, // line number is not available here
                    .column = 0, // column number is not available here
                    .kind = ErrorKind.unterminated_quote,
                };
            }
            return error.Invalid;
        };

        // trailing characters after closing quote
        if (closing_quote_index + 2 < value.len) {
            if (diag) |d| {
                d.* = Diagnostic{
                    .line = 0, // line number is not available here
                    .column = 0, // column number is not available here
                    .kind = ErrorKind.trailing_characters,
                };
            }
            return error.Invalid;
        }

        return value[1 .. closing_quote_index + 1]; // return the content inside the quotes
    } else if (std.mem.startsWith(u8, value, "\"")) {
        // Double quotes are not allowed
        if (diag) |d| {
            d.* = Diagnostic{
                .line = 0, // line number is not available here
                .column = 0, // column number is not available here
                .kind = ErrorKind.double_quotes,
            };
        }
        return error.Invalid;
    } else {
        // Unquoted value
        // One or more characters from `A-Z a-z 0-9 _ - . / : @ % + , =`. Nothing else.
        for (value) |char| {
            if (!std.ascii.isAlphanumeric(char) and
                char != '_' and
                char != '-' and
                char != '.' and
                char != '/' and
                char != ':' and
                char != '@' and
                char != '%' and
                char != '+' and
                char != ',' and
                char != '=')
            {
                if (diag) |d| {
                    d.* = Diagnostic{
                        .line = 0, // line number is not available here
                        .column = 0, // column number is not available here
                        .kind = ErrorKind.invalid_unquoted_char,
                    };
                }
                return error.Invalid;
            }
        }
        return value;
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
