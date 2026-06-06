const std = @import("std");

/// Internal building blocks: token, ast, errors, scanner, compile.
pub const core = @import("core/root.zig");

pub const ast = core.ast;
pub const token = core.token;
pub const errors = core.errors;
pub const scanner = core.scanner;
/// AST → HIR: the desugared, Unicode-resolved IR handed to backends.
pub const hir = core.hir;

/// The execution engine: backend contract + agnostic operations + backends.
pub const engine = @import("engine/root.zig");

// The comptime/runtime AST-building layer. Aliased privately to avoid clashing
// with the `compile` *function* re-exported below.
const build = core.compile;

// ── Most-used surface, re-exported for convenience ────────────────────────────

pub const Ast = ast.Ast;
pub const Diagnostic = errors.Diagnostic;
pub const ErrorCode = errors.ErrorCode;
pub const Span = errors.Span;
pub const Error = build.Error;
pub const Outcome = build.Outcome;

// ── HIR surface ───────────────────────────────────────────────────────────────

pub const Hir = hir.Hir;
pub const HirOptions = hir.Options;
pub const CaseFold = hir.CaseFold;
/// Runtime: build a heap-allocated HIR from an AST (free with `freeHir`).
pub const buildHir = hir.buildAlloc;
/// Free a runtime-built HIR.
pub const freeHir = hir.deinitHir;
/// Comptime: build a HIR into ro_data, returning `.ok`/`.fail`.
pub const buildHirComptime = hir.buildComptime;

// ── Engine / backend-contract surface ─────────────────────────────────────────

pub const Engine = engine.Engine;
pub const verifyBackend = engine.verifyBackend;
pub const Backend = engine.backend;
pub const Match = engine.Match;
pub const Captures = engine.Captures;
pub const SearchOptions = engine.SearchOptions;

// ── Front door: the simplest way to use the engine ────────────────────────────

/// Runtime: compile a pattern into a heap-backed regex (free with `re.deinit()`).
/// On a bad pattern, returns `error.InvalidPattern` and fills the `Diagnostic`.
pub const compileRuntime = engine.compileRuntime;
/// Comptime: compile a pattern into a ro_data regex (a bad pattern is a compile error).
pub const compileComptime = engine.compileComptime;
pub const Compiled = engine.Compiled;

/// Runtime: build a heap-allocated AST (free with `Ast.deinit`).
pub const parse = build.parse;
/// Runtime: build, handing any diagnostic to a caller-supplied context.
pub const parseReporting = build.parseReporting;
/// Comptime: build into ro_data, returning `.ok`/`.fail`.
pub const parseComptime = build.parseComptime;
/// Comptime: build into ro_data, failing compilation on a bad pattern.
pub const compile = build.compile;
/// Storage-agnostic core: build into caller-owned `Buffers` (see scanner.zig).
pub const scan = scanner.scan;

test {
    std.testing.refAllDecls(core);
    std.testing.refAllDecls(engine);
}
