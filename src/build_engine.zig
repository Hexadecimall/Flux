const std = @import("std");
const syntax = @import("syntax.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Directory = std.Io.Dir;
const Call = syntax.Call;

const CustomCompiler = struct {
    executable: []const u8,
    language: []const u8,
    settings: *Call,
};

const CustomArgumentKind = enum {
    implementation,
    header,
    library,
    optimization,
    output,
};

const CustomArgumentGroup = struct {
    position: usize,
    kind: CustomArgumentKind,
    template: []const u8,
};

fn same(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn text(value: syntax.Value) ![]const u8 {
    return switch (value) {
        .identifier, .string => |content| content,
        else => error.ExpectedText,
    };
}

fn first(call: *Call) ![]const u8 {
    if (call.arguments.len != 1) return error.ExpectedOneArgument;
    return text(call.arguments[0]);
}

fn child(statement: syntax.Statement) !*Call {
    return switch (statement) {
        .call => |declaration| declaration,
        else => error.ExpectedDeclaration,
    };
}

pub const Engine = struct {
    allocator: Allocator,
    input_output: std.Io,
    profile: []const u8 = "debug",
    target_triple: ?[]const u8 = null,
    selected: ?[]const u8 = null,
    compiler_c: []const u8 = "builtIn",
    compiler_cxx: []const u8 = "builtIn",
    custom_compiler: ?CustomCompiler = null,
    custom_compilers: std.StringHashMapUnmanaged(CustomCompiler) = .empty,
    standard: ?usize = null,
    declarations: std.ArrayList(*Call) = .empty,
    loaded: std.StringHashMapUnmanaged(bool) = .empty,
    versions: std.StringHashMapUnmanaged([]const u8) = .empty,
    environment_digest: [32]u8 = @splat(0),
    jobs: usize = 4,
    environment: ?*const std.process.Environ.Map = null,
    targets: std.StringHashMapUnmanaged(*Call) = .empty,
    artifacts: std.StringHashMapUnmanaged([]const u8) = .empty,
    visiting: std.StringHashMapUnmanaged(void) = .empty,
    exit_code: u8 = 0,
    testing: bool = false,

    pub fn load(engine: *Engine, path: []const u8) anyerror!void {
        if (same(std.fs.path.basename(path), "Lockfile.flx")) return error.LockfileCannotBeYoinked;
        const canonical = try Directory.cwd().realPathFileAlloc(engine.input_output, path, engine.allocator);
        if (engine.loaded.get(canonical)) |finished| {
            if (!finished) return error.CircularYoink;
            return;
        }
        if (engine.loaded.count() >= 256) return error.TooManyBuildFiles;
        try engine.loaded.put(engine.allocator, canonical, false);
        const source = try Directory.cwd().readFileAlloc(engine.input_output, path, engine.allocator, .limited(8 * 1024 * 1024));
        const result = try syntax.parse(engine.allocator, source);
        if (result == .issue) {
            const issue = result.issue;
            std.debug.print("{s}:{d}:{d}: {s}\n", .{ std.fs.path.basename(path), issue.location.line, issue.location.column, issue.message });
            return error.InvalidBuildFile;
        }
        for (result.document.calls) |declaration| {
            if (same(declaration.name, "yoink")) {
                if (declaration.arguments.len != 0) return error.InvalidYoink;
                for (declaration.body) |entry| {
                    if (entry != .value) return error.ExpectedFileName;
                    const filename = try text(entry.value);
                    const resolved = try std.fs.path.join(engine.allocator, &.{ std.fs.path.dirname(path) orelse ".", filename });
                    try engine.load(resolved);
                }
            } else {
                try engine.declarations.append(engine.allocator, declaration);
            }
        }
        try engine.loaded.put(engine.allocator, canonical, true);
    }

    pub fn build(engine: *Engine, execute: bool, runtime_arguments: []const []const u8) !void {
        try Directory.cwd().createDirPath(engine.input_output, "build/.flux");
        const lock = try Directory.cwd().createFile(engine.input_output, "build/.flux/lock", .{ .truncate = false });
        defer lock.close(engine.input_output);
        if (!try lock.tryLock(engine.input_output, .exclusive)) return error.BuildAlreadyRunning;
        defer lock.unlock(engine.input_output);
        if (!same(engine.profile, "debug") and !same(engine.profile, "release")) return error.UnknownProfile;
        var project: ?*Call = null;
        for (engine.declarations.items) |declaration| {
            if (!same(declaration.name, "definition")) continue;
            try engine.registerCompiler(declaration);
        }
        for (engine.declarations.items) |declaration| {
            if (same(declaration.name, "definition")) continue;
            if (!same(declaration.name, "project")) return error.UnsupportedTopLevelDeclaration;
            if (project != null) return error.DuplicateProject;
            _ = try first(declaration);
            project = declaration;
        }
        const root = project orelse return error.MissingProject;
        var targets: std.ArrayList(*Call) = .empty;
        var seen_languages: std.StringHashMapUnmanaged(void) = .empty;
        for (root.body) |statement| {
            const declaration = try child(statement);
            if (same(declaration.name, "language")) {
                const language = try first(declaration);
                if (seen_languages.contains(language)) return error.DuplicateLanguage;
                try seen_languages.put(engine.allocator, language, {});
                var compiler: []const u8 = "builtIn";
                for (declaration.body) |setting| {
                    const option = try child(setting);
                    if (!same(option.name, "compiler")) return error.UnknownLanguageSetting;
                    compiler = try first(option);
                }
                if (same(language, "c") or same(language, "cxx")) {
                    if (!same(compiler, "builtIn") and !same(compiler, "zig") and !same(compiler, "clang") and !same(compiler, "gcc")) return error.UnknownCompiler;
                    if (same(language, "c")) engine.compiler_c = compiler else engine.compiler_cxx = compiler;
                } else {
                    if (engine.custom_compiler != null) return error.MultipleCustomLanguagesNotImplemented;
                    const definition = engine.custom_compilers.get(compiler) orelse return error.UnknownCompiler;
                    if (!same(definition.language, language)) return error.CompilerDoesNotSupportLanguage;
                    engine.custom_compiler = definition;
                }
            } else if (same(declaration.name, "standard")) {
                if (declaration.arguments.len != 1 or declaration.arguments[0] != .number) return error.ExpectedStandardNumber;
                engine.standard = declaration.arguments[0].number;
            } else if (same(declaration.name, "target")) {
                if (declaration.arguments.len != 2) return error.InvalidTarget;
                const name = try text(declaration.arguments[0]);
                if (name.len == 0 or same(name, ".") or same(name, "..") or std.mem.indexOfAny(u8, name, "/\\") != null) return error.InvalidTargetName;
                for (targets.items) |existing| {
                    if (same(name, try text(existing.arguments[0]))) return error.DuplicateTarget;
                }
                const kind = try text(declaration.arguments[1]);
                if (!same(kind, "executable") and !same(kind, "staticLibrary") and !same(kind, "test")) return error.TargetKindNotImplemented;
                try engine.targets.put(engine.allocator, name, declaration);
                try targets.append(engine.allocator, declaration);
            } else return error.UnknownProjectSetting;
        }
        if (targets.items.len == 0) return error.NoTargets;
        if (execute and !engine.testing and engine.selected == null) {
            for (targets.items) |target| {
                if (same(try text(target.arguments[1]), "executable")) {
                    if (engine.selected != null) return error.SelectTargetToRun;
                    engine.selected = try text(target.arguments[0]);
                }
            }
            if (engine.selected == null) return error.NoExecutableTarget;
        }
        var matched = false;
        for (targets.items) |target| {
            const name = try text(target.arguments[0]);
            if (engine.testing and !same(try text(target.arguments[1]), "test")) continue;
            if (engine.selected) |selection| {
                if (!same(name, selection)) continue;
            }
            matched = true;
            const artifact = try engine.buildTarget(target);
            if (execute) {
                if (same(try text(target.arguments[1]), "staticLibrary")) return error.CannotRunLibrary;
                if (engine.target_triple != null) return error.CrossTargetCannotRun;
                var command: std.ArrayList([]const u8) = .empty;
                try command.append(engine.allocator, artifact);
                try command.appendSlice(engine.allocator, runtime_arguments);
                var process = try std.process.spawn(engine.input_output, .{ .argv = command.items, .environ_map = engine.environment });
                const term = try process.wait(engine.input_output);
                const status: u8 = if (term == .exited) term.exited else 128;
                if (status != 0) engine.exit_code = status;
            }
        }
        if (!matched) return error.UnknownTarget;
    }

    fn registerCompiler(engine: *Engine, declaration: *Call) !void {
        if (!same(try first(declaration), "compiler")) return error.DefinitionKindNotImplemented;
        var name: ?[]const u8 = null;
        var executable: ?[]const u8 = null;
        var language: ?[]const u8 = null;
        var settings: ?*Call = null;
        for (declaration.body) |statement| {
            const option = try child(statement);
            if (same(option.name, "name")) {
                if (name != null) return error.DuplicateCompilerName;
                name = try first(option);
            } else if (same(option.name, "executable")) {
                if (executable != null) return error.DuplicateCompilerExecutable;
                executable = try first(option);
            } else if (same(option.name, "language")) {
                if (language != null) return error.MultipleCompilerLanguagesNotImplemented;
                language = try first(option);
                settings = option;
            } else return error.UnknownCompilerDefinitionSetting;
        }
        const compiler_name = name orelse return error.MissingCompilerName;
        if (engine.custom_compilers.contains(compiler_name)) return error.DuplicateCompilerDefinition;
        try engine.custom_compilers.put(engine.allocator, compiler_name, .{
            .executable = executable orelse return error.MissingCompilerExecutable,
            .language = language orelse return error.MissingCompilerLanguage,
            .settings = settings.?,
        });
    }

    fn buildCustomTarget(
        engine: *Engine,
        name: []const u8,
        is_library: bool,
        definition: CustomCompiler,
        sources: []const []const u8,
        headers: []const []const u8,
        libraries: []const []const u8,
        object_dir: []const u8,
        output_dir: []const u8,
    ) ![]const u8 {
        var groups: std.ArrayList(CustomArgumentGroup) = .empty;
        var positions: std.AutoHashMapUnmanaged(usize, void) = .empty;
        var has_implementation = false;
        var has_output = false;
        for (definition.settings.body) |statement| {
            const setting = try child(statement);
            const kind: CustomArgumentKind = if (same(setting.name, "implementation")) .implementation else if (same(setting.name, "header")) .header else if (same(setting.name, "library")) .library else if (same(setting.name, "optimization")) .optimization else if (same(setting.name, "output")) .output else return error.UnknownCustomCompilerSetting;
            const expected_arguments: usize = if (kind == .optimization) 1 else 2;
            if (setting.arguments.len != expected_arguments) return error.InvalidCustomCompilerSetting;
            const position = try argumentPosition(setting.arguments[0]);
            if (positions.contains(position)) return error.DuplicateCustomArgumentPosition;
            try positions.put(engine.allocator, position, {});
            const template = if (kind == .optimization)
                try optimizationForProfile(setting, engine.profile)
            else
                try text(setting.arguments[1]);
            has_implementation = has_implementation or kind == .implementation;
            has_output = has_output or kind == .output;
            try groups.append(engine.allocator, .{ .position = position, .kind = kind, .template = template });
        }
        if (!has_implementation) return error.MissingImplementationArguments;
        if (!has_output) return error.MissingOutputArguments;
        std.mem.sort(CustomArgumentGroup, groups.items, {}, struct {
            fn less(_: void, left: CustomArgumentGroup, right: CustomArgumentGroup) bool {
                return left.position < right.position;
            }
        }.less);

        const artifact = try std.fmt.allocPrint(engine.allocator, "{s}/{s}{s}{s}", .{ output_dir, if (is_library) "lib" else "", name, if (is_library) ".a" else if (builtin.os.tag == .windows and engine.target_triple == null) ".exe" else "" });
        const temporary = try std.fmt.allocPrint(engine.allocator, "{s}.pending", .{artifact});
        var command: std.ArrayList([]const u8) = .empty;
        try command.append(engine.allocator, definition.executable);
        const output_values = [_][]const u8{temporary};
        for (groups.items) |group| {
            const values: []const []const u8 = switch (group.kind) {
                .implementation => sources,
                .header => headers,
                .library => libraries,
                .optimization => &.{},
                .output => &output_values,
            };
            try engine.appendCustomArguments(&command, group.template, values, group.kind == .library);
        }
        var cache_inputs: std.ArrayList([]const u8) = .empty;
        try cache_inputs.appendSlice(engine.allocator, sources);
        try cache_inputs.appendSlice(engine.allocator, headers);
        try cache_inputs.appendSlice(engine.allocator, libraries);
        const cache_manifest = try std.fmt.allocPrint(engine.allocator, "{s}/custom.key", .{object_dir});
        const previous_key = Directory.cwd().readFileAlloc(engine.input_output, cache_manifest, engine.allocator, .limited(256)) catch "";
        if (try engine.customCacheKey(command.items, artifact, cache_inputs.items)) |digest| {
            if (same(previous_key, &digest)) {
                std.debug.print("up to date: {s}\n", .{name});
                try engine.artifacts.put(engine.allocator, name, artifact);
                return artifact;
            }
        }
        Directory.cwd().deleteFile(engine.input_output, cache_manifest) catch {};
        Directory.cwd().deleteFile(engine.input_output, temporary) catch {};
        try engine.invoke(command.items);
        _ = Directory.cwd().statFile(engine.input_output, temporary, .{}) catch return error.CustomCompilerProducedNoOutput;
        try Directory.cwd().rename(temporary, Directory.cwd(), artifact, engine.input_output);
        if (try engine.customCacheKey(command.items, artifact, cache_inputs.items)) |digest| {
            try Directory.cwd().writeFile(engine.input_output, .{ .sub_path = cache_manifest, .data = &digest });
        }
        std.debug.print("built {s}\n", .{artifact});
        try engine.artifacts.put(engine.allocator, name, artifact);

        const command_record = try std.fmt.allocPrint(engine.allocator, "{s}/custom-command.txt", .{object_dir});
        var record: std.ArrayList(u8) = .empty;
        for (command.items) |argument| {
            try record.appendSlice(engine.allocator, argument);
            try record.append(engine.allocator, '\n');
        }
        try Directory.cwd().writeFile(engine.input_output, .{ .sub_path = command_record, .data = record.items });
        return artifact;
    }

    fn appendCustomArguments(engine: *Engine, command: *std.ArrayList([]const u8), template: []const u8, values: []const []const u8, replace_library: bool) !void {
        if (replace_library and std.mem.indexOf(u8, template, "{lib}") != null) {
            for (values) |value| try engine.appendCustomTemplate(command, template, value);
            return;
        }
        try engine.appendCustomTemplate(command, template, null);
        try command.appendSlice(engine.allocator, values);
    }

    fn appendCustomTemplate(engine: *Engine, command: *std.ArrayList([]const u8), template: []const u8, replacement: ?[]const u8) !void {
        var words = std.mem.tokenizeAny(u8, template, " \t\r\n");
        while (words.next()) |word| {
            if (replacement) |value| {
                try command.append(engine.allocator, try replaceAll(engine.allocator, word, "{lib}", value));
            } else try command.append(engine.allocator, word);
        }
    }

    fn customCacheKey(engine: *Engine, command: []const []const u8, artifact: []const u8, inputs: []const []const u8) !?[32]u8 {
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        digest.update(&engine.environment_digest);
        for (command) |argument| {
            digest.update(argument);
            digest.update(&.{0});
        }
        const compiler_bytes = try engine.readExecutable(command[0]) orelse return null;
        digest.update(compiler_bytes);
        for (inputs) |path| {
            digest.update(path);
            digest.update(&.{0});
            const content = Directory.cwd().readFileAlloc(engine.input_output, path, engine.allocator, .limited(512 * 1024 * 1024)) catch return null;
            digest.update(content);
        }
        const output = Directory.cwd().readFileAlloc(engine.input_output, artifact, engine.allocator, .limited(512 * 1024 * 1024)) catch return null;
        digest.update(output);
        return digest.finalResult();
    }

    fn readExecutable(engine: *Engine, executable: []const u8) !?[]const u8 {
        if (std.mem.indexOfAny(u8, executable, "/\\") != null) {
            return Directory.cwd().readFileAlloc(engine.input_output, executable, engine.allocator, .limited(512 * 1024 * 1024)) catch null;
        }
        const environment = engine.environment orelse return null;
        const search_path = environment.get("PATH") orelse return null;
        var directories = std.mem.splitScalar(u8, search_path, if (builtin.os.tag == .windows) ';' else ':');
        while (directories.next()) |directory| {
            const candidate = try std.fs.path.join(engine.allocator, &.{ if (directory.len == 0) "." else directory, executable });
            if (Directory.cwd().readFileAlloc(engine.input_output, candidate, engine.allocator, .limited(512 * 1024 * 1024)) catch null) |content| return content;
        }
        return null;
    }

    fn driver(engine: *Engine, compiler: []const u8, cpp: bool) !std.ArrayList([]const u8) {
        var command: std.ArrayList([]const u8) = .empty;
        if (same(compiler, "builtIn") or same(compiler, "zig")) {
            try command.appendSlice(engine.allocator, &.{ "zig", if (cpp) "c++" else "cc" });
        } else try command.append(engine.allocator, if (same(compiler, "gcc")) (if (cpp) "g++" else "gcc") else (if (cpp) "clang++" else "clang"));
        if (engine.target_triple) |triple| {
            if (same(compiler, "gcc")) return error.GccCrossDriverRequired;
            const translated = if (same(command.items[0], "zig")) try zigTriple(engine.allocator, triple) else triple;
            try command.appendSlice(engine.allocator, &.{ "-target", translated });
        }
        return command;
    }

    fn buildTarget(engine: *Engine, target: *Call) anyerror![]const u8 {
        const name = try text(target.arguments[0]);
        if (engine.artifacts.get(name)) |artifact| return artifact;
        if (engine.visiting.contains(name)) return error.CircularTargetDependency;
        try engine.visiting.put(engine.allocator, name, {});
        defer _ = engine.visiting.remove(name);
        const is_library = same(try text(target.arguments[1]), "staticLibrary");
        var libraries: std.ArrayList([]const u8) = .empty;
        var sources: std.ArrayList([]const u8) = .empty;
        var headers: std.ArrayList([]const u8) = .empty;
        var includes: std.ArrayList([]const u8) = .empty;
        var flags: std.ArrayList([]const u8) = .empty;
        for (target.body) |statement| {
            const section = try child(statement);
            if (same(section.name, "use")) {
                const dependency = engine.targets.get(try first(section)) orelse return error.UnknownTargetDependency;
                if (!same(try text(dependency.arguments[1]), "staticLibrary")) return error.DependencyMustBeLibrary;
                if (is_library) return error.LibraryDependencyPropagationNotImplemented;
                try libraries.append(engine.allocator, try engine.buildTarget(dependency));
                continue;
            }
            if (same(section.name, "includeDirectory")) {
                try appendUnique(engine.allocator, &includes, try first(section));
                continue;
            }
            if (same(section.name, "define")) {
                try flags.append(engine.allocator, try std.fmt.allocPrint(engine.allocator, "-D{s}", .{try first(section)}));
                continue;
            }
            if (!same(section.name, "source")) return error.UnknownTargetSetting;
            const role = try first(section);
            if (!same(role, "implementation") and !same(role, "header")) return error.UnknownSourceRole;
            for (section.body) |entry| {
                if (entry != .value) return error.ExpectedSourcePath;
                const pattern = try text(entry.value);
                var matches: std.ArrayList([]const u8) = .empty;
                try engine.expand(pattern, &matches);
                for (matches.items) |filename| {
                    if (same(role, "implementation")) {
                        try appendUnique(engine.allocator, &sources, filename);
                    } else {
                        try appendUnique(engine.allocator, &headers, filename);
                        try appendUnique(engine.allocator, &includes, std.fs.path.dirname(filename) orelse ".");
                    }
                }
            }
        }
        if (sources.items.len == 0) return error.NoImplementationSources;
        const triple = engine.target_triple orelse if (builtin.os.tag == .macos)
            try std.fmt.allocPrint(engine.allocator, "{s}-apple-darwin", .{@tagName(builtin.cpu.arch)})
        else
            try std.fmt.allocPrint(engine.allocator, "{s}-unknown-{s}-{s}", .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), @tagName(builtin.abi) });
        if (std.mem.indexOfAny(u8, triple, "/\\") != null) return error.InvalidTargetTriple;
        const base = try std.fmt.allocPrint(engine.allocator, "build/{s}/{s}", .{ triple, engine.profile });
        const object_dir = try std.fmt.allocPrint(engine.allocator, "{s}/intermediate/{s}", .{ base, name });
        const output_dir = try std.fmt.allocPrint(engine.allocator, "{s}/out", .{base});
        try Directory.cwd().createDirPath(engine.input_output, object_dir);
        try Directory.cwd().createDirPath(engine.input_output, output_dir);
        try Directory.cwd().writeFile(engine.input_output, .{
            .sub_path = try std.fmt.allocPrint(engine.allocator, "{s}/.flux-managed", .{base}),
            .data = "flux-v1\n",
        });
        var has_native_source = false;
        var has_custom_source = false;
        for (sources.items) |source| {
            const extension = std.fs.path.extension(source);
            if (same(extension, ".c") or same(extension, ".cpp") or same(extension, ".cc") or same(extension, ".cxx")) {
                has_native_source = true;
            } else {
                has_custom_source = true;
            }
        }
        if (has_custom_source) {
            if (has_native_source) return error.MixedCustomLanguageTargetNotImplemented;
            const definition = engine.custom_compiler orelse return error.UnknownSourceLanguage;
            return engine.buildCustomTarget(name, is_library, definition, sources.items, headers.items, libraries.items, object_dir, output_dir);
        }
        var objects: std.ArrayList([]const u8) = .empty;
        var tasks: std.ArrayList(CompileTask) = .empty;
        var has_cpp = false;
        for (sources.items) |source| {
            const extension = std.fs.path.extension(source);
            const cpp = same(extension, ".cpp") or same(extension, ".cc") or same(extension, ".cxx");
            if (!cpp and !same(extension, ".c")) return error.UnknownSourceLanguage;
            has_cpp = has_cpp or cpp;
            var source_digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(source, &source_digest, .{});
            const source_key = std.fmt.bytesToHex(source_digest[0..16], .lower);
            const object = try std.fmt.allocPrint(engine.allocator, "{s}/{s}.o", .{ object_dir, source_key });
            var command = try engine.driver(if (cpp) engine.compiler_cxx else engine.compiler_c, cpp);
            try command.appendSlice(engine.allocator, &.{ if (same(engine.profile, "release")) "-O3" else "-O0", "-c", source, "-o", object });
            const depfile = try std.fmt.allocPrint(engine.allocator, "{s}.d", .{object});
            try command.appendSlice(engine.allocator, &.{ "-MD", "-MF", depfile });
            const current = try std.process.currentPathAlloc(engine.input_output, engine.allocator);
            try command.append(engine.allocator, try std.fmt.allocPrint(engine.allocator, "-ffile-prefix-map={s}=.", .{current}));
            if (engine.standard) |standard| {
                if (cpp) try command.append(engine.allocator, try std.fmt.allocPrint(engine.allocator, "-std=c++{d}", .{standard}));
            }
            for (includes.items) |include| try command.appendSlice(engine.allocator, &.{ "-I", include });
            try command.appendSlice(engine.allocator, flags.items);
            try tasks.append(engine.allocator, .{ .engine = engine, .command = command.items, .object = object, .depfile = depfile });
            try objects.append(engine.allocator, object);
        }
        var task_index: usize = 0;
        while (task_index < tasks.items.len) {
            const batch_end = @min(tasks.items.len, task_index + engine.jobs);
            var group: std.Io.Group = .init;
            defer group.cancel(engine.input_output);
            for (tasks.items[task_index..batch_end]) |*task| {
                group.concurrent(engine.input_output, CompileTask.perform, .{task}) catch {
                    task.perform();
                };
            }
            try group.await(engine.input_output);
            for (tasks.items[task_index..batch_end]) |task| if (task.failure) |failure| return failure;
            task_index = batch_end;
        }
        const artifact = try std.fmt.allocPrint(engine.allocator, "{s}/{s}{s}{s}", .{ output_dir, if (is_library) "lib" else "", name, if (is_library) ".a" else if (builtin.os.tag == .windows and engine.target_triple == null) ".exe" else "" });
        const temporary = try std.fmt.allocPrint(engine.allocator, "{s}.pending", .{artifact});
        var link = try engine.driver(if (has_cpp) engine.compiler_cxx else engine.compiler_c, has_cpp);
        // Native macOS uses the SDK's runtime rather than rebuilding libc++.
        if (!is_library and has_cpp and builtin.os.tag == .macos and engine.target_triple == null and same(link.items[0], "zig")) {
            const sdk = try std.process.run(engine.allocator, engine.input_output, .{ .argv = &.{ "xcrun", "--show-sdk-path" }, .environ_map = engine.environment });
            if (sdk.term != .exited or sdk.term.exited != 0) return error.MissingMacSdk;
            const runtime = try std.fs.path.join(engine.allocator, &.{ std.mem.trim(u8, sdk.stdout, "\r\n"), "usr/lib/libc++.tbd" });
            try link.append(engine.allocator, "-nostdlib++");
            try objects.append(engine.allocator, runtime);
        }
        if (is_library) {
            link.clearRetainingCapacity();
            try link.appendSlice(engine.allocator, &.{ "zig", "ar", "rcs", temporary });
            try link.appendSlice(engine.allocator, objects.items);
        } else {
            try link.appendSlice(engine.allocator, objects.items);
            try link.appendSlice(engine.allocator, libraries.items);
            try link.appendSlice(engine.allocator, &.{ "-o", temporary });
        }
        try objects.appendSlice(engine.allocator, libraries.items);
        const link_dependencies = try std.fmt.allocPrint(engine.allocator, "{s}/link.d", .{object_dir});
        var dependency_text: std.ArrayList(u8) = .empty;
        try dependency_text.appendSlice(engine.allocator, "flux: ");
        for (objects.items) |object| {
            for (object) |character| {
                if (character == ' ' or character == '\\') try dependency_text.append(engine.allocator, '\\');
                try dependency_text.append(engine.allocator, character);
            }
            try dependency_text.append(engine.allocator, ' ');
        }
        try Directory.cwd().writeFile(engine.input_output, .{ .sub_path = link_dependencies, .data = dependency_text.items });
        const link_manifest = try std.fmt.allocPrint(engine.allocator, "{s}/link.key", .{object_dir});
        const previous_link = Directory.cwd().readFileAlloc(engine.input_output, link_manifest, engine.allocator, .limited(256)) catch "";
        if (try engine.cacheKey(link.items, artifact, link_dependencies)) |digest| {
            if (same(previous_link, &digest)) {
                std.debug.print("up to date: {s}\n", .{name});
                try engine.artifacts.put(engine.allocator, name, artifact);
                return artifact;
            }
        }
        if (is_library) Directory.cwd().deleteFile(engine.input_output, temporary) catch {};
        try engine.invoke(link.items);
        try Directory.cwd().rename(temporary, Directory.cwd(), artifact, engine.input_output);
        if (try engine.cacheKey(link.items, artifact, link_dependencies)) |digest| {
            try Directory.cwd().writeFile(engine.input_output, .{ .sub_path = link_manifest, .data = &digest });
        }
        std.debug.print("built {s}\n", .{artifact});
        try engine.artifacts.put(engine.allocator, name, artifact);
        return artifact;
    }

    fn invoke(engine: *Engine, command: []const []const u8) !void {
        const result = try std.process.run(engine.allocator, engine.input_output, .{ .argv = command, .environ_map = engine.environment, .stdout_limit = .limited(8 * 1024 * 1024), .stderr_limit = .limited(8 * 1024 * 1024) });
        if (result.stdout.len != 0) std.debug.print("{s}", .{try engine.sanitize(result.stdout)});
        if (result.stderr.len != 0) std.debug.print("{s}", .{try engine.sanitize(result.stderr)});
        if (result.term != .exited or result.term.exited != 0) return error.CompilerFailed;
    }

    fn sanitize(engine: *Engine, message: []const u8) ![]const u8 {
        var output: std.ArrayList(u8) = .empty;
        var cursor: usize = 0;
        while (cursor < message.len) {
            if (message[cursor] == '/' and (cursor == 0 or !std.ascii.isAlphanumeric(message[cursor - 1]) or (cursor >= 2 and message[cursor - 2] == '-'))) {
                var end = cursor;
                while (end < message.len and std.mem.indexOfScalar(u8, " \t\r\n'\"():", message[end]) == null) : (end += 1) {}
                try output.appendSlice(engine.allocator, std.fs.path.basename(message[cursor..end]));
                cursor = end;
            } else {
                try output.append(engine.allocator, message[cursor]);
                cursor += 1;
            }
        }
        return output.toOwnedSlice(engine.allocator);
    }

    fn cachedInvoke(engine: *Engine, command: []const []const u8, object: []const u8, depfile: []const u8) !void {
        var source_name: []const u8 = std.fs.path.basename(object);
        for (command, 0..) |argument, index| {
            if (same(argument, "-c") and index + 1 < command.len) source_name = command[index + 1];
        }
        var scan: std.ArrayList([]const u8) = .empty;
        var argument_index: usize = 0;
        while (argument_index < command.len) : (argument_index += 1) {
            const argument = command[argument_index];
            if (same(argument, "-o") or same(argument, "-MF")) {
                argument_index += 1;
            } else if (!same(argument, "-c") and !same(argument, "-MD")) {
                try scan.append(engine.allocator, argument);
            }
        }
        try scan.appendSlice(engine.allocator, &.{ "-M", "-MT", "flux" });
        const dependencies = try std.process.run(engine.allocator, engine.input_output, .{ .argv = scan.items, .environ_map = engine.environment, .stdout_limit = .limited(8 * 1024 * 1024), .stderr_limit = .limited(8 * 1024 * 1024) });
        if (dependencies.term != .exited or dependencies.term.exited != 0) {
            std.debug.print("{s}", .{try engine.sanitize(dependencies.stderr)});
            return error.DependencyScanFailed;
        }
        try Directory.cwd().writeFile(engine.input_output, .{ .sub_path = depfile, .data = dependencies.stdout });
        const manifest = try std.fmt.allocPrint(engine.allocator, "{s}.key", .{object});
        const previous = Directory.cwd().readFileAlloc(engine.input_output, manifest, engine.allocator, .limited(256)) catch "";
        const before = try engine.cacheKey(command, object, depfile);
        if (before) |digest| {
            if (same(previous, &digest)) {
                std.debug.print("cached {s}\n", .{std.fs.path.basename(source_name)});
                return;
            }
        }
        // A failed compiler may leave partial output; its prior key cannot be reused.
        Directory.cwd().deleteFile(engine.input_output, manifest) catch {};
        const input_before = (try engine.cacheKey(command, "", depfile)) orelse return error.MissingDependency;
        try engine.invoke(command);
        const input_after = (try engine.cacheKey(command, "", depfile)) orelse return error.InputChangedDuringBuild;
        if (!std.mem.eql(u8, &input_before, &input_after)) return error.InputChangedDuringBuild;
        std.debug.print("compiled {s}\n", .{std.fs.path.basename(source_name)});
        if (try engine.cacheKey(command, object, depfile)) |digest| {
            try Directory.cwd().writeFile(engine.input_output, .{ .sub_path = manifest, .data = &digest });
        }
    }

    fn cacheKey(engine: *Engine, command: []const []const u8, object: []const u8, depfile: []const u8) !?[32]u8 {
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        digest.update(&engine.environment_digest);
        for (command) |argument| {
            digest.update(argument);
            digest.update(&.{0});
        }
        const version = engine.versions.get(command[0]) orelse version_block: {
            const result = try std.process.run(engine.allocator, engine.input_output, .{ .argv = &.{ command[0], if (same(command[0], "zig")) "version" else "--version" }, .environ_map = engine.environment });
            if (result.term != .exited or result.term.exited != 0) return error.CompilerVersionFailed;
            try engine.versions.put(engine.allocator, command[0], result.stdout);
            break :version_block result.stdout;
        };
        digest.update(version);
        if (object.len != 0) {
            const object_bytes = Directory.cwd().readFileAlloc(engine.input_output, object, engine.allocator, .limited(128 * 1024 * 1024)) catch return null;
            digest.update(object_bytes);
        }
        const dependencies = Directory.cwd().readFileAlloc(engine.input_output, depfile, engine.allocator, .limited(8 * 1024 * 1024)) catch return null;
        const separator = std.mem.indexOf(u8, dependencies, ": ") orelse return null;
        var cursor = separator + 2;
        var filename: std.ArrayList(u8) = .empty;
        while (cursor <= dependencies.len) : (cursor += 1) {
            if (cursor < dependencies.len and dependencies[cursor] == '\\' and cursor + 1 < dependencies.len) {
                cursor += 1;
                if (dependencies[cursor] != '\n') try filename.append(engine.allocator, dependencies[cursor]);
            } else if (cursor == dependencies.len or std.ascii.isWhitespace(dependencies[cursor])) {
                if (filename.items.len != 0) {
                    const content = Directory.cwd().readFileAlloc(engine.input_output, filename.items, engine.allocator, .limited(128 * 1024 * 1024)) catch return null;
                    digest.update(filename.items);
                    digest.update(&.{0});
                    digest.update(content);
                    digest.update(&.{0});
                    filename.clearRetainingCapacity();
                }
            } else try filename.append(engine.allocator, dependencies[cursor]);
        }
        return digest.finalResult();
    }

    fn expand(engine: *Engine, pattern: []const u8, matches: *std.ArrayList([]const u8)) !void {
        if (std.mem.indexOfAny(u8, pattern, "*?") == null) {
            _ = try Directory.cwd().statFile(engine.input_output, pattern, .{});
            try matches.append(engine.allocator, pattern);
            return;
        }
        const wildcard = std.mem.indexOfAny(u8, pattern, "*?").?;
        const separator = std.mem.lastIndexOfScalar(u8, pattern[0..wildcard], '/');
        const parent = if (separator) |position| (if (position == 0) "/" else pattern[0..position]) else ".";
        const mask = if (separator) |position| pattern[position + 1 ..] else pattern;
        var directory = try Directory.cwd().openDir(engine.input_output, parent, .{ .iterate = true });
        defer directory.close(engine.input_output);
        var iterator = try directory.walk(engine.allocator);
        defer iterator.deinit();
        while (try iterator.next(engine.input_output)) |entry| {
            if (entry.kind != .file) continue;
            if (globPath(mask, entry.path)) try matches.append(engine.allocator, try std.fs.path.join(engine.allocator, &.{ parent, entry.path }));
        }
        if (matches.items.len == 0) return error.SourcePatternMatchedNothing;
        std.mem.sort([]const u8, matches.items, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.less);
    }
};

