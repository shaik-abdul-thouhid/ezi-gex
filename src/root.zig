const std = @import("std");

/// Internal building blocks: token, ast, errors, scanner.
pub const core = @import("core/root.zig");

pub const ast = core.ast;
pub const token = core.token;
pub const errors = core.errors;
pub const scanner = core.scanner;

// ── Most-used surface, re-exported for convenience ────────────────────────────

pub const Ast = ast.Ast;
pub const Diagnostic = errors.Diagnostic;
pub const ErrorCode = errors.ErrorCode;
pub const Span = errors.Span;

/// Runtime: parse into a heap-allocated AST (free with `Ast.deinit`).
pub const parse = scanner.parse;
/// Runtime: parse, handing any diagnostic to a caller-supplied context.
pub const parseReporting = scanner.parseReporting;
/// Comptime: parse into ro_data, returning `.ok`/`.fail`.
pub const parseComptime = scanner.parseComptime;
/// Comptime: parse into ro_data, failing compilation on a bad pattern.
pub const compile = scanner.compile;
/// Storage-agnostic core: parse into caller-owned `Buffers`.
pub const scan = scanner.scan;

test {
    std.testing.refAllDecls(core);
}
