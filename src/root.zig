const std = @import("std");

/// Internal building blocks: token, ast, errors, scanner, compile.
pub const core = @import("core");

pub const ast = core.ast;
pub const token = core.token;
pub const errors = core.errors;
pub const scanner = core.scanner;
/// AST → HIR: the desugared, Unicode-resolved IR handed to backends.
pub const hir = core.hir;

/// The execution engine: backend contract + agnostic operations + backends.
pub const engine = @import("engine");

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
/// | `literal`   | whole    | yes      | pure literals / literal alternations only (group 0)   |
/// | `bytepike`  | yes      | yes      | byte-lowerable (no `\X`; ASCII `\b`); reference executor |
/// | `dfa`       | no       | **no**   | byte-lowerable + `\A`/`^` + anchored-end `$`/`\z` + Unicode `\b` |
/// | `edfa`      | no       | yes      | as `dfa` (frozen tables, bounded state) + ASCII `\b` + non-prone `(?m)` |
/// | `onepass`   | yes      | yes      | provably one-pass, assertion-free patterns; anchored   |
///
/// **Universal limits (true of every backend, by design — routing decisions, not missing
/// features):**
///   * `\X` (grapheme) is `backtrack`-only — no other backend can consume a variable number of
///     code points per step. `\b`/`\B` (word boundary) runs on `pikevm`/`backtrack` (Unicode) and,
///     since 0.4.0, on the **byte DFAs**: the **eager** DFA bakes in **ASCII** `\b` (zero decode),
///     the **lazy** DFA carries **Unicode** `\b` via a decode-hybrid. `auto` routes a `\b` pattern
///     by a cached whole-input ASCII check (ASCII → eager, non-ASCII → lazy), and falls back to the
///     Pike VM for a *prone* `\b`, a *chained* `\b\b`, or `\b` combined with `$`/`(?m)`. (`bytepike`
///     evaluates ASCII `\b` too; it does **not** do `\X`.)
///   * A **mixed** `$` (a `text_end` in only some alternation branches, `a$|b`) runs on the Pike
///     VM. `(?m)` line anchors run on the **eager** DFA when non-prone (`(?m)^\w+`, `(?m)foo$`);
///     a *prone* `(?m)` (an unbounded run before the anchor, `(?m)\w+$`) and any `(?m)` on the
///     lazy DFA fall to the Pike VM (correct + linear there).
///   * Every backend is **leftmost-first** (byte-identical spans) and — except `backtrack` on
///     oversized input — **linear-time** (no catastrophic backtracking), pinned by
///     `engine/conformance.zig` and `engine/redos.zig`.
///
/// **Span-only** backends `dfa` and `edfa` locate `[start, end)` but do not fill captures; asking
/// one for captures is a `@compileError`. (`literal` and `bytepike` *do* fill captures — `literal`
/// only the whole match, since pure literals have no groups; `bytepike` full groups.) **`dfa` is
/// runtime-only** (its cache mutates while matching) — use `edfa`/`pikevm`/`auto` for comptime
/// matching. **`onepass`** is the *capture* fast path: a single deterministic thread fills the slots
/// in O(input) (no thread set) for a provably one-pass pattern — `auto` uses it for the anchored
/// capture fill after a DFA arm locates the span, and declines (→ Pike VM) anything not one-pass.
/// Each backend's module doc spells out precisely what it accepts and declines.
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
/// Runtime: build a heap-allocated AST with caller-chosen scan `Limits`.
pub const parseWith = build.parseWith;
/// Runtime: build, handing any diagnostic to a caller-supplied context.
pub const parseReporting = build.parseReporting;
/// Comptime: build into ro_data, returning `.ok`/`.fail`.
pub const parseComptime = build.parseComptime;
/// Comptime: build into ro_data with caller-chosen scan `Limits`.
pub const parseComptimeWith = build.parseComptimeWith;
/// Comptime: build into ro_data, failing compilation on a bad pattern.
pub const compile = build.compile;
/// Comptime: build into ro_data with caller-chosen scan `Limits`.
pub const compileWith = build.compileWith;
/// Storage-agnostic core: build into caller-owned `Buffers` (see scanner.zig).
pub const scan = scanner.scan;
/// Storage-agnostic core with caller-chosen scan `Limits` (see scanner.zig).
pub const scanWith = scanner.scanWith;
/// Tunable scan-time limits (currently the `{m,n}` repetition ceiling).
pub const Limits = scanner.Limits;
/// Default `{m,n}` repetition ceiling (see `Options.max_repetition`).
pub const default_max_repetition = scanner.default_max_repetition;

test {
    std.testing.refAllDecls(core);
    std.testing.refAllDecls(engine);
}
