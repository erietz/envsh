//! envsh: open a shell (or run a command) with a `.env` file loaded.
const std = @import("std");
const dotenv = @import("dotenv");

const usage =
    \\usage: envsh [PATH]                 open $SHELL with PATH loaded (default: ./.env)
    \\       envsh [PATH] -- CMD [ARGS]   run CMD with PATH loaded, instead of a shell
    \\
;

/// Largest `.env` file envsh will read.
const max_file_size = 1 << 20;

const Command = struct {
    /// File to load, as the user should see it in messages.
    path: []const u8,
    /// Value for ENVSH.
    name: []const u8,
    /// CMD [ARGS], or null to open $SHELL.
    argv: ?[]const []const u8,
};

const ParsedArgs = union(enum) {
    run: Command,
    help,
    /// A usage error, with a short reason.
    usage_error: []const u8,
};

/// Loaded when no PATH is given.
const default_path = ".env";

/// `args` excludes argv[0].
fn parseArgs(args: []const []const u8) ParsedArgs {
    var rest = args;
    var path: []const u8 = default_path;
    if (rest.len > 0) {
        const first = rest[0];
        if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
            return .help;
        }
        if (first.len == 0) return .{ .usage_error = "PATH must not be empty" };
        if (!std.mem.eql(u8, first, "--")) {
            if (first[0] == '-') {
                return .{ .usage_error = "unknown option; use ./PATH for a file starting with '-'" };
            }
            path = first;
            rest = rest[1..];
        }
    }

    const name = std.fs.path.basename(path);
    if (name.len == 0) return .{ .usage_error = "PATH has no file name" };

    var argv: ?[]const []const u8 = null;
    if (rest.len > 0) {
        if (!std.mem.eql(u8, rest[0], "--")) {
            return .{
                .usage_error = "unexpected argument; put a command after '--'",
            };
        }
        if (rest.len == 1) return .{ .usage_error = "'--' needs a CMD" };
        argv = rest[1..];
    }
    return .{ .run = .{ .path = path, .name = name, .argv = argv } };
}

/// Prints `envsh: <message>` to stderr and exits with `status`.
fn die(status: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("envsh: " ++ fmt ++ "\n", args);
    std.process.exit(status);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;

    const raw_args = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, raw_args.len -| 1);
    for (args, raw_args[1..]) |*dst, src| dst.* = src;

    const cmd = switch (parseArgs(args)) {
        .run => |c| c,
        .help => {
            var buf: [1024]u8 = undefined;
            var stdout = std.Io.File.stdout().writer(io, &buf);
            try stdout.interface.writeAll(usage);
            try stdout.interface.flush();
            return;
        },
        .usage_error => |reason| {
            std.debug.print("envsh: {s}\n{s}", .{ reason, usage });
            std.process.exit(2);
        },
    };

    // 1. Refuse to nest.
    if (env.get("ENVSH")) |current| {
        die(1, "already in \"{s}\"; exit first", .{current});
    }

    // 2. Read and parse the file.
    const source = std.Io.Dir.cwd().readFileAlloc(
        io,
        cmd.path,
        arena,
        .limited(max_file_size),
    ) catch |err| switch (err) {
        error.FileNotFound => die(2, "{s}: file not found", .{cmd.path}),
        error.StreamTooLong => die(
            2,
            "{s}: file is larger than {d} bytes",
            .{ cmd.path, max_file_size },
        ),
        else => die(2, "{s}: cannot read file: {t}", .{ cmd.path, err }),
    };
    var diag: dotenv.Diagnostic = undefined;
    const entries = dotenv.parse(arena, source, &diag) catch |err| switch (err) {
        error.Invalid => die(
            2,
            "{s}:{d}:{d}: {s}",
            .{ cmd.path, diag.line, diag.column, diag.kind.message() },
        ),
        else => |e| return e,
    };

    // 3. The file may not set ENVSH itself.
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, "ENVSH")) {
            die(
                2,
                "{s}:{d}:1: the file must not define ENVSH; envsh sets it",
                .{ cmd.path, entry.line },
            );
        }
    }

    // Decide what to run before the file can change $SHELL.
    const argv: []const []const u8 = cmd.argv orelse blk: {
        const shell = env.get("SHELL") orelse "";
        const program = if (shell.len == 0) "/bin/sh" else shell;
        // Copy it: env.put below may free the original SHELL value.
        const owned = try arena.dupe(u8, program);
        break :blk try arena.dupe([]const u8, &.{owned});
    };

    // 4. Current environment, then the file (file wins), then ENVSH.
    for (entries) |entry| try env.put(entry.key, entry.value);
    try env.put("ENVSH", cmd.name);

    // 5. Announce (shell mode only).
    if (cmd.argv == null) std.debug.print("envsh: loaded {s}\n", .{cmd.path});

    // 6. Replace ourselves. Only returns on failure.
    const err = std.process.replace(io, .{ .argv = argv, .environ_map = env });
    switch (err) {
        error.FileNotFound => die(127, "{s}: command not found", .{argv[0]}),
        else => die(126, "{s}: cannot execute: {t}", .{ argv[0], err }),
    }
}

fn expectRun(
    args: []const []const u8,
    path: []const u8,
    name: []const u8,
    argv: ?[]const []const u8,
) !void {
    const parsed = parseArgs(args);
    try std.testing.expect(parsed == .run);
    const cmd = parsed.run;
    try std.testing.expectEqualStrings(path, cmd.path);
    try std.testing.expectEqualStrings(name, cmd.name);
    if (argv) |expected| {
        try std.testing.expect(cmd.argv != null);
        try std.testing.expectEqual(expected.len, cmd.argv.?.len);
        for (expected, cmd.argv.?) |e, a| {
            try std.testing.expectEqualStrings(e, a);
        }
    } else {
        try std.testing.expect(cmd.argv == null);
    }
}

fn expectUsageError(args: []const []const u8) !void {
    try std.testing.expect(parseArgs(args) == .usage_error);
}

test "parseArgs: no arguments loads .env" {
    try expectRun(&.{}, ".env", ".env", null);
}

test "parseArgs: -- CMD loads .env" {
    try expectRun(&.{ "--", "env" }, ".env", ".env", &.{"env"});
}

test "parseArgs: PATH" {
    try expectRun(&.{".env.test"}, ".env.test", ".env.test", null);
}

test "parseArgs: PATH with directories" {
    try expectRun(
        &.{"config/prod.env"},
        "config/prod.env",
        "prod.env",
        null,
    );
}

test "parseArgs: PATH -- CMD ARGS" {
    try expectRun(
        &.{ ".env.test", "--", "mysqlsh", "--uri", "x" },
        ".env.test",
        ".env.test",
        &.{ "mysqlsh", "--uri", "x" },
    );
}

test "parseArgs: ./PATH starting with '-'" {
    try expectRun(&.{"./-odd"}, "./-odd", "-odd", null);
}

test "parseArgs: help" {
    try std.testing.expect(parseArgs(&.{"--help"}) == .help);
    try std.testing.expect(parseArgs(&.{"-h"}) == .help);
}

test "parseArgs: usage errors" {
    try expectUsageError(&.{"-f"});
    try expectUsageError(&.{"-x"});
    try expectUsageError(&.{""});
    try expectUsageError(&.{"/"});
    try expectUsageError(&.{"--"});
    try expectUsageError(&.{ ".env.test", "--" });
    try expectUsageError(&.{ ".env.test", "extra" });
}
