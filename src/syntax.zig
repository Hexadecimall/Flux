const std = @import("std");

pub const Location = struct {
    offset: usize,
    line: usize,
    column: usize,
};

pub const TokenKind = enum {
    identifier,
    string,
    number,
    left_parenthesis,
    right_parenthesis,
    left_brace,
    right_brace,
    comma,
    end_of_file,
    invalid,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    location: Location,
};

pub const Lexer = struct {
    source: []const u8,
    cursor: usize = 0,
    line: usize = 1,
    column: usize = 1,

    pub fn next(lexer: *Lexer) Token {
        lexer.skipIgnored();
        const source_location = lexer.location();
        if (lexer.cursor == lexer.source.len) {
            return .{ .kind = .end_of_file, .text = "", .location = source_location };
        }

        const character = lexer.source[lexer.cursor];
        return switch (character) {
            '(' => lexer.single(.left_parenthesis),
            ')' => lexer.single(.right_parenthesis),
            '{' => lexer.single(.left_brace),
            '}' => lexer.single(.right_brace),
            ',' => lexer.single(.comma),
            '"' => lexer.stringToken(),
            '0'...'9' => lexer.numberToken(),
            'A'...'Z', 'a'...'z', '_' => lexer.identifierToken(),
            else => lexer.single(.invalid),
        };
    }

    fn skipIgnored(lexer: *Lexer) void {
        while (lexer.cursor < lexer.source.len) {
            switch (lexer.source[lexer.cursor]) {
                ' ', '\t', '\r', '\n' => lexer.advance(),
                '#' => {
                    while (lexer.cursor < lexer.source.len and lexer.source[lexer.cursor] != '\n') {
                        lexer.advance();
                    }
                },
                else => return,
            }
        }
    }

    fn stringToken(lexer: *Lexer) Token {
        const source_location = lexer.location();
        lexer.advance();
        const content_start = lexer.cursor;

        while (lexer.cursor < lexer.source.len) {
            if (lexer.source[lexer.cursor] == '"') {
                const content = lexer.source[content_start..lexer.cursor];
                lexer.advance();
                return .{ .kind = .string, .text = content, .location = source_location };
            }
            if (lexer.source[lexer.cursor] == '\\' and lexer.cursor + 1 < lexer.source.len) {
                lexer.advance();
            }
            lexer.advance();
        }

        return .{
            .kind = .invalid,
            .text = lexer.source[content_start - 1 ..],
            .location = source_location,
        };
    }

    fn numberToken(lexer: *Lexer) Token {
        const source_location = lexer.location();
        const start = lexer.cursor;
        while (lexer.cursor < lexer.source.len and std.ascii.isDigit(lexer.source[lexer.cursor])) {
            lexer.advance();
        }
        return .{ .kind = .number, .text = lexer.source[start..lexer.cursor], .location = source_location };
    }

    fn identifierToken(lexer: *Lexer) Token {
        const source_location = lexer.location();
        const start = lexer.cursor;
        while (lexer.cursor < lexer.source.len) {
            const character = lexer.source[lexer.cursor];
            if (!std.ascii.isAlphanumeric(character) and character != '_') break;
            lexer.advance();
        }
        return .{ .kind = .identifier, .text = lexer.source[start..lexer.cursor], .location = source_location };
    }

    fn single(lexer: *Lexer, kind: TokenKind) Token {
        const source_location = lexer.location();
        const start = lexer.cursor;
        lexer.advance();
        return .{ .kind = kind, .text = lexer.source[start..lexer.cursor], .location = source_location };
    }

    fn advance(lexer: *Lexer) void {
        if (lexer.source[lexer.cursor] == '\n') {
            lexer.line += 1;
            lexer.column = 1;
        } else {
            lexer.column += 1;
        }
        lexer.cursor += 1;
    }

    fn location(lexer: *const Lexer) Location {
        return .{ .offset = lexer.cursor, .line = lexer.line, .column = lexer.column };
    }
};

pub const Value = union(enum) {
    identifier: []const u8,
    string: []const u8,
    number: usize,
    call: *Call,
};

pub const Call = struct {
    name: []const u8,
    arguments: []const Value,
    body: []const Statement,
    location: Location,
};

pub const Statement = union(enum) {
    call: *Call,
    value: Value,
};

pub const Document = struct {
    calls: []const *Call,
};

pub const Issue = struct {
    message: []const u8,
    location: Location,
};

