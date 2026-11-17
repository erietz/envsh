//! envsh: open a shell (or run a command) with a `.env` file loaded.
const std = @import("std");
const dotenv = @import("dotenv");

const usage =
    \\usage: envsh NAME                  open $SHELL with ./.env.NAME loaded
    \\       envsh NAME -- CMD [ARGS]    run CMD with ./.env.NAME loaded, instead of a shell
    \\       envsh -f PATH [-- CMD ...]  same, with an explicit file; ENVSH is the file's basename
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

/// `args` excludes argv[0]. Allocations go in `arena`.
fn parseArgs(
    arena: std.mem.Allocator,
    args: []const []const u8,
) std.mem.Allocator.Error!ParsedArgs {
    if (args.len == 0) return .{ .usage_error = "missing NAME" };

    const first = args[0];
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        return .help;
    }

    var cmd: Command = undefined;
    var rest: []const []const u8 = undefined;
    if (std.mem.eql(u8, first, "-f")) {
        if (args.len < 2) return .{ .usage_error = "-f needs a PATH" };
        cmd.path = args[1];
        cmd.name = std.fs.path.basename(cmd.path);
        if (cmd.name.len == 0) {
            return .{ .usage_error = "PATH has no file name" };
        }
        rest = args[2..];
    } else if (first.len == 0) {
        return .{ .usage_error = "NAME must not be empty" };
    } else if (first[0] == '-') {
        return .{ .usage_error = "unknown option" };
    } else {
        if (std.mem.indexOfScalar(u8, first, '/') != null) {
            return .{ .usage_error = "NAME must not contain '/'; use -f PATH" };
        }
        cmd.name = first;
        cmd.path = try std.fmt.allocPrint(arena, ".env.{s}", .{first});
        rest = args[1..];
    }

    if (rest.len == 0) {
        cmd.argv = null;
    } else if (std.mem.eql(u8, rest[0], "--")) {
        if (rest.len == 1) return .{ .usage_error = "'--' needs a CMD" };
        cmd.argv = rest[1..];
    } else {
        return .{
            .usage_error = "unexpected argument; put a command after '--'",
        };
    }
    return .{ .run = cmd };
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

    const cmd = switch (try parseArgs(arena, args)) {
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
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseArgs(arena_state.allocator(), args);
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
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseArgs(arena_state.allocator(), args);
    try std.testing.expect(parsed == .usage_error);
}

test "parseArgs: NAME" {
    try expectRun(&.{"test"}, ".env.test", "test", null);
}

test "parseArgs: NAME -- CMD ARGS" {
    try expectRun(
        &.{ "test", "--", "mysqlsh", "--uri", "x" },
        ".env.test",
        "test",
        &.{ "mysqlsh", "--uri", "x" },
    );
}

test "parseArgs: -f PATH" {
    try expectRun(
        &.{ "-f", "config/prod.env" },
        "config/prod.env",
        "prod.env",
        null,
    );
}

test "parseArgs: -f PATH -- CMD" {
    try expectRun(
        &.{ "-f", "/tmp/x.env", "--", "env" },
        "/tmp/x.env",
        "x.env",
        &.{"env"},
    );
}

test "parseArgs: help" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(try parseArgs(arena, &.{"--help"}) == .help);
    try std.testing.expect(try parseArgs(arena, &.{"-h"}) == .help);
}

test "parseArgs: usage errors" {
    try expectUsageError(&.{});
    try expectUsageError(&.{"-f"});
    try expectUsageError(&.{"-x"});
    try expectUsageError(&.{""});
    try expectUsageError(&.{"../prod"});
    try expectUsageError(&.{ "test", "--" });
    try expectUsageError(&.{ "test", "extra" });
}