fn argumentPosition(value: syntax.Value) !usize {
    const argument = switch (value) {
        .call => |call| call,
        else => return error.ExpectedArgumentPosition,
    };
    if (!same(argument.name, "argument") or argument.arguments.len != 1 or argument.arguments[0] != .number) return error.ExpectedArgumentPosition;
    const position = argument.arguments[0].number;
    if (position == 0 or position > 1024) return error.InvalidArgumentPosition;
    return position;
}

fn optimizationForProfile(setting: *Call, profile: []const u8) ![]const u8 {
    const wanted = if (same(profile, "release")) "max" else "none";
    for (setting.body) |statement| {
        const option = try child(statement);
        if (same(option.name, wanted)) return first(option);
    }
    return error.MissingOptimizationProfile;
}

fn replaceAll(allocator: Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, input, cursor, needle)) |position| {
        try result.appendSlice(allocator, input[cursor..position]);
        try result.appendSlice(allocator, replacement);
        cursor = position + needle.len;
    }
    try result.appendSlice(allocator, input[cursor..]);
    return result.toOwnedSlice(allocator);
}

fn zigTriple(allocator: Allocator, triple: []const u8) ![]const u8 {
    var components = std.mem.splitScalar(u8, triple, '-');
    const architecture = components.next() orelse return error.InvalidTargetTriple;
    const vendor = components.next() orelse return error.InvalidTargetTriple;
    const operating_system = components.next() orelse return error.InvalidTargetTriple;
    const abi = components.next();
    if (components.next() != null) return error.InvalidTargetTriple;
    if (same(vendor, "apple") and same(operating_system, "darwin")) return std.fmt.allocPrint(allocator, "{s}-macos", .{architecture});
    if (abi) |calling_convention| return std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ architecture, operating_system, calling_convention });
    return triple;
}