pub const ParseResult = union(enum) {
    document: Document,
    issue: Issue,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!ParseResult {
    var parser = Parser.init(allocator, source);
    return parser.parseDocument();
}

const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current: Token,
    issue: ?Issue = null,
    depth: usize = 0,

    fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var lexer = Lexer{ .source = source };
        const current = lexer.next();
        return .{
            .allocator = allocator,
            .lexer = lexer,
            .current = current,
        };
    }

    fn parseDocument(parser: *Parser) std.mem.Allocator.Error!ParseResult {
        var calls: std.ArrayList(*Call) = .empty;
        defer calls.deinit(parser.allocator);

        while (parser.current.kind != .end_of_file and parser.issue == null) {
            const call = try parser.parseCall();
            if (call) |parsed_call| try calls.append(parser.allocator, parsed_call);
        }

        if (parser.issue) |issue| return .{ .issue = issue };
        return .{ .document = .{ .calls = try calls.toOwnedSlice(parser.allocator) } };
    }

    fn parseCall(parser: *Parser) std.mem.Allocator.Error!?*Call {
        if (parser.depth >= 128) {
            parser.fail("declaration nesting exceeds 128 levels");
            return null;
        }
        parser.depth += 1;
        defer parser.depth -= 1;
        if (parser.current.kind != .identifier) {
            parser.fail("expected a declaration name");
            return null;
        }

        const name = parser.current.text;
        const location = parser.current.location;
        parser.advance();
        if (!parser.expect(.left_parenthesis, "expected '('")) return null;

        var arguments: std.ArrayList(Value) = .empty;
        defer arguments.deinit(parser.allocator);
        while (parser.current.kind != .right_parenthesis and parser.issue == null) {
            const value = try parser.parseValue();
            if (value) |parsed_value| try arguments.append(parser.allocator, parsed_value);
            if (parser.current.kind == .comma) {
                parser.advance();
            } else if (parser.current.kind != .right_parenthesis) {
                parser.fail("expected ',' or ')'");
            }
        }
        if (!parser.expect(.right_parenthesis, "expected ')'")) return null;

        var body: std.ArrayList(Statement) = .empty;
        defer body.deinit(parser.allocator);
        if (parser.current.kind == .left_brace) {
            parser.advance();
            while (parser.current.kind != .right_brace and
                parser.current.kind != .end_of_file and
                parser.issue == null)
            {
                if (parser.current.kind == .identifier) {
                    const child = try parser.parseCall();
                    if (child) |parsed_child| {
                        try body.append(parser.allocator, .{ .call = parsed_child });
                    }
                } else {
                    const value = try parser.parseValue();
                    if (value) |parsed_value| {
                        try body.append(parser.allocator, .{ .value = parsed_value });
                    }
                }
            }
            if (!parser.expect(.right_brace, "expected '}'")) return null;
        }

        const call = try parser.allocator.create(Call);
        call.* = .{
            .name = name,
            .arguments = try arguments.toOwnedSlice(parser.allocator),
            .body = try body.toOwnedSlice(parser.allocator),
            .location = location,
        };
        return call;
    }

    fn parseValue(parser: *Parser) std.mem.Allocator.Error!?Value {
        return switch (parser.current.kind) {
            .string => try parser.consumeStringValue(),
            .number => parser.consumeNumberValue(),
            .identifier => identifier_value: {
                const saved_lexer = parser.lexer;
                const saved_token = parser.current;
                parser.advance();
                if (parser.current.kind == .left_parenthesis) {
                    parser.lexer = saved_lexer;
                    parser.current = saved_token;
                    const nested_call = try parser.parseCall();
                    break :identifier_value if (nested_call) |call| Value{ .call = call } else null;
                }
                break :identifier_value Value{ .identifier = saved_token.text };
            },
            else => {
                parser.fail("expected a value");
                return null;
            },
        };
    }

    fn consumeStringValue(parser: *Parser) std.mem.Allocator.Error!?Value {
        const content = parser.current.text;
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(parser.allocator);
        var index: usize = 0;
        while (index < content.len) : (index += 1) {
            var character = content[index];
            if (character == '\\') {
                index += 1;
                if (index == content.len) {
                    parser.fail("unterminated escape");
                    return null;
                }
                character = switch (content[index]) {
                    '\\' => '\\',
                    '"' => '"',
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => {
                        parser.fail("unknown string escape");
                        return null;
                    },
                };
            }
            try decoded.append(parser.allocator, character);
        }
        parser.advance();
        return .{ .string = try decoded.toOwnedSlice(parser.allocator) };
    }

    fn consumeNumberValue(parser: *Parser) ?Value {
        const number = std.fmt.parseInt(usize, parser.current.text, 10) catch {
            parser.fail("integer is too large");
            return null;
        };
        parser.advance();
        return .{ .number = number };
    }

    fn expect(parser: *Parser, kind: TokenKind, message: []const u8) bool {
        if (parser.current.kind != kind) {
            parser.fail(message);
            return false;
        }
        parser.advance();
        return true;
    }

    fn fail(parser: *Parser, message: []const u8) void {
        if (parser.issue == null) {
            parser.issue = .{ .message = message, .location = parser.current.location };
        }
    }

    fn advance(parser: *Parser) void {
        parser.current = parser.lexer.next();
    }
};

