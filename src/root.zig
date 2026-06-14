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
/// ## Built-in backends & capability matrix
///
/// Pluggable backends, any of which can be passed to `compileRuntimeWith` /
/// `compileComptimeWith`. **`auto` is the default and is correct by construction:** it inspects
/// each pattern and routes it to a backend that supports it (and switches per search — bounded
/// backtracker vs. Pike VM for captures, eager vs. lazy DFA for spans). So you only need the
/// matrix below if you deliberately *pin* a non-`auto` backend; that is the contract you opt into:
///
/// | backend     | captures | comptime | accepts (beyond the universal limits below)            |
/// |-------------|----------|----------|-------------------------------------------------------|
/// | `auto`      | yes      | yes      | everything — routes to a capable backend internally   |
/// | `pikevm`    | yes      | yes      | every feature **except `\X`**; always O(input)        |
/// | `backtrack` | yes      | yes      | every feature **including `\X`**; **bounded input**   |
/// | `literal`   | no       | yes      | pure literals / literal alternations only             |
/// | `bytepike`  | no       | yes      | byte-lowerable (no `\X`/`\b`); reference executor      |
/// | `dfa`       | no       | **no**   | byte-lowerable + `\A`/`^` + **anchored-end** `$`/`\z`  |
/// | `edfa`      | no       | yes      | as `dfa`, frozen tables; bounded determinized state    |
///
/// **Universal limits (true of every backend, by design — routing decisions, not missing
/// features):**
///   * `\b`/`\B` (word boundary) and `\X` (grapheme) are *codepoint* properties: only the
///     **code-point** engines evaluate them (`\b`/`\B` on `pikevm`/`backtrack`; `\X` on
///     `backtrack` only). The byte DFAs (`dfa`/`edfa`/`bytepike`) **never** support them —
///     `auto` keeps such patterns on the code-point engines.
///   * A **mixed** `$` (a `text_end` in only some alternation branches, `a$|b`) runs on the Pike
///     VM. `(?m)` line anchors run on the **eager** DFA when non-prone (`(?m)^\w+`, `(?m)foo$`);
///     a *prone* `(?m)` (an unbounded run before the anchor, `(?m)\w+$`) and any `(?m)` on the
///     lazy DFA fall to the Pike VM (correct + linear there).
///   * Every backend is **leftmost-first** (byte-identical spans) and — except `backtrack` on
///     oversized input — **linear-time** (no catastrophic backtracking), pinned by
///     `engine/conformance.zig` and `engine/redos.zig`.
///
/// **Span-only** backends (`literal`/`bytepike`/`dfa`/`edfa`) locate `[start, end)` but do not
/// fill captures; asking one for captures is a `@compileError`. **`dfa` is runtime-only** (its
/// cache mutates while matching) — use `edfa`/`pikevm`/`auto` for comptime matching. Each
/// backend's module doc spells out precisely what it accepts and declines.
pub const backends = engine.backends;
/// Front-door pipeline options (`case_fold`, …), comptime-known on both paths.
pub const Options = engine.Options;

// ── Front door: the simplest way to use the engine ────────────────────────────

/// Runtime: compile a pattern into a heap-backed regex (free with `re.deinit()`).
/// On a bad pattern, returns `error.InvalidPattern` and fills the `Diagnostic`.
/// Uses the default `auto` backend.
pub const compileRuntime = engine.compileRuntime;
/// Comptime: compile a pattern into a ro_data regex (a bad pattern is a compile error).
pub const compileComptime = engine.compileComptime;
/// Runtime: compile with an explicit backend (`backends.pikevm`, `.literal`, …).
pub const compileRuntimeWith = engine.compileRuntimeWith;
/// Comptime: compile with an explicit backend.
pub const compileComptimeWith = engine.compileComptimeWith;
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
