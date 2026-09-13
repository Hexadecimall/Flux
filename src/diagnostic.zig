const std = @import("std");

pub fn displayPath(path: []const u8) []const u8 {
    var separator_index: usize = 0;
    for (path, 0..) |character, index| {
        if (character == '/' or character == '\\') separator_index = index + 1;
    }
    return path[separator_index..];
}

pub fn redactKnownRoots(
    allocator: std.mem.Allocator,
    input: []const u8,
    roots: []const []const u8,
) std.mem.Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var input_index: usize = 0;
    while (input_index < input.len) {
        var matched_length: usize = 0;
        for (roots) |root| {
            if (root.len > matched_length and
                root.len <= input.len - input_index and
                std.mem.eql(u8, input[input_index .. input_index + root.len], root))
            {
                matched_length = root.len;
            }
        }

        if (matched_length != 0) {
            try output.appendSlice(allocator, "<hidden>");
            input_index += matched_length;
        } else {
            try output.append(allocator, input[input_index]);
            input_index += 1;
        }
    }

    return output.toOwnedSlice(allocator);
}

test "display paths contain no parent directories" {
    try std.testing.expectEqualStrings("Build.flx", displayPath("ROOT_DIRECTORY/project/Build.flx"));
    try std.testing.expectEqualStrings("Build.flx", displayPath("ROOT_DIRECTORY\\project\\Build.flx"));
}

test "known roots are removed from compiler output" {
    const allocator = std.testing.allocator;
    const roots = [_][]const u8{ "TOOLCHAIN_ROOT", "PROJECT_ROOT" };
    const result = try redactKnownRoots(
        allocator,
        "TOOLCHAIN_ROOT/lib/file.zig: PROJECT_ROOT/src/main.zig",
        &roots,
    );
    defer allocator.free(result);

    try std.testing.expectEqualStrings(
        "<hidden>/lib/file.zig: <hidden>/src/main.zig",
        result,
    );
}
