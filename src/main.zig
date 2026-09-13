const std = @import("std");
const flux = @import("flux");

pub const panic = std.debug.simple_panic;

pub fn main(initialization: std.process.Init) void {
    const exit_code = run(initialization) catch {
        writeStandardError(initialization.io, "flux: internal error\n");
        std.process.exit(2);
    };
    std.process.exit(exit_code);
}

fn run(initialization: std.process.Init) !u8 {
    const allocator = initialization.arena.allocator();
    const arguments = try initialization.minimal.args.toSlice(allocator);

    if (arguments.len == 1) {
        writeStandardOutput(initialization.io, help_text);
        return 0;
    }

    if (std.mem.eql(u8, arguments[1], "version") or std.mem.eql(u8, arguments[1], "-version")) {
        writeStandardOutput(initialization.io, "Flux 0.1.0\n");
        return 0;
    }

    if (std.mem.eql(u8, arguments[1], "check")) {
        const build_file = if (arguments.len >= 3) arguments[2] else "Build.flx";
        return checkBuildFile(initialization, build_file);
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
            output_writer.interface.print("{s}: valid ({d} declarations)\n", .{
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
    \\Flux 0.1.0
    \\
    \\Usage:
    \\  flux check [Build.flx]
    \\  flux version
    \\
;
