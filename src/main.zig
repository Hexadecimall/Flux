const std = @import("std");
const flux = @import("flux");

pub const panic = std.debug.simple_panic;

pub fn main(initialization: std.process.Init) void {
    const exit_code = run(initialization) catch |failure| {
        std.debug.print("flux: {s}\n", .{@errorName(failure)});
        std.process.exit(2);
    };
    std.process.exit(exit_code);
}

fn run(initialization: std.process.Init) !u8 {
    const allocator = initialization.arena.allocator();
    const arguments = try initialization.minimal.args.toSlice(allocator);

    if (arguments.len == 1 or std.mem.eql(u8, arguments[1], "help") or std.mem.eql(u8, arguments[1], "-help") or std.mem.eql(u8, arguments[1], "-h")) {
        writeStandardOutput(initialization.io, help_text);
        return 0;
    }

    if (std.mem.eql(u8, arguments[1], "version") or std.mem.eql(u8, arguments[1], "-version")) {
        writeStandardOutput(initialization.io, "Flux 0.2.0\n");
        return 0;
    }

    if (std.mem.eql(u8, arguments[1], "check")) {
        const build_file = if (arguments.len >= 3) arguments[2] else "Build.flx";
        return checkBuildFile(initialization, build_file);
    }

    if (std.mem.eql(u8, arguments[1], "init")) {
        if (arguments.len != 2) return error.UnexpectedArgument;
        const file = try std.Io.Dir.cwd().createFile(initialization.io, "Build.flx", .{ .exclusive = true });
        defer file.close(initialization.io);
        try file.writeStreamingAll(initialization.io, initial_build_file);
        writeStandardOutput(initialization.io, "Created Build.flx; set the project name and source patterns.\n");
        return 0;
    }
    if (std.mem.eql(u8, arguments[1], "clean")) {
        if (arguments.len != 2) return error.UnexpectedArgument;
        try clean(initialization);
        return 0;
    }

    if (std.mem.eql(u8, arguments[1], "build") or std.mem.eql(u8, arguments[1], "run") or std.mem.eql(u8, arguments[1], "test")) {
        var engine = flux.build_engine.Engine{ .allocator = allocator, .input_output = initialization.io };
        engine.testing = std.mem.eql(u8, arguments[1], "test");
        const working_directory = try std.process.currentPathAlloc(initialization.io, allocator);
        var compiler_environment = try initialization.environ_map.clone(allocator);
        const cache_variables = [_][]const u8{ "TMPDIR", "ZIG_LOCAL_CACHE_DIR", "ZIG_GLOBAL_CACHE_DIR" };
        const cache_names = [_][]const u8{ "temporary", "zig-local", "zig-global" };
        for (cache_variables, cache_names) |variable, name| {
            const location = try std.fs.path.join(allocator, &.{ working_directory, "build/.flux", name });
            try std.Io.Dir.cwd().createDirPath(initialization.io, location);
            try compiler_environment.put(variable, location);
        }
        engine.environment = &compiler_environment;
        var environment_hash = std.crypto.hash.sha2.Sha256.init(.{});
        var environment_iterator = compiler_environment.iterator();
        while (environment_iterator.next()) |entry| {
            environment_hash.update(entry.key_ptr.*);
            environment_hash.update(&.{0});
            environment_hash.update(entry.value_ptr.*);
            environment_hash.update(&.{0});
        }
        engine.environment_digest = environment_hash.finalResult();
        var argument_index: usize = 2;
        var runtime_arguments: []const []const u8 = &.{};
        while (argument_index < arguments.len) : (argument_index += 1) {
            const argument = arguments[argument_index];
            if (std.mem.eql(u8, argument, "--")) {
                runtime_arguments = arguments[argument_index + 1 ..];
                break;
            }
            if (std.mem.eql(u8, argument, "-jobs")) {
                argument_index += 1;
                if (argument_index == arguments.len) return error.MissingOptionValue;
                engine.jobs = std.fmt.parseInt(usize, arguments[argument_index], 10) catch return error.InvalidJobCount;
                if (engine.jobs == 0 or engine.jobs > 256) return error.InvalidJobCount;
            } else if (std.mem.eql(u8, argument, "-target") or std.mem.eql(u8, argument, "-profile")) {
                argument_index += 1;
                if (argument_index == arguments.len) return error.MissingOptionValue;
                if (std.mem.eql(u8, argument, "-target")) engine.target_triple = arguments[argument_index] else engine.profile = arguments[argument_index];
            } else if (std.mem.startsWith(u8, argument, "-")) return error.UnknownOption else {
                if (engine.selected != null) return error.TooManyTargetNames;
                engine.selected = argument;
            }
        }
        try engine.load("Build.flx");
        try engine.build(std.mem.eql(u8, arguments[1], "run") or engine.testing, runtime_arguments);
        return engine.exit_code;
    }

    writeStandardError(initialization.io, "flux: unknown command\n");
    return 2;
}