const CompileTask = struct {
    engine: *Engine,
    command: []const []const u8,
    object: []const u8,
    depfile: []const u8,
    failure: ?anyerror = null,

    fn perform(task: *CompileTask) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var worker = Engine{
            .allocator = arena.allocator(),
            .input_output = task.engine.input_output,
            .environment_digest = task.engine.environment_digest,
            .environment = task.engine.environment,
        };
        worker.cachedInvoke(task.command, task.object, task.depfile) catch |failure| {
            task.failure = failure;
        };
    }
};

fn appendUnique(allocator: Allocator, list: *std.ArrayList([]const u8), item: []const u8) !void {
    for (list.items) |existing| if (same(existing, item)) return;
    try list.append(allocator, item);
}

pub fn glob(pattern: []const u8, candidate: []const u8) bool {
    var pattern_index: usize = 0;
    var candidate_index: usize = 0;
    var star: ?usize = null;
    var restart: usize = 0;
    while (candidate_index < candidate.len) {
        if (pattern_index < pattern.len and (pattern[pattern_index] == '?' or pattern[pattern_index] == candidate[candidate_index])) {
            pattern_index += 1;
            candidate_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star = pattern_index;
            pattern_index += 1;
            restart = candidate_index;
        } else if (star) |position| {
            pattern_index = position + 1;
            restart += 1;
            candidate_index = restart;
        } else return false;
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

pub fn globPath(pattern: []const u8, candidate: []const u8) bool {
    const pattern_separator = std.mem.indexOfScalar(u8, pattern, '/');
    const candidate_separator = std.mem.indexOfScalar(u8, candidate, '/');
    const segment = pattern[0 .. pattern_separator orelse pattern.len];
    if (same(segment, "**")) {
        if (pattern_separator == null) return true;
        const rest = pattern[pattern_separator.? + 1 ..];
        if (globPath(rest, candidate)) return true;
        if (candidate_separator) |position| return globPath(pattern, candidate[position + 1 ..]);
        return false;
    }
    if (!glob(segment, candidate[0 .. candidate_separator orelse candidate.len])) return false;
    if (pattern_separator == null or candidate_separator == null) return pattern_separator == null and candidate_separator == null;
    return globPath(pattern[pattern_separator.? + 1 ..], candidate[candidate_separator.? + 1 ..]);
}

test "recursive globs preserve directory boundaries" {
    try std.testing.expect(globPath("**/*.cpp", "main.cpp"));
    try std.testing.expect(globPath("**/*.cpp", "nested/deeper/main.cpp"));
    try std.testing.expect(!globPath("*.cpp", "nested/main.cpp"));
    try std.testing.expect(globPath("module?/**/*.c", "module1/deeper/main.c"));
}

test "source glob backtracking" {
    try std.testing.expect(glob("*.cpp", "file with spaces.cpp"));
    try std.testing.expect(glob("a*b?c", "abbbbc"));
    try std.testing.expect(!glob("*.c", "main.cpp"));
}
