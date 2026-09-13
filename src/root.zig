pub const diagnostic = @import("diagnostic.zig");
pub const syntax = @import("syntax.zig");
pub const build_engine = @import("build_engine.zig");

test {
    _ = build_engine;
    _ = diagnostic;
    _ = syntax;
}