fn checkBuildFile(initialization: std.process.Init, build_file: []const u8) !u8 {
    const allocator = initialization.arena.allocator();
    const source = std.Io.Dir.cwd().readFileAlloc(
        initialization.io,
        build_file,
        allocator,
        .limited(64 * 1024 * 1024),
    ) catch {
        writeStandardError(initialization.io, "flux: could not read build file\n");
        return 2;
    };

    const result = try flux.syntax.parse(allocator, source);
    switch (result) {
        .document => |document| {
            var output_buffer: [256]u8 = undefined;
            var output_writer: std.Io.File.Writer = .init(.stdout(), initialization.io, &output_buffer);
            output_writer.interface.print("{s}: syntax valid ({d} declarations)\n", .{
                flux.diagnostic.displayPath(build_file),
                document.calls.len,
            }) catch {};
            output_writer.interface.flush() catch {};
            return 0;
        },
        .issue => |issue| {
            var error_buffer: [512]u8 = undefined;
            var error_writer: std.Io.File.Writer = .init(.stderr(), initialization.io, &error_buffer);
            error_writer.interface.print("{s}:{d}:{d}: error: {s}\n", .{
                flux.diagnostic.displayPath(build_file),
                issue.location.line,
                issue.location.column,
                issue.message,
            }) catch {};
            error_writer.interface.flush() catch {};
            return 1;
        },
    }
}

fn writeStandardOutput(input_output: std.Io, message: []const u8) void {
    var output_buffer: [1024]u8 = undefined;
    var output_writer: std.Io.File.Writer = .init(.stdout(), input_output, &output_buffer);
    output_writer.interface.writeAll(message) catch {};
    output_writer.interface.flush() catch {};
}

fn writeStandardError(input_output: std.Io, message: []const u8) void {
    var error_buffer: [1024]u8 = undefined;
    var error_writer: std.Io.File.Writer = .init(.stderr(), input_output, &error_buffer);
    error_writer.interface.writeAll(message) catch {};
    error_writer.interface.flush() catch {};
}

const help_text =
    \\Flux 0.2.0
    \\
    \\Usage:
    \\  flux build [targetName] [-profile debug|release] [-target triple]
    \\  flux run [targetName] [-- arguments...]
    \\  flux test [targetName]
    \\  flux init
    \\  flux clean
    \\  flux check [Build.flx]
    \\  flux version
    \\
;

const initial_build_file =
    \\project("Project") {
    \\    language(cxx) { compiler(builtIn) }
    \\    standard(20)
    \\    target("app", executable) {
    \\        source(implementation) { "src/**/*.cpp" }
    \\    }
    \\}
    \\
;

fn clean(initialization: std.process.Init) !void {
    const input_output = initialization.io;
    const allocator = initialization.arena.allocator();
    const status = std.Io.Dir.cwd().statFile(input_output, "build", .{ .follow_symlinks = false }) catch |failure| switch (failure) {
        error.FileNotFound => return,
        else => return failure,
    };
    if (status.kind != .directory) return error.BuildRootMustBeDirectory;
    var directory = try std.Io.Dir.cwd().openDir(input_output, "build", .{ .iterate = true });
    defer directory.close(input_output);
    try directory.createDirPath(input_output, ".flux");
    const lock = try directory.createFile(input_output, ".flux/lock", .{ .truncate = false });
    defer lock.close(input_output);
    if (!try lock.tryLock(input_output, .exclusive)) return error.BuildAlreadyRunning;
    defer lock.unlock(input_output);
    var iterator = directory.iterate();
    while (try iterator.next(input_output)) |entry| {
        if (entry.kind != .directory or std.mem.startsWith(u8, entry.name, ".")) continue;
        for ([_][]const u8{ "debug", "release" }) |profile| {
            const relative = try std.fs.path.join(allocator, &.{ entry.name, profile });
            const profile_status = directory.statFile(input_output, relative, .{ .follow_symlinks = false }) catch continue;
            if (profile_status.kind != .directory) continue;
            const marker = try std.fs.path.join(allocator, &.{ relative, ".flux-managed" });
            const content = directory.readFileAlloc(input_output, marker, allocator, .limited(64)) catch continue;
            if (!std.mem.eql(u8, content, "flux-v1\n")) continue;
            try directory.deleteTree(input_output, relative);
        }
    }
    writeStandardOutput(input_output, "Cleaned generated targets; compiler caches retained.\n");
}