test "compiler definitions parse without recursive compiler declarations" {
    const source =
        \\definition(compiler) {
        \\    name("customCompiler")
        \\    executable("customcc")
        \\    language("customLanguage") {
        \\        implementation(argument(1), "")
        \\        header(argument(2), "-header")
        \\        library(argument(3), "-l {lib}")
        \\        optimization(argument(4)) {
        \\            none("-O0")
        \\            high("-O3")
        \\        }
        \\        output(argument(5), "-o")
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), source);
    switch (result) {
        .issue => |issue| {
            std.debug.print("unexpected issue at {d}:{d}: {s}\n", .{
                issue.location.line,
                issue.location.column,
                issue.message,
            });
            return error.UnexpectedParseIssue;
        },
        .document => |document| {
            try std.testing.expectEqual(@as(usize, 1), document.calls.len);
            try std.testing.expectEqualStrings("definition", document.calls[0].name);
            try std.testing.expectEqual(@as(usize, 3), document.calls[0].body.len);
        },
    }
}

test "preset and custom languages remain distinct values" {
    const source =
        \\project("Mixed") {
        \\    language(cxx) { compiler(zig) }
        \\    language("customLanguage") { compiler("customCompiler") }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), source);
    switch (result) {
        .issue => return error.UnexpectedParseIssue,
        .document => |document| {
            const project = document.calls[0];
            try std.testing.expectEqual(@as(usize, 2), project.body.len);
            try std.testing.expect(project.body[0] == .call);
            try std.testing.expect(project.body[1] == .call);
            try std.testing.expect(project.body[0].call.arguments[0] == .identifier);
            try std.testing.expect(project.body[1].call.arguments[0] == .string);
        },
    }
}

test "a project can select multiple languages and compilers" {
    const source =
        \\project("Mixed Languages") {
        \\    language(c) { compiler(clang) }
        \\    language(cxx) { compiler(zig) }
        \\    language("customLanguage") { compiler("customCompiler") }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), source);
    switch (result) {
        .issue => return error.UnexpectedParseIssue,
        .document => |document| {
            const project = document.calls[0];
            try std.testing.expectEqual(@as(usize, 3), project.body.len);
            try std.testing.expectEqualStrings("language", project.body[0].call.name);
            try std.testing.expectEqualStrings("language", project.body[1].call.name);
            try std.testing.expectEqualStrings("language", project.body[2].call.name);
        },
    }
}

test "source and yoink blocks accept bare file values" {
    const source =
        \\yoink() {
        \\    "compilers.flx"
        \\}
        \\source(implementation) {
        \\    "src/main.cpp"
        \\    "src/*.cpp"
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), source);
    switch (result) {
        .issue => return error.UnexpectedParseIssue,
        .document => |document| {
            try std.testing.expectEqual(@as(usize, 2), document.calls.len);
            try std.testing.expect(document.calls[0].body[0] == .value);
            try std.testing.expect(document.calls[1].body[0] == .value);
            try std.testing.expect(document.calls[1].body[1] == .value);
        },
    }
}

test "comments and nested argument calls parse" {
    const source =
        \\# compiler argument placement
        \\implementation(argument(1), "")
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), source);
    switch (result) {
        .issue => return error.UnexpectedParseIssue,
        .document => |document| {
            try std.testing.expectEqual(@as(usize, 2), document.calls[0].arguments.len);
            try std.testing.expect(document.calls[0].arguments[0] == .call);
        },
    }
}

test "oversized integer is rejected instead of becoming zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), "argument(99999999999999999999999999999999999999)");
    try std.testing.expect(result == .issue);
}

test "escaped quote is decoded in a string value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parse(arena.allocator(), "project(\"a\\\"b\")");
    try std.testing.expect(result == .document);
    try std.testing.expectEqualStrings("a\"b", result.document.calls[0].arguments[0].string);
}
