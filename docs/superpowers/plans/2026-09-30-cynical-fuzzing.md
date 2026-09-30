# Cynical Fuzzing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `fuzz/` into a suite that trusts nothing — an independent tree-driven reference matcher, metamorphic printing, dirty-scratch scripts, large/evil inputs, OOM injection, comptime parity, counter-based complexity checks — plus vacuity guards, a known-open ledger, and a `fuzz-min` delta-debugger; then run a campaign and hand back a findings report.

**Architecture:** A new `fuzz_lib` module (`fuzz/lib.zig`) holds generators (`gen/`), an independent reference matcher (`ref/`), and check bodies (`check/`); each fuzz group under `fuzz/groups/` stays a thin `test` block compiled into its own binary. Every check is split into `run(gpa, *const Case)` (deterministic, replayable) and `fuzzOne(void, *Smith)` (generate a `Case`, call `run`), so any failure prints a `FUZZ-CASE` line that `zig build fuzz-min` can replay and shrink.

**Tech Stack:** Zig `0.17.0-dev` (`zig` on PATH; this machine: `0.17.0-dev.2338+b46a7f3a2`), `std.testing.fuzz` + `std.testing.Smith`, `std.testing.checkAllAllocationFailures`, `ezi_gex` public API, `ezi_code` per-code-point predicates.

**Spec:** `docs/superpowers/specs/2026-09-30-cynical-fuzzing-design.md`

## Global Constraints

- **No engine/library changes.** Nothing under `src/` is edited; fixes are follow-ups the owner picks.
- **Never `std.unicode`** anywhere (workspace rule) — fuzz code decodes/encodes UTF-8 itself or via `ezi_code`.
- `ezi_code` is imported by exactly two modules: `utils` (library seam, unchanged) and `fuzz_lib` (reference predicates).
- **Commits:** Conventional Commits (`test(fuzz): …`, `build(fuzz): …`, `docs(fuzz): …`). **Never** a `Co-Authored-By` trailer or a "🤖 Generated with …" line.
- **Never stage** `src/main.zig` or `CLAUDE.md` (the owner's uncommitted work). Always `git add` explicit paths.
- Branch: `fuzz/cynical`.
- Finite smoke stays finite: `zig build test` replays seeds only. **Budget: the `fuzz` unit adds ≤ 30 s** to `zig build test -Doptimize=ReleaseSafe`.
- Every fuzz body starts with `@disableInstrumentation();` and does bounded work per iteration.
- **Options are comptime** in ezi_gex (`compileRuntimeWith(B, gpa, pat, &diag, comptime opts)`): a case picks an index into `common.opt_variants`; `compileVariant` dispatches with `inline` switch prongs.
- Semantics treated as spec (spec §4): leftmost-first; RE2/Rust empty-width loops (`(|a)*` on `"aaa"` → `""`); `$`≡`\z`≡`\Z` without `m`; `(?m)` on `\n` only; `.` excludes only `\n` unless `s`; `\d`=Nd, `\w`=Alphabetic∪M∪Nd∪Pc∪Join_Control, `\s`=White_Space; `unicode=false` → `\d`=`[0-9]`, `\w`=`[0-9A-Za-z_]`, `\s`=`[\t\n\v\f\r ]`, `\b` stays Unicode; dead-on-invalid input; `(?i)` simple folding: `c≡x` iff `caseFoldSimple(c)==caseFoldSimple(x)`; `case_fold=.none` ignores `(?i)`; `Script_Extensions` falls back to `Script`.
- Property names the scanner accepts: GC short/long names and groups (`L LC M N P S Z C` + long forms), DerivedCoreProperties names (`Alphabetic`, `Lowercase`, `Math`, …), and scripts **only** via `Script=`/`sc=`/`Script_Extensions=`/`scx=` prefixes. Bare script names (`\p{Greek}`) and `White_Space` are **rejected** (`unknown_property`).
- Scanner facts (probed): quantified assertions are legal (`^*`, `\b?`); `a**` is `multiple_quantifiers`; `{`, `}`, `]` alone are literals; `\#`, `\ ` are literal escapes; `\xHH` takes 0–2 hex digits and means the code point; `\cX` is case-insensitive.

## Review Focus

1. **`fuzz-min` on a case that does not reproduce** (truncated line, or a failure that depended on scratch history) → must print `does not reproduce` and exit non-zero, never "minimize" to garbage or loop. *Test: Task 28, Step 1.*
2. **Printer overflow** (a tree whose printed pattern exceeds the buffer) → `print` returns `null` and the case is skipped; a truncated pattern must never be matched. *Test: Task 6, Step 1.*
3. **`findAt` with `start` inside a multi-byte code point, on an invalid byte, at `input.len`, and `span_end < start`** → reference and checks return cleanly (no panic, no out-of-bounds). *Test: Task 8, Step 1 and Task 15, Step 3 (the "odd search options never panic" test).*
4. **A `FUZZ-CASE` line with a 12 KiB input and empty fields** (empty pattern, empty input, `span_end = null`) must round-trip `report → parse` byte-exactly. *Test: Task 2, Step 1.*
5. **A known-open gate whose predicate is too broad** silently disables a check → `health` must fail when any gate skips > 1 % of cases. *Test: Task 27, Step 1.*

## File Map

| Path | Responsibility |
|------|----------------|
| `build.zig` (modify) | `fuzz_lib` module, lib unit tests chained into the `fuzz` unit, 19 groups, `fuzz-min` step |
| `fuzz/lib.zig` (create) | `fuzz_lib` root: re-exports `gen`, `ref`, `check`; pulls in their unit tests |
| `fuzz/root.zig` (modify) | aggregate `fuzz` unit: every group's seed replay + `health` + `findings` + `threads` |
| `fuzz/gen/pattern.zig` (moved from `groups/pattern_smith.zig`) | string-level pattern generators (widened) |
| `fuzz/gen/input.zig` (create) | `genInput`, evil UTF-8, long inputs with plants, fold-swap |
| `fuzz/gen/props.zig` (create) | property-name table: two spellings + semantics + a sample code point |
| `fuzz/gen/tree.zig` (create) | semantic tree types, `Builder`, Smith generator, `nullable`, serialization |
| `fuzz/gen/print.zig` (create) | tree → pattern printer (canonical + randomized equivalent spellings) |
| `fuzz/gen/witness.zig` (create) | witness string sampler (validated by the reference) |
| `fuzz/gen/literals.zig` (create) | literal-set generator |
| `fuzz/ref/uni.zig` (create) | strict UTF-8 decode/encode, per-cp predicates, simple-fold orbits |
| `fuzz/ref/nfa.zig` (create) | tree → Thompson NFA (Rust `regex-automata` construction) |
| `fuzz/ref/pike.zig` (create) | naive Pike simulation with captures |
| `fuzz/ref/root.zig` (create) | `Ref` façade: `find`, `findAll` |
| `fuzz/ref/selfcheck.zig` (create) | reference vs pinned conformance semantics (finite) |
| `fuzz/check/common.zig` (create) | outcomes, backend lists, `\b` byte gate, `opt_variants`, `Stats`, `Case` |
| `fuzz/check/differential.zig` (moved from `groups/harness.zig`) | the existing seven groups' bodies |
| `fuzz/check/{reference,metamorphic,invariants,state,large,literals,api,oom,comptime_parity,complexity,utf8class,scanner,grapheme,chaos}.zig` (create) | one check each: `run` + `fuzzOne` |
| `fuzz/check/known_open.zig` (create) | known-open gates |
| `fuzz/check/registry.zig` (create) | `CheckId → run` table for `fuzz-min` |
| `fuzz/groups/*.zig` (modify + create) | thin fuzz targets, one binary each |
| `fuzz/health.zig` (create) | vacuity guards |
| `fuzz/findings.zig` (create) | known-open ledger |
| `fuzz/threads.zig` (create) | shared-`Program` multi-thread parity |
| `fuzz/min.zig` (create) | `fuzz-min` delta-debugger executable |
| `fuzz/README.md` (rewrite) | suite documentation |

Common commands used throughout (run from the repo root `ezi_gex/`):

```sh
zig build test-fuzz -Doptimize=ReleaseSafe      # fuzz unit: fuzz_lib unit tests + aggregate seed replay
zig build fuzz -Doptimize=ReleaseSafe           # finite smoke of every group binary, in parallel
zig build fuzz-<group> -Doptimize=ReleaseSafe --fuzz=200K   # real fuzzing of one group
```

---

## Phase A — Restructure and plumbing

### Task 1: Move the suite into a `fuzz_lib` module (pure move, no behavior change)

**Files:**
- Move: `fuzz/groups/harness.zig` → `fuzz/check/differential.zig`
- Move: `fuzz/groups/pattern_smith.zig` → `fuzz/gen/pattern.zig`
- Create: `fuzz/lib.zig`
- Modify: `fuzz/groups/{scanner,diff,anchors,unicode,captures,iter,search}.zig` (one import line each)
- Modify: `build.zig` (fuzz section)

**Interfaces:**
- Produces: module `fuzz_lib` exposing `gen.pattern`, `check.differential` (same `pub` decls as the old `harness.zig` / `pattern_smith.zig`). Group files import it as `@import("fuzz_lib")`.

- [ ] **Step 1: Record the baseline test count and time**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe --summary all 2>&1 | grep -E "tests? passed|run test"`
Expected: PASS; note the number of passing tests (the seven groups' `test` blocks). Keep it for Step 7.

Run: `rm -rf .zig-cache/o && time zig build test -Doptimize=ReleaseSafe`
Note the wall time in the commit message of this task as `baseline test time: <N>s` — Task 29 checks the ≤ 30 s budget against it.

- [ ] **Step 2: Move the files with history**

```sh
mkdir -p fuzz/check fuzz/gen fuzz/ref
git mv fuzz/groups/harness.zig fuzz/check/differential.zig
git mv fuzz/groups/pattern_smith.zig fuzz/gen/pattern.zig
```

- [ ] **Step 3: Fix the moved file's import**

In `fuzz/check/differential.zig` replace

```zig
const ps = @import("pattern_smith.zig");
```

with

```zig
const ps = @import("../gen/pattern.zig");
```

- [ ] **Step 4: Create `fuzz/lib.zig`**

```zig
//! `fuzz_lib` — everything the ezi_gex fuzz binaries share.
//!
//! Each fuzz group (`fuzz/groups/*.zig`) compiles into its OWN test binary so the groups
//! fuzz in parallel; they all import this one module for the generators (`gen`), the
//! independent reference matcher (`ref`), and the check bodies (`check`). The aggregate
//! `fuzz` unit (`fuzz/root.zig`) imports it too. Its own unit tests run as a separate
//! binary chained into `zig build test-fuzz`.

const std = @import("std");

pub const gen = struct {
    pub const pattern = @import("gen/pattern.zig");
};

pub const check = struct {
    pub const differential = @import("check/differential.zig");
};

test {
    _ = @import("gen/pattern.zig");
    _ = @import("check/differential.zig");
}
```

- [ ] **Step 5: Point the seven group files at `fuzz_lib`**

```sh
for g in scanner diff anchors unicode captures iter search; do
  sed -i '' 's#const h = @import("harness.zig");#const h = @import("fuzz_lib").check.differential;#' fuzz/groups/$g.zig
done
grep -n 'harness.zig' fuzz/groups/*.zig fuzz/root.zig || echo "no stale imports"
```

Expected: `no stale imports` (the doc comments in `fuzz/root.zig` mention `harness.zig` only in prose; update the two prose mentions to `check/differential.zig` by hand).

- [ ] **Step 6: Wire `fuzz_lib` in `build.zig`**

Replace the block that starts with `// ── fuzz: coverage-guided fuzz targets` and ends with the `fuzz_mod` declaration with:

```zig
    // ── fuzz: coverage-guided fuzz targets (Smith-driven) over the facade ──────
    // `fuzz_lib` (fuzz/lib.zig) holds what every fuzz binary shares: generators
    // (gen/), the independent reference matcher (ref/), and check bodies (check/).
    // It drives the published `ezi_gex` module exactly as a downstream user would,
    // and imports `ezi_code` DIRECTLY — the one module besides `utils` allowed to —
    // because the reference matcher must evaluate Unicode predicates per code point
    // without going through ezi_gex's own range tables (independence is its point).
    // The library itself still only sees `ezi_code` through `utils`.
    const fuzz_lib_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ezi_gex", .module = mod },
            .{ .name = "ezi_code", .module = ezi_code.module("ezi_code") },
        },
    });
    const fuzz_lib: std.Build.Module.Import = .{ .name = "fuzz_lib", .module = fuzz_lib_mod };
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ezi_gex", .module = mod }, fuzz_lib },
    });
```

After the line `const run_fuzz_tests = b.addRunArtifact(fuzz_tests);` add:

```zig
    // fuzz_lib's own unit tests (generators, reference matcher, check helpers) live in a
    // different module than the aggregate, so they are a separate binary — chained here so
    // `test-fuzz` / `-Dinclude-test=fuzz` runs both.
    const fuzz_lib_tests = b.addTest(.{ .root_module = fuzz_lib_mod });
    run_fuzz_tests.step.dependOn(&b.addRunArtifact(fuzz_lib_tests).step);
```

In the `for (fuzz_groups) |g|` loop, change the group module's imports to:

```zig
            .imports = &.{ .{ .name = "ezi_gex", .module = mod }, fuzz_lib },
```

and update the loop's comment `share the differential bodies in fuzz/groups/harness.zig` → `share the bodies in fuzz_lib (fuzz/lib.zig)`.

- [ ] **Step 7: Verify nothing changed behaviorally**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe --summary all 2>&1 | grep -E "tests? passed|run test"`
Expected: PASS with the same count as Step 1 (plus a `fuzz_lib` test binary with 0 tests).

Run: `zig build fuzz -Doptimize=ReleaseSafe`
Expected: exit 0, no output.

- [ ] **Step 8: Commit**

```sh
git add build.zig fuzz/lib.zig fuzz/check/differential.zig fuzz/gen/pattern.zig fuzz/groups/*.zig fuzz/root.zig
git commit -m "build(fuzz): move shared fuzz code into a fuzz_lib module" -m "baseline test time: <N>s (zig build test -Doptimize=ReleaseSafe, cold)"
```

---

### Task 2: `check/common.zig` — shared helpers, option variants, stats, replayable `Case`

**Files:**
- Create: `fuzz/check/common.zig`
- Create: `fuzz/gen/input.zig`
- Modify: `fuzz/check/differential.zig` (delete moved helpers, alias them, add stats notes)
- Modify: `fuzz/lib.zig`

**Interfaces:**
- Produces (in `common`):
  - `Outcome = union(enum){ invalid, skip, span: ?[2]usize }`, `spanEq(a, b) bool`
  - `all_backends` (tuple, 8), `n_backends = 8`, `backendIndex(comptime B) usize`, `backend_names: [8][]const u8`
  - `span_backends`, `capture_backends`, `iter_backends`, `replace_backends`, `offset_backends` (tuples, unchanged membership)
  - `isByteEngine(comptime B) bool`, `isAsciiStr([]const u8) bool`, `patternHasWordBoundary(gpa, []const u8) bool`, `byteEnginesSafe(gpa, pattern, input) bool`
  - `opt_variants: [6]gex.Options`, `compileVariant(comptime B, gpa, pattern, *gex.Diagnostic, opt: u8) anyerror!gex.Compiled(B)`
  - `CheckId` enum, `Stats`, `pub var stats: Stats`, `noteRun(CheckId, valid: bool)`, `noteCompared(CheckId, comptime B)`, `noteSkipped(CheckId, comptime B)`, `comparedFraction(CheckId, backend_index) f64`
  - `Case{ check, pattern, input, tree, template, opt, start, anchored, span_end, seed, n, opt2, seed2 }` with `searchOptions()`, `report(comptime why, args)`, `format(*std.Io.Writer)`, `parse(gpa, line) !Case`, `deinitOwned(gpa)`; `pub var quiet: bool`
- Produces (in `gen/input.zig`): `max_input_len = 64`, `genInput(*Smith, []u8) []const u8`

- [ ] **Step 1: Write the failing tests** (they live at the bottom of the new `fuzz/check/common.zig`; create the file with just these tests and the imports first)

```zig
const std = @import("std");
const gex = @import("ezi_gex");
const testing = std.testing;

test "Case report/parse round-trips byte-exactly (incl. 12 KiB input and empty fields)" {
    const gpa = testing.allocator;
    var big: [12 * 1024]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i *% 131 +% 7);
    const cases = [_]Case{
        .{ .check = .span, .pattern = "a|b", .input = "xab", .opt = 3, .start = 1, .anchored = true, .span_end = 3, .seed = 42, .n = 7, .template = "$1-${g}", .opt2 = 5, .seed2 = 99 },
        .{ .check = .large, .pattern = "", .input = &big },
        .{ .check = .reference, .pattern = "\xff\x00", .input = "", .tree = "\x01\x02\x03", .span_end = null },
    };
    for (cases) |c| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try c.format(&aw.writer);
        const back = try Case.parse(gpa, aw.written());
        defer back.deinitOwned(gpa);
        try testing.expectEqual(c.check, back.check);
        try testing.expectEqualSlices(u8, c.pattern, back.pattern);
        try testing.expectEqualSlices(u8, c.input, back.input);
        try testing.expectEqualSlices(u8, c.tree, back.tree);
        try testing.expectEqualSlices(u8, c.template, back.template);
        try testing.expectEqual(c.opt, back.opt);
        try testing.expectEqual(c.start, back.start);
        try testing.expectEqual(c.anchored, back.anchored);
        try testing.expectEqual(c.span_end, back.span_end);
        try testing.expectEqual(c.seed, back.seed);
        try testing.expectEqual(c.n, back.n);
        try testing.expectEqual(c.opt2, back.opt2);
        try testing.expectEqual(c.seed2, back.seed2);
    }
}

test "Case.parse rejects a truncated line" {
    try testing.expectError(error.BadCaseLine, Case.parse(testing.allocator, "FUZZ-CASE check=span opt=0 pat=61"));
    try testing.expectError(error.BadCaseLine, Case.parse(testing.allocator, "nonsense"));
}

test "compileVariant honours each option variant" {
    const gpa = testing.allocator;
    const P = gex.backends.pikevm;
    const Probe = struct { pat: []const u8, in: []const u8, opt: u8, want: bool };
    const probes = [_]Probe{
        .{ .pat = "a", .in = "A", .opt = 0, .want = false },
        .{ .pat = "a", .in = "A", .opt = 3, .want = true }, // case_insensitive via Options
        .{ .pat = "(?i)a", .in = "A", .opt = 2, .want = false }, // case_fold = .none ignores (?i)
        .{ .pat = "\\d", .in = "\u{0663}", .opt = 0, .want = true }, // Unicode \d
        .{ .pat = "\\d", .in = "\u{0663}", .opt = 1, .want = false }, // ASCII \d
        .{ .pat = "^b", .in = "a\nb", .opt = 4, .want = true }, // multiline via Options
        .{ .pat = "a.b", .in = "a\nb", .opt = 5, .want = true }, // dot_matches_newline via Options
    };
    for (probes) |p| {
        var diag: gex.Diagnostic = .{};
        var re = try compileVariant(P, gpa, p.pat, &diag, p.opt);
        defer re.deinit();
        var sc = try re.initScratch(gpa);
        defer sc.deinit(gpa);
        try testing.expectEqual(p.want, re.isMatch(&sc, p.in));
    }
}

test "stats count compared and skipped per check and backend" {
    stats.reset();
    noteRun(.span, true);
    noteCompared(.span, gex.backends.dfa);
    noteSkipped(.span, gex.backends.literal);
    try testing.expectEqual(@as(u32, 1), stats.compared[@intFromEnum(CheckId.span)][backendIndex(gex.backends.dfa)]);
    try testing.expectEqual(@as(u32, 1), stats.skipped[@intFromEnum(CheckId.span)][backendIndex(gex.backends.literal)]);
    try testing.expectEqual(@as(f64, 1.0), comparedFraction(.span, backendIndex(gex.backends.dfa)));
    stats.reset();
}
```

Add `_ = @import("check/common.zig");` to the `test {}` block of `fuzz/lib.zig` and `pub const common = @import("check/common.zig");` inside `pub const check`.

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile — `use of undeclared identifier 'Case'` (and `compileVariant`, `stats`, …).

- [ ] **Step 3: Implement `common.zig` above the tests**

```zig
//! Shared fuzz-check plumbing: outcomes, backend lists, the byte-engine ASCII-`\b` gate,
//! compile-option variants, per-check × per-backend comparison accounting (read by
//! `fuzz/health.zig`), and the replayable `Case` every failing check prints as one
//! `FUZZ-CASE …` line (read back by `zig build fuzz-min`).

const std = @import("std");
const gex = @import("ezi_gex");

// ══════════════════════════════════════════════════════════════════════════════
// Outcomes
// ══════════════════════════════════════════════════════════════════════════════

/// Per-backend match outcome.
pub const Outcome = union(enum) {
    /// Scanner/HIR rejected the pattern (deterministic — same parse for every backend).
    invalid,
    /// The backend declined this pattern (Unsupported) or a resource ceiling tripped.
    skip,
    /// Matched span, or `null` for no match.
    span: ?[2]usize,
};

pub fn spanEq(a: ?[2]usize, b: ?[2]usize) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?[0] == b.?[0] and a.?[1] == b.?[1];
}

// ══════════════════════════════════════════════════════════════════════════════
// Backends
// ══════════════════════════════════════════════════════════════════════════════

pub const all_backends = .{
    gex.backends.pikevm,  gex.backends.backtrack, gex.backends.auto,    gex.backends.bytepike,
    gex.backends.dfa,     gex.backends.edfa,      gex.backends.onepass, gex.backends.literal,
};
pub const n_backends = 8;
pub const backend_names = [n_backends][]const u8{ "pikevm", "backtrack", "auto", "bytepike", "dfa", "edfa", "onepass", "literal" };

pub fn backendIndex(comptime B: type) usize {
    inline for (all_backends, 0..) |X, i| {
        if (X == B) return i;
    }
    @compileError("backendIndex: unknown backend " ++ @typeName(B));
}

/// The backends compared against the Pike VM for plain `find`.
pub const span_backends = .{
    gex.backends.backtrack, gex.backends.auto, gex.backends.bytepike, gex.backends.dfa,
    gex.backends.edfa,      gex.backends.onepass, gex.backends.literal,
};
pub const capture_backends = .{ gex.backends.backtrack, gex.backends.auto, gex.backends.onepass, gex.backends.bytepike };
pub const iter_backends = .{ gex.backends.backtrack, gex.backends.auto, gex.backends.bytepike, gex.backends.dfa, gex.backends.edfa };
pub const replace_backends = .{ gex.backends.backtrack, gex.backends.auto, gex.backends.bytepike };
pub const offset_backends = .{ gex.backends.backtrack, gex.backends.auto, gex.backends.bytepike, gex.backends.dfa, gex.backends.edfa };

// ── Byte-engine ASCII-`\b` contract (mirrors conformance.byteEngineCanRunCase) ──
// `bytepike`/`dfa`/`edfa` evaluate `\b`/`\B` as ASCII word boundaries — exact on ASCII
// input; `auto` routes non-ASCII `\b` to the code-point engines. So a pinned byte engine
// is only contracted on ASCII input for a `\b` pattern, and the checks skip it otherwise.

pub fn isByteEngine(comptime B: type) bool {
    return B == gex.backends.bytepike or B == gex.backends.dfa or B == gex.backends.edfa;
}

pub fn isAsciiStr(s: []const u8) bool {
    for (s) |b| if (b >= 0x80) return false;
    return true;
}

/// True if `pattern` carries a `\b`/`\B` (via the HIR analysis flag). A parse/HIR
/// failure ⇒ false (then every backend agrees `.invalid` anyway).
pub fn patternHasWordBoundary(gpa: std.mem.Allocator, pattern: []const u8) bool {
    @disableInstrumentation();
    var diag: gex.Diagnostic = .{};
    const ast = gex.parse(gpa, pattern, &diag) catch return false;
    defer ast.deinit(gpa);
    const h = gex.buildHir(gpa, ast, .{}) catch return false;
    defer gex.freeHir(gpa, h);
    return h.analysis.has_word_boundary;
}

pub fn byteEnginesSafe(gpa: std.mem.Allocator, pattern: []const u8, input: []const u8) bool {
    @disableInstrumentation();
    if (isAsciiStr(input)) return true;
    return !patternHasWordBoundary(gpa, pattern);
}

// ══════════════════════════════════════════════════════════════════════════════
// Compile-option variants
// ══════════════════════════════════════════════════════════════════════════════

/// `Options` is a comptime parameter in ezi_gex, so a case carries an INDEX into this
/// table and `compileVariant` dispatches with `inline` prongs (one instantiation each).
/// Keep in sync with `gen/tree.zig`'s `opt_sem` (a comptime assertion in tree.zig checks).
pub const opt_variants = [_]gex.Options{
    .{}, // 0: defaults
    .{ .unicode = false }, // 1: ASCII \d \w \s
    .{ .case_fold = .none }, // 2: (?i) ignored
    .{ .case_insensitive = true }, // 3: i seeded from Options
    .{ .multiline = true }, // 4: m seeded from Options
    .{ .dot_matches_newline = true }, // 5: s seeded from Options
};

pub fn compileVariant(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, diag: *gex.Diagnostic, opt: u8) anyerror!gex.Compiled(B) {
    return switch (opt) {
        inline 0...opt_variants.len - 1 => |i| gex.compileRuntimeWith(B, gpa, pattern, diag, opt_variants[i]),
        else => error.BadOptionVariant,
    };
}

// ══════════════════════════════════════════════════════════════════════════════
// Accounting (read by fuzz/health.zig)
// ══════════════════════════════════════════════════════════════════════════════

pub const CheckId = enum(u8) {
    span, anchors, unicode, captures, iter, replace, offset, strategy, scanner, grapheme,
    reference, metamorphic, invariants, state, large, literals, api, oom, comptime_parity,
    complexity, utf8class, chaos,
};
pub const n_checks = @typeInfo(CheckId).@"enum".fields.len;
pub const max_gates = 32;

pub const Stats = struct {
    runs: [n_checks]u32 = std.mem.zeroes([n_checks]u32),
    valid: [n_checks]u32 = std.mem.zeroes([n_checks]u32),
    compared: [n_checks][n_backends]u32 = std.mem.zeroes([n_checks][n_backends]u32),
    skipped: [n_checks][n_backends]u32 = std.mem.zeroes([n_checks][n_backends]u32),
    gated: [max_gates]u32 = std.mem.zeroes([max_gates]u32),

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }
};

/// Process-global counters. Single-threaded use only (the fuzz bodies and health tests).
pub var stats: Stats = .{};

pub fn noteRun(c: CheckId, valid: bool) void {
    stats.runs[@intFromEnum(c)] += 1;
    if (valid) stats.valid[@intFromEnum(c)] += 1;
}
pub fn noteCompared(c: CheckId, comptime B: type) void {
    stats.compared[@intFromEnum(c)][backendIndex(B)] += 1;
}
pub fn noteSkipped(c: CheckId, comptime B: type) void {
    stats.skipped[@intFromEnum(c)][backendIndex(B)] += 1;
}
/// compared / valid for (check, backend); 0 when the check saw no valid case.
pub fn comparedFraction(c: CheckId, bi: usize) f64 {
    const v = stats.valid[@intFromEnum(c)];
    if (v == 0) return 0;
    return @as(f64, @floatFromInt(stats.compared[@intFromEnum(c)][bi])) / @as(f64, @floatFromInt(v));
}

// ══════════════════════════════════════════════════════════════════════════════
// Replayable cases
// ══════════════════════════════════════════════════════════════════════════════

/// Suppresses `Case.report` output (health measurement, `fuzz-min` shrinking).
pub var quiet: bool = false;

/// Everything needed to replay one check deterministically. Slices are borrowed,
/// except for a `Case` returned by `parse` (free it with `deinitOwned`).
pub const Case = struct {
    check: CheckId,
    pattern: []const u8 = "",
    input: []const u8 = "",
    /// Serialized `gen/tree.zig` `Tree` (tree-driven checks), else empty.
    tree: []const u8 = "",
    template: []const u8 = "",
    /// Index into `opt_variants`.
    opt: u8 = 0,
    start: usize = 0,
    anchored: bool = false,
    span_end: ?usize = null,
    /// Check-specific PRNG seed (printer variant, op script, witness, …).
    seed: u64 = 0,
    /// Check-specific count (splitN/replaceN n, complexity n, comptime table index, …).
    n: usize = 0,
    /// Second option variant / seed (the metamorphic check's second printing).
    opt2: u8 = 0,
    seed2: u64 = 0,

    pub fn searchOptions(self: *const Case) gex.SearchOptions {
        return .{ .start = self.start, .anchored = self.anchored, .span_end = self.span_end };
    }

    const line_fmt = "FUZZ-CASE check={s} opt={d} start={d} anchored={d} span_end={?d} seed={d} n={d} opt2={d} seed2={d} pat={x} in={x} tmpl={x} tree={x}";
    const LineArgs = struct { []const u8, u8, usize, u1, ?usize, u64, usize, u8, u64, []const u8, []const u8, []const u8, []const u8 };

    fn lineArgs(self: *const Case) LineArgs {
        return .{
            @tagName(self.check), self.opt,      self.start, @intFromBool(self.anchored), self.span_end,
            self.seed,            self.n,        self.opt2,  self.seed2,                  self.pattern,
            self.input,           self.template, self.tree,
        };
    }

    /// One machine-readable line (no trailing newline).
    pub fn format(self: *const Case, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print(line_fmt, self.lineArgs());
    }

    /// Print `why` (formatted) plus the replay line to stderr, unless `quiet`.
    pub fn report(self: *const Case, comptime why: []const u8, args: anytype) void {
        if (quiet) return;
        std.debug.print("\n" ++ why ++ "\n  pattern: /{s}/\n  input:   \"{s}\"\n", args ++ .{ self.pattern, self.input });
        std.debug.print(line_fmt ++ "\n", self.lineArgs());
    }

    /// Parse a `FUZZ-CASE …` line (as printed by `format`). The returned case OWNS its
    /// byte slices — release with `deinitOwned`.
    pub fn parse(gpa: std.mem.Allocator, line_in: []const u8) !Case {
        const line = std.mem.trim(u8, line_in, " \r\n\t");
        const at = std.mem.indexOf(u8, line, "FUZZ-CASE ") orelse return error.BadCaseLine;
        var c: Case = .{ .check = .span };
        var seen: u16 = 0;
        var it = std.mem.tokenizeScalar(u8, line[at + "FUZZ-CASE ".len ..], ' ');
        errdefer c.deinitOwned(gpa);
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadCaseLine;
            const k = kv[0..eq];
            const v = kv[eq + 1 ..];
            if (std.mem.eql(u8, k, "check")) {
                c.check = std.meta.stringToEnum(CheckId, v) orelse return error.BadCaseLine;
                seen |= 1 << 0;
            } else if (std.mem.eql(u8, k, "opt")) {
                c.opt = try std.fmt.parseInt(u8, v, 10);
                seen |= 1 << 1;
            } else if (std.mem.eql(u8, k, "start")) {
                c.start = try std.fmt.parseInt(usize, v, 10);
                seen |= 1 << 2;
            } else if (std.mem.eql(u8, k, "anchored")) {
                c.anchored = !std.mem.eql(u8, v, "0");
                seen |= 1 << 3;
            } else if (std.mem.eql(u8, k, "span_end")) {
                c.span_end = if (std.mem.eql(u8, v, "null")) null else try std.fmt.parseInt(usize, v, 10);
                seen |= 1 << 4;
            } else if (std.mem.eql(u8, k, "seed")) {
                c.seed = try std.fmt.parseInt(u64, v, 10);
                seen |= 1 << 5;
            } else if (std.mem.eql(u8, k, "n")) {
                c.n = try std.fmt.parseInt(usize, v, 10);
                seen |= 1 << 6;
            } else if (std.mem.eql(u8, k, "opt2")) {
                c.opt2 = try std.fmt.parseInt(u8, v, 10);
                seen |= 1 << 7;
            } else if (std.mem.eql(u8, k, "seed2")) {
                c.seed2 = try std.fmt.parseInt(u64, v, 10);
                seen |= 1 << 8;
            } else if (std.mem.eql(u8, k, "pat")) {
                c.pattern = try hexDup(gpa, v);
                seen |= 1 << 9;
            } else if (std.mem.eql(u8, k, "in")) {
                c.input = try hexDup(gpa, v);
                seen |= 1 << 10;
            } else if (std.mem.eql(u8, k, "tmpl")) {
                c.template = try hexDup(gpa, v);
                seen |= 1 << 11;
            } else if (std.mem.eql(u8, k, "tree")) {
                c.tree = try hexDup(gpa, v);
                seen |= 1 << 12;
            } else return error.BadCaseLine;
        }
        if (seen != (1 << 13) - 1) return error.BadCaseLine; // every field must be present
        return c;
    }

    pub fn deinitOwned(self: *const Case, gpa: std.mem.Allocator) void {
        gpa.free(self.pattern);
        gpa.free(self.input);
        gpa.free(self.template);
        gpa.free(self.tree);
    }
};

fn hexDup(gpa: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.BadCaseLine;
    const out = try gpa.alloc(u8, hex.len / 2);
    errdefer gpa.free(out);
    _ = std.fmt.hexToBytes(out, hex) catch return error.BadCaseLine;
    return out;
}
```

> Note on `parse`'s `errdefer c.deinitOwned(gpa)`: fields not yet assigned are the empty literal `""`; `gpa.free("")` on a zero-length slice is a no-op in `std.mem.Allocator.free` (it returns early for `len == 0`), so the errdefer is safe on a partial parse.

- [ ] **Step 4: Create `fuzz/gen/input.zig` with the moved input generator**

```zig
//! Haystack generators. `genInput` is the original small-input generator (moved from
//! the old harness); later tasks add evil UTF-8, long inputs with planted witnesses,
//! and fold-swapped copies.

const std = @import("std");
const Smith = std.testing.Smith;
const ps = @import("pattern.zig");

/// Largest haystack a small-input target feeds the engine.
pub const max_input_len = 64;

/// Generate a haystack into `buf`. 3:1 it draws from the shared alphabet (so matches
/// happen) vs raw full-range bytes (so no-match / prefilter-miss / invalid-UTF-8 paths run).
pub fn genInput(smith: *Smith, buf: []u8) []const u8 {
    @disableInstrumentation();
    const n = smith.slice(buf[0..@min(buf.len, max_input_len)]);
    if (smith.boolWeighted(3, 1)) {
        for (buf[0..n]) |*b| b.* = ps.alphabet[b.* % ps.alphabet.len];
    }
    return buf[0..n];
}
```

Add `pub const input = @import("gen/input.zig");` to `gen` in `fuzz/lib.zig` and `_ = @import("gen/input.zig");` to its test block.

- [ ] **Step 5: Slim `differential.zig` onto `common` and record stats**

In `fuzz/check/differential.zig`:

1. Delete these definitions (now in `common.zig` / `gen/input.zig`): `max_input_len`, `genInput`, `isAsciiStr`, `patternHasWordBoundary`, `byteEnginesSafe`, `isByteEngine`, `Outcome`, `spanEq`, `span_backends`, `capture_backends`, `iter_backends`, `replace_backends`, `offset_backends`.
2. Under the existing imports add:

```zig
const common = @import("common.zig");
const inp = @import("../gen/input.zig");
pub const Outcome = common.Outcome;
const spanEq = common.spanEq;
const byteEnginesSafe = common.byteEnginesSafe;
const isByteEngine = common.isByteEngine;
const span_backends = common.span_backends;
const capture_backends = common.capture_backends;
const iter_backends = common.iter_backends;
const replace_backends = common.replace_backends;
const offset_backends = common.offset_backends;
pub const max_input_len = inp.max_input_len;
pub const genInput = inp.genInput;
```

3. Thread a `CheckId` through the span differential and record compared/skipped. Replace `checkSpan` and `assertBackendsAgree` with:

```zig
fn checkSpan(comptime B: type, gpa: std.mem.Allocator, check: common.CheckId, oracle: Outcome, pattern: []const u8, input: []const u8, byte_safe: bool) anyerror!void {
    @disableInstrumentation();
    if (comptime isByteEngine(B)) if (!byte_safe) return common.noteSkipped(check, B);
    const r = try spanOf(B, gpa, pattern, input);
    if (r == .skip) return common.noteSkipped(check, B);
    if (oracle == .invalid or r == .invalid) {
        if ((oracle == .invalid) != (r == .invalid)) {
            std.debug.print("validity disagreement on /{s}/ ({s}): oracle={s} other={s}\n", .{ pattern, @typeName(B), @tagName(oracle), @tagName(r) });
            return error.ValidityDisagreement;
        }
        return;
    }
    common.noteCompared(check, B);
    if (!spanEq(oracle.span, r.span)) {
        std.debug.print("span disagreement on /{s}/ over \"{s}\" ({s}): oracle={?any} other={?any}\n  pat.hex={x}\n  in.hex ={x}\n", .{ pattern, input, @typeName(B), oracle.span, r.span, pattern, input });
        return error.SpanDisagreement;
    }
}

/// The shared differential assertion: every accepting backend must agree with the
/// Pike VM on validity and (when valid) on a byte-identical leftmost-first span.
pub fn assertBackendsAgree(gpa: std.mem.Allocator, check: common.CheckId, pattern: []const u8, input: []const u8) anyerror!void {
    @disableInstrumentation();
    const oracle = try spanOf(gex.backends.pikevm, gpa, pattern, input);
    if (oracle == .skip) return;
    common.noteRun(check, oracle != .invalid);
    const byte_safe = byteEnginesSafe(gpa, pattern, input);
    inline for (span_backends) |B| try checkSpan(B, gpa, check, oracle, pattern, input, byte_safe);
}
```

and update the three callers: `backendsAgree` → `assertBackendsAgree(gpa, .span, …)`, `anchorsAgree` → `.anchors`, `unicodeAgree` → `.unicode`.

4. Same pattern for the other differentials — in each `checkX` helper add a leading `check`-less stats call using the fixed id:
   - `capturesAgree`: after the oracle `.skip` early-return add `common.noteRun(.captures, oracle.tag != .invalid);`; in `checkCaps` replace `if (comptime isByteEngine(B)) if (!byte_safe) return;` with `if (comptime isByteEngine(B)) if (!byte_safe) return common.noteSkipped(.captures, B);` and `if (r.tag == .skip) return;` with `if (r.tag == .skip) return common.noteSkipped(.captures, B);`, then add `common.noteCompared(.captures, B);` right before the `capResEq` comparison.
   - `iterationAgree`/`checkIter`: same with `.iter`.
   - `replaceAgree`/`checkReplace`: same with `.replace` (oracle `noteRun(.replace, true)` after the `oracle.tag != .ok` return).
   - `searchOffsetAgree`/`checkOffset`: same with `.offset` (`noteRun(.offset, true)` after the oracle skip/invalid return).
   - `strategyInvariant`: after the base skip/invalid return add `common.noteRun(.strategy, true);` (no per-backend counts — it runs `auto` only).

- [ ] **Step 6: Run the tests**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS (the four new `common` tests + unchanged seed replay).

Run: `zig build fuzz -Doptimize=ReleaseSafe`
Expected: exit 0.

- [ ] **Step 7: Commit**

```sh
git add fuzz/check/common.zig fuzz/check/differential.zig fuzz/gen/input.zig fuzz/lib.zig
git commit -m "test(fuzz): shared check plumbing — option variants, stats, replayable cases"
```

---

### Task 3: `health.zig` — vacuity guards (and the two generator bugs they catch)

**Files:**
- Create: `fuzz/health.zig`
- Modify: `fuzz/root.zig` (import health)
- Modify: `fuzz/gen/pattern.zig` (count-based loops; scanner-accepted property names)
- Modify: `fuzz/check/differential.zig` (fix the two invalid unicode seeds)

**Background (verified in `lib/std/testing/Smith.zig`):** when a `Smith` replays bytes (`.in != null` — seed corpora, and every deterministic use), `eosWeightedSimple` returns `in[0] != 0`, i.e. **true for any non-zero byte**; the weights only steer the live fuzzer. The existing generators drive their loops with `while (!smith.eosWeightedSimple(…))`, so seed replay emits near-empty patterns. Separately, 4 of `genUnicode`'s 10 property names are spellings the scanner rejects. Both are silent vacuity; this task makes them loud, then fixes them.

**Interfaces:**
- Consumes: `common.stats`, `common.comparedFraction`, `common.quiet`, `differential.*` bodies, `pattern.gen/genAnchors/genUnicode`.
- Produces (`health.zig`, extended by later tasks): `smithFrom(*std.Random.DefaultPrng, []u8) Smith`, `GenStats{ valid: f64, mean_len: f64, nonempty: f64 }`, `genStats(comptime genFn) GenStats`, `measure(comptime body, seed) usize`, `expectFloor(CheckId, backend_name, min) !void`, `printTable(CheckId) void`.

- [ ] **Step 1: Write the failing health test**

Create `fuzz/health.zig`:

```zig
//! Vacuity guards: the fuzz suite must not pass by doing nothing.
//!
//! A differential in which a backend is *skipped* on every case, or a generator that
//! mostly emits empty or scanner-rejected patterns, still "passes" — silently. These
//! finite tests run each generator and check body over fixed-seed `Smith` inputs and
//! assert: generators emit valid, non-trivial patterns; every backend is actually
//! COMPARED on at least a floor fraction of valid cases. Floors come from measured values
//! with margin (fuzz/README.md → Health). A floor that trips is a finding first (vacuity),
//! a floor adjustment only with a stated reason.

const std = @import("std");
const gex = @import("ezi_gex");
const lib = @import("fuzz_lib");
const common = lib.check.common;
const d = lib.check.differential;
const ps = lib.gen.pattern;
const Smith = std.testing.Smith;

pub const gen_seeds = 2000;
pub const body_seeds = 400;

/// A replaying `Smith` over PRNG bytes. (Replay-mode `eos` is `byte != 0`, so generators
/// must not steer loops with `eos` — see Task 3 background.)
pub fn smithFrom(prng: *std.Random.DefaultPrng, buf: []u8) Smith {
    prng.random().bytes(buf);
    return .{ .in = buf };
}

pub const GenStats = struct { valid: f64, mean_len: f64, nonempty: f64 };

/// Validity / size profile of `genFn` over `gen_seeds` fixed seeds.
pub fn genStats(comptime genFn: anytype) GenStats {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x4ea1_7400);
    var buf: [512]u8 = undefined;
    var ok: usize = 0;
    var total_len: usize = 0;
    var nonempty: usize = 0;
    for (0..gen_seeds) |_| {
        var s = smithFrom(&prng, &buf);
        const p = genFn(&s);
        const pat = p.slice();
        total_len += pat.len;
        if (pat.len > 0) nonempty += 1;
        var diag: gex.Diagnostic = .{};
        if (gex.parse(gpa, pat, &diag)) |a| {
            ok += 1;
            a.deinit(gpa);
        } else |_| {}
    }
    const n: f64 = @floatFromInt(gen_seeds);
    return .{
        .valid = @as(f64, @floatFromInt(ok)) / n,
        .mean_len = @as(f64, @floatFromInt(total_len)) / n,
        .nonempty = @as(f64, @floatFromInt(nonempty)) / n,
    };
}

/// Run `body` over `body_seeds` fixed seeds with fresh stats and reporting suppressed.
/// Returns how many iterations returned an error (a divergence found while measuring —
/// counted, not failed: finding bugs is the groups' job, measuring reach is ours).
pub fn measure(comptime body: anytype, seed: u64) usize {
    common.stats.reset();
    common.quiet = true;
    defer common.quiet = false;
    var prng = std.Random.DefaultPrng.init(seed);
    var buf: [512]u8 = undefined;
    var failures: usize = 0;
    for (0..body_seeds) |_| {
        var s = smithFrom(&prng, &buf);
        body({}, &s) catch {
            failures += 1;
        };
    }
    return failures;
}

pub fn printTable(check: common.CheckId) void {
    std.debug.print("health[{s}] runs={d} valid={d}:", .{ @tagName(check), common.stats.runs[@intFromEnum(check)], common.stats.valid[@intFromEnum(check)] });
    for (common.backend_names, 0..) |name, bi| std.debug.print(" {s}={d:.2}", .{ name, common.comparedFraction(check, bi) });
    std.debug.print("\n", .{});
}

pub fn expectFloor(check: common.CheckId, backend: []const u8, min: f64) !void {
    for (common.backend_names, 0..) |name, bi| {
        if (!std.mem.eql(u8, name, backend)) continue;
        const got = common.comparedFraction(check, bi);
        if (got < min) {
            std.debug.print("health: {s}/{s} compared on {d:.3} of valid cases (floor {d:.3}) — vacuous?\n", .{ @tagName(check), backend, got, min });
            printTable(check);
            return error.VacuousCheck;
        }
        return;
    }
    return error.UnknownBackend;
}

fn expectGen(name: []const u8, st: GenStats, min_valid: f64, min_mean_len: f64) !void {
    if (st.valid < min_valid or st.mean_len < min_mean_len or st.nonempty < 0.9) {
        std.debug.print("health: generator {s}: valid={d:.3} (floor {d:.2}) mean_len={d:.1} (floor {d:.1}) nonempty={d:.3} (floor 0.90)\n", .{ name, st.valid, min_valid, st.mean_len, min_mean_len, st.nonempty });
        return error.GeneratorVacuous;
    }
}

test "health: generators emit valid, non-trivial patterns" {
    try expectGen("gen", genStats(ps.gen), 0.80, 8.0);
    try expectGen("genAnchors", genStats(ps.genAnchors), 0.90, 4.0);
    try expectGen("genUnicode", genStats(ps.genUnicode), 0.90, 6.0);
}

test "health: span differential compares every backend" {
    _ = measure(d.backendsAgree, 0xd1ff);
    try expectFloor(.span, "backtrack", 0.90);
    try expectFloor(.span, "auto", 0.90);
    try expectFloor(.span, "bytepike", 0.40);
    try expectFloor(.span, "dfa", 0.30);
    try expectFloor(.span, "edfa", 0.30);
    try expectFloor(.span, "onepass", 0.05);
}

test "health: unicode differential compares the code-point engines" {
    _ = measure(d.unicodeAgree, 0x0c0de);
    try expectFloor(.unicode, "backtrack", 0.90);
    try expectFloor(.unicode, "auto", 0.90);
}
```

Add to `fuzz/root.zig`'s `test {}` block: `_ = @import("health.zig");`

- [ ] **Step 2: Run it to see it fail**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe 2>&1 | grep -E "health"`
Expected: FAIL — `health: generator gen: valid=… mean_len=<small> … nonempty=<well under 0.90>` (the eos-driven loops stop at the first non-zero byte).

- [ ] **Step 3: Make every generator loop count-driven**

In `fuzz/gen/pattern.zig` add, near the top, the explanation and replace each `eos`-steered loop:

```zig
// Loop lengths are drawn with `valueRangeAtMost`, never steered by `eos`: when a `Smith`
// REPLAYS bytes (seed corpora, fuzz/health.zig, any deterministic use) `eos` is simply
// `byte != 0`, so an eos-steered loop almost always stops at once and seed replay would
// test near-empty patterns. Count draws behave the same under replay and live fuzzing.
```

`genAlternation`:

```zig
fn genAlternation(p: *PatternSmith, smith: *Smith, depth: u8) void {
    genConcat(p, smith, depth);
    // Lean against extra branches: 1 in 8 alternations get 1–2 more.
    const extra: u8 = if (smith.valueRangeAtMost(u8, 0, 7) == 0) smith.valueRangeAtMost(u8, 1, 2) else 0;
    var i: u8 = 0;
    while (i < extra and !p.nearlyFull()) : (i += 1) {
        p.put('|');
        genConcat(p, smith, depth);
    }
}
```

`genConcat`:

```zig
fn genConcat(p: *PatternSmith, smith: *Smith, depth: u8) void {
    // 0 atoms is a valid empty branch (`a|`); usually 1–5.
    const n = smith.valueRangeAtMost(u8, 0, 5);
    var i: u8 = 0;
    while (i < n and !p.nearlyFull()) : (i += 1) genQuantified(p, smith, depth);
}
```

In `genClass` replace the `while (n < 4 and !smith.eosWeightedSimple(2, 1)) : (n += 1)` header with:

```zig
    const want = smith.valueRangeAtMost(u8, 1, 4);
    var n: u8 = 0;
    while (n < want) : (n += 1) {
```

In `unicodeInput` replace `while (guard < 24 and !smith.eosWeightedSimple(3, 1)) : (guard += 1)` with:

```zig
    const want = smith.valueRangeAtMost(u8, 0, 24);
    var guard: u8 = 0;
    while (guard < want) : (guard += 1) {
```

Run: `grep -n "eos" fuzz/gen/pattern.zig`
Expected: only the comment above mentions `eos`.

- [ ] **Step 4: Run again — now the unicode generator's validity trips**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe 2>&1 | grep -E "health"`
Expected: FAIL — `health: generator genUnicode: valid=0.7… (floor 0.90)` (bare script names and `White_Space` are `unknown_property`).

- [ ] **Step 5: Use scanner-accepted property names; fix the two invalid seeds**

In `fuzz/gen/pattern.zig` replace `uni_props`:

```zig
/// Property names the scanner accepts (`token.resolveProperty`): GC names/groups,
/// DerivedCoreProperties, and scripts ONLY behind a `Script=`/`sc=` prefix. Bare script
/// names (`Greek`) and `White_Space` are rejected (`unknown_property`) — an earlier
/// version of this list used them, silently spending a quarter of the unicode group's
/// budget on the reject path (caught by fuzz/health.zig).
const uni_props = [_][]const u8{
    "L",  "Lu", "Ll",       "Nd",      "N",
    "P",  "sc=Greek", "sc=Latn", "Script=Cyrillic", "Alphabetic",
};
```

In `fuzz/check/differential.zig`'s `unicode_seed_corpus` replace `"\\p{Greek}"` → `"\\p{sc=Greek}"` and `"[a-z\\p{Cyrillic}]+"` → `"[a-z\\p{sc=Cyrl}]+"`.

- [ ] **Step 6: Set the backend floors from measurement**

Temporarily set every `expectFloor` `min` in the two differential tests to `1.0`, run
`zig build test-fuzz -Doptimize=ReleaseSafe 2>&1 | grep -E "^health"` — each failing floor prints its check's full
table (`health[span] runs=… valid=…: pikevm=… backtrack=… …`). Set each `min` to the measured fraction × 0.8,
rounded **down** to 0.05. If a backend measures < 0.05 where engagement is expected (`dfa`, `edfa`, `bytepike`,
`auto`, `backtrack`), stop — that is vacuity: temporarily print `@errorName(e)` in `spanOf`'s
`else => return .skip` branch to see why it declines, and record the explanation in the commit message before
choosing a floor. Same procedure for the generator floors (`expectGen`) using the printed `valid`/`mean_len`.

- [ ] **Step 7: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS.

Run: `zig build fuzz -Doptimize=ReleaseSafe`
Expected: exit 0. Seed replay now exercises non-trivial patterns, so a group may FAIL here on a real divergence
that was unreachable before. Do not fix the engine. Copy the printed pattern/input (and hex) into a new
`## Open (to triage)` section at the end of `fuzz/README.md`, then change only the triggering corpus entry
(corpora are byte streams to the generators now, so any other string of similar length works) until the smoke is
green. Task 27 turns each such entry into a gated ledger finding.

- [ ] **Step 8: Commit**

```sh
git add fuzz/health.zig fuzz/root.zig fuzz/gen/pattern.zig fuzz/check/differential.zig fuzz/README.md
git commit -m "test(fuzz): vacuity guards; fix two silent generator gaps

- Replay-mode Smith eos is byte != 0, so eos-steered loops made seed
  replay test near-empty patterns; loops now draw counts.
- genUnicode used property spellings the scanner rejects (bare script
  names, White_Space); now uses sc=/Script= prefixed names.
health.zig fails on both classes."
```

---

## Phase B — Generators

### Task 4: Widen `gen/pattern.zig` (trap code points, named escapes, `\Z`, class items, verbose text)

**Files:**
- Modify: `fuzz/gen/pattern.zig`

**Interfaces:**
- Produces: `pattern.trap_raw: []const []const u8` (raw UTF-8 of the fold/length trap code points; reused by `gen/input.zig`). `gen`, `genAnchors`, `genUnicode`, `unicodeInput`, `alphabet`, `max_pattern_len`, `max_rep_bound`, `PatternSmith` keep their signatures.

- [ ] **Step 1: Write the failing reach test** (append to `fuzz/gen/pattern.zig`)

```zig
test "gen reaches the widened syntax" {
    const needles = [_][]const u8{
        "\\e",   "\\Z",   "\\x{212A}", "\\u{017F}", "\\P{", "\\S",
        "(?x",   "#",     "\\cj",      "[^",        "\\-",  "\xE2\x84\xAA",
    };
    var seen = [_]bool{false} ** needles.len;
    var prng = std.Random.DefaultPrng.init(7);
    var buf: [512]u8 = undefined;
    for (0..4000) |_| {
        prng.random().bytes(&buf);
        var s: Smith = .{ .in = &buf };
        const p = gen(&s);
        for (needles, 0..) |nd, k| {
            if (std.mem.indexOf(u8, p.slice(), nd) != null) seen[k] = true;
        }
    }
    for (needles, seen) |nd, ok| {
        if (!ok) {
            std.debug.print("gen never emitted {s}\n", .{nd});
            return error.SyntaxUnreached;
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe 2>&1 | grep -E "never emitted|SyntaxUnreached"`
Expected: FAIL — `gen never emitted \e` (and others).

- [ ] **Step 3: Implement the widening**

Add after `alphabet`:

```zig
/// Raw UTF-8 for code points that stress case folding and UTF-8 length handling: folds
/// that change encoded length (K U+212A ↔ k: 3→1 bytes; ſ U+017F ↔ s; Ⱥ U+023A ↔ ⱥ
/// U+2C65: 2→3), multi-member orbits (ς/σ/Σ, µ/μ, İ/ı, ǅ), a 4-byte cased letter (𐐀),
/// and a real U+FFFD (distinct from an invalid byte under dead-on-invalid).
pub const trap_raw = [_][]const u8{
    "\xE2\x84\xAA", "\xC5\xBF", "\xC8\xBA", "\xE2\xB1\xA5", "\xCF\x82", "\xCF\x83", "\xCE\xA3",
    "\xC2\xB5",     "\xCE\xBC", "\xC4\xB0", "\xC4\xB1",     "\xC7\x85", "\xF0\x90\x90\x80",
    "\xF0\x90\x90\xA8", "\xEF\xBF\xBD",
};
```

Replace `genEscape`:

```zig
/// A literal-yielding escape the scanner accepts.
fn genEscape(p: *PatternSmith, smith: *Smith) void {
    const fixed = [_][]const u8{
        "\\x61", "\\x{42}", "\\u{0063}", "\\u0031",  "\\cA",       "\\cj",       "\\n",
        "\\t",   "\\e",     "\\0",       "\\x{212A}", "\\u{017F}", "\\x{10FFFF}", "\\u{FFFD}",
    };
    const k = smith.valueRangeAtMost(u8, 0, fixed.len); // == fixed.len → an escaped metachar
    if (k < fixed.len) return p.puts(fixed[k]);
    const metas = ".*+?()[]{}|^$\\-# ";
    p.put('\\');
    p.put(metas[smith.index(metas.len)]);
}
```

In `genShorthand` change the range to `valueRangeAtMost(u8, 0, 12)` and add `12 => p.puts("\\Z"),` before the `else`.

Replace the item `switch` inside `genClass`'s loop:

```zig
        switch (smith.valueRangeAtMost(u8, 0, 9)) {
            0 => p.puts("a-c"),
            1 => p.puts("\\d"),
            2 => p.puts("\\w"),
            3 => p.puts("\\p{L}"),
            4 => p.puts("\\S"),
            5 => p.puts("\\D"),
            6 => p.puts("\\P{Lu}"),
            7 => p.puts("\\x{e9}-\\x{3b1}"),
            8 => p.puts("\\-"),
            else => p.puts(trap_raw[smith.index(trap_raw.len)]),
        }
```

In `genAtom`, make one in five literals a trap (replace the `0, 1 => p.put(litByte(smith)),` prong):

```zig
        0, 1 => if (smith.valueRangeAtMost(u8, 0, 4) == 0)
            p.puts(trap_raw[smith.index(trap_raw.len)])
        else
            p.put(litByte(smith)),
```

In `genConcat`'s loop body, before `genQuantified(p, smith, depth);`, add occasional verbose-mode text (a literal space/`#`/newline when `x` is off, insignificant when it is on — the differential compares backends on the same text either way):

```zig
        if (smith.valueRangeAtMost(u8, 0, 9) == 0) {
            const junk = [_][]const u8{ " ", "\t", " #c\n" };
            p.puts(junk[smith.index(junk.len)]);
        }
```

- [ ] **Step 4: Run to verify it passes (reach + health floors unchanged)**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS (the health generator floors from Task 3 still hold; if `gen`'s `valid` drops below its floor, print the rejected patterns in a scratch test and fix the emitting prong — every added spelling above is scanner-accepted, per the Global Constraints probe).

- [ ] **Step 5: Commit**

```sh
git add fuzz/gen/pattern.zig
git commit -m "test(fuzz): widen pattern generator — fold traps, named escapes, \\Z, class items, verbose text"
```

---

### Task 5: `gen/props.zig` + `gen/tree.zig` — the semantic tree

**Files:**
- Create: `fuzz/gen/props.zig`, `fuzz/gen/tree.zig`
- Modify: `fuzz/check/common.zig` (comptime sync assertion), `fuzz/lib.zig`

**Interfaces:**
- Produces (`props`): `Group` enum, `Sem = union(enum){ gc, group, derived, script }`, `Prop{ short, long, sem, sample: u21 }`, `table: []const Prop`, `indexOf(short) ?u8`.
- Produces (`tree`): `max_nodes=48`, `max_kids=96`, `max_items=32`, `max_depth=4`, `max_rep=6`, `max_groups=15`, `unbounded=0xFF`; `Flags` (packed u8: `i m s` + `eql`), `OptSem{ unicode, fold, base: Flags }`, `opt_sem: [6]OptSem`; `Kind`, `Assert`, `Perl`, `ItemKind`; `Item` and `Node` (extern); `Tree` (extern) with `init(opt)`, `add(Node) u16`, `addParent(kind, flags, kids) u16`, `addItems(items) ?u16`, `kidsOf(Node)`, `itemsOf(Node)`, `nullable(i) bool`, `hasCapture(i) bool`, `size(i) usize`, `renumberGroups()`, `bytes() []const u8`, `fromBytes([]const u8) ?Tree`, `wellFormed() bool`; `Builder`; `generate(*Smith, opt) Tree`; `pickOpt(*Smith) u8`; `encodeUtf8(u21, *[4]u8) u3`; `alphabet_cps`, `trap_cps`.
- Node field meanings: `lit`: `cp`. `class`: `a`=negated, `first/len`=items. `assert`: `a`=`Assert`. `concat/alt`: `first/len`=kids. `repeat`: `a`=greedy, `b`=min, `c`=max (`unbounded`), `first`=child. `group` (capturing): `b`=capture index (pre-order, 1-based), `first`=child. `flags`: `a`=set bits, `b`=clear bits, `first`=child (whose `flags` are the result). Node 0 is always a shared `empty` leaf (`add` returns 0 when the pool is full).

- [ ] **Step 1: Create `fuzz/gen/props.zig`** (data + a test that ezi accepts every spelling)

```zig
//! Unicode property names the tree generator may emit. Each has two scanner-accepted
//! spellings (the printer picks one — a metamorphic rewrite), its semantics for the
//! reference matcher, and one sample member (witnesses, class-membership inputs).

const std = @import("std");
const ez = @import("ezi_code");
const P = ez.unicode.properties;
const S = ez.unicode.scripts;

pub const Group = enum { letter, cased_letter, mark, number, punctuation, symbol, separator, other };
pub const Sem = union(enum) {
    gc: P.GeneralCategory,
    group: Group,
    derived: P.DerivedProperty,
    /// ezi_gex resolves `Script_Extensions=` to the plain `Script` ranges (documented).
    script: S.ScriptType,
};
pub const Prop = struct { short: []const u8, long: []const u8, sem: Sem, sample: u21 };

pub const table = [_]Prop{
    .{ .short = "L", .long = "Letter", .sem = .{ .group = .letter }, .sample = 'q' },
    .{ .short = "LC", .long = "Cased_Letter", .sem = .{ .group = .cased_letter }, .sample = 'Q' },
    .{ .short = "M", .long = "Mark", .sem = .{ .group = .mark }, .sample = 0x0301 },
    .{ .short = "N", .long = "Number", .sem = .{ .group = .number }, .sample = '7' },
    .{ .short = "P", .long = "Punctuation", .sem = .{ .group = .punctuation }, .sample = '!' },
    .{ .short = "S", .long = "Symbol", .sem = .{ .group = .symbol }, .sample = '+' },
    .{ .short = "Z", .long = "Separator", .sem = .{ .group = .separator }, .sample = ' ' },
    .{ .short = "C", .long = "Other", .sem = .{ .group = .other }, .sample = '\t' },
    .{ .short = "Lu", .long = "Uppercase_Letter", .sem = .{ .gc = .uppercase_letter }, .sample = 'K' },
    .{ .short = "Ll", .long = "Lowercase_Letter", .sem = .{ .gc = .lowercase_letter }, .sample = 'k' },
    .{ .short = "Lt", .long = "Titlecase_Letter", .sem = .{ .gc = .titlecase_letter }, .sample = 0x01C5 },
    .{ .short = "Lm", .long = "Modifier_Letter", .sem = .{ .gc = .modifier_letter }, .sample = 0x02B0 },
    .{ .short = "Lo", .long = "Other_Letter", .sem = .{ .gc = .other_letter }, .sample = 0x65E5 },
    .{ .short = "Mn", .long = "Nonspacing_Mark", .sem = .{ .gc = .non_spacing_mark }, .sample = 0x0301 },
    .{ .short = "Nd", .long = "Decimal_Number", .sem = .{ .gc = .decimal_number }, .sample = 0x0663 },
    .{ .short = "Nl", .long = "Letter_Number", .sem = .{ .gc = .letter_number }, .sample = 0x2160 },
    .{ .short = "No", .long = "Other_Number", .sem = .{ .gc = .other_number }, .sample = 0x00B2 },
    .{ .short = "Pc", .long = "Connector_Punctuation", .sem = .{ .gc = .connector_punctuation }, .sample = '_' },
    .{ .short = "Pd", .long = "Dash_Punctuation", .sem = .{ .gc = .dash_punctuation }, .sample = '-' },
    .{ .short = "Ps", .long = "Open_Punctuation", .sem = .{ .gc = .open_punctuation }, .sample = '(' },
    .{ .short = "Po", .long = "Other_Punctuation", .sem = .{ .gc = .other_punctuation }, .sample = '#' },
    .{ .short = "Sm", .long = "Math_Symbol", .sem = .{ .gc = .math_symbol }, .sample = '+' },
    .{ .short = "Sc", .long = "Currency_Symbol", .sem = .{ .gc = .currency_symbol }, .sample = '$' },
    .{ .short = "So", .long = "Other_Symbol", .sem = .{ .gc = .other_symbol }, .sample = 0x00A9 },
    .{ .short = "Zs", .long = "Space_Separator", .sem = .{ .gc = .space_separator }, .sample = 0x3000 },
    .{ .short = "Cc", .long = "Control", .sem = .{ .gc = .control }, .sample = '\n' },
    .{ .short = "Cf", .long = "Format", .sem = .{ .gc = .format }, .sample = 0x200D },
    .{ .short = "Co", .long = "Private_Use", .sem = .{ .gc = .private_use }, .sample = 0xE000 },
    .{ .short = "Cn", .long = "Unassigned", .sem = .{ .gc = .unassigned }, .sample = 0x0378 },
    .{ .short = "Alphabetic", .long = "Alphabetic", .sem = .{ .derived = .alphabetic }, .sample = 'a' },
    .{ .short = "Lowercase", .long = "Lowercase", .sem = .{ .derived = .lowercase }, .sample = 0x00AA },
    .{ .short = "Uppercase", .long = "Uppercase", .sem = .{ .derived = .uppercase }, .sample = 'Z' },
    .{ .short = "Cased", .long = "Cased", .sem = .{ .derived = .cased }, .sample = 0x01C5 },
    .{ .short = "Math", .long = "Math", .sem = .{ .derived = .math }, .sample = '^' },
    .{ .short = "ID_Start", .long = "ID_Start", .sem = .{ .derived = .id_start }, .sample = 'x' },
    .{ .short = "XID_Continue", .long = "XID_Continue", .sem = .{ .derived = .xid_continue }, .sample = '9' },
    .{ .short = "Default_Ignorable_Code_Point", .long = "Default_Ignorable_Code_Point", .sem = .{ .derived = .default_ignorable_code_point }, .sample = 0x00AD },
    .{ .short = "Grapheme_Extend", .long = "Grapheme_Extend", .sem = .{ .derived = .grapheme_extend }, .sample = 0x0300 },
    .{ .short = "sc=Grek", .long = "Script=Greek", .sem = .{ .script = .greek }, .sample = 0x03B1 },
    .{ .short = "sc=Latn", .long = "Script=Latin", .sem = .{ .script = .latin }, .sample = 'a' },
    .{ .short = "sc=Cyrl", .long = "Script=Cyrillic", .sem = .{ .script = .cyrillic }, .sample = 0x0436 },
    .{ .short = "sc=Hani", .long = "Script=Han", .sem = .{ .script = .han }, .sample = 0x65E5 },
    .{ .short = "sc=Zyyy", .long = "Script=Common", .sem = .{ .script = .common }, .sample = '1' },
    .{ .short = "sc=Zinh", .long = "Script=Inherited", .sem = .{ .script = .inherited }, .sample = 0x0301 },
    .{ .short = "scx=Grek", .long = "Script_Extensions=Greek", .sem = .{ .script = .greek }, .sample = 0x03B1 },
};

pub fn indexOf(short: []const u8) ?u8 {
    for (table, 0..) |p, i| if (std.mem.eql(u8, p.short, short)) return @intCast(i);
    return null;
}

test "every property spelling is accepted by the scanner" {
    const gex = @import("ezi_gex");
    const gpa = std.testing.allocator;
    var buf: [64]u8 = undefined;
    for (table) |p| {
        for ([_][]const u8{ p.short, p.long }) |name| {
            const pat = try std.fmt.bufPrint(&buf, "\\p{{{s}}}", .{name});
            var diag: gex.Diagnostic = .{};
            const a = gex.parse(gpa, pat, &diag) catch {
                std.debug.print("scanner rejected {s}: {s}\n", .{ pat, @tagName(diag.code) });
                return error.PropertyRejected;
            };
            a.deinit(gpa);
        }
    }
}
```

Add `pub const props = @import("gen/props.zig");` to `gen` in `fuzz/lib.zig` and `_ = @import("gen/props.zig");` to its test block.

- [ ] **Step 2: Run the props test**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS. (If a spelling is rejected, the scanner's tables — `src/core/token.zig` `gc_map_entries`/`derived_map_entries`/`script_long_name_entries` — are authoritative: drop or respell that entry.)

- [ ] **Step 3: Write the failing tree tests** — create `fuzz/gen/tree.zig` containing only this test block plus `const std = @import("std"); const Smith = std.testing.Smith;` for now:

```zig
test "Builder + nullable" {
    var b = Builder.init(0);
    const a = b.lit('a');
    try std.testing.expect(b.t.nullable(b.star(a)));
    try std.testing.expect(!b.t.nullable(b.plus(a)));
    try std.testing.expect(b.t.nullable(b.alt(&.{ b.empty(), b.lit('x') })));
    try std.testing.expect(b.t.nullable(b.assert(.word_boundary)));
    try std.testing.expect(b.t.nullable(b.rep(a, 0, 0, true)));
    try std.testing.expect(!b.t.nullable(b.class(&.{Builder.range('a', 'c')}, false)));
    try std.testing.expect(!b.t.nullable(b.cat(&.{ b.opt(a), b.lit('y') })));
}

test "renumberGroups numbers capture groups in pre-order" {
    var b = Builder.init(0);
    const inner_a = b.group(b.lit('a')); // built first (bottom-up) …
    const inner_b = b.group(b.lit('b'));
    const outer = b.group(b.cat(&.{ inner_a, inner_b })); // … but opens first in the text
    const t = b.finish(outer);
    try std.testing.expectEqual(@as(u8, 3), t.n_groups);
    try std.testing.expectEqual(@as(u8, 1), t.nodes[outer].b);
    try std.testing.expectEqual(@as(u8, 2), t.nodes[inner_a].b);
    try std.testing.expectEqual(@as(u8, 3), t.nodes[inner_b].b);
}

test "generated trees are well-formed and round-trip through bytes" {
    var prng = std.Random.DefaultPrng.init(11);
    var buf: [1024]u8 = undefined;
    var kinds_seen = [_]bool{false} ** @typeInfo(Kind).@"enum".fields.len;
    for (0..3000) |_| {
        prng.random().bytes(&buf);
        var s: Smith = .{ .in = &buf };
        const opt = pickOpt(&s);
        const t = generate(&s, opt);
        try std.testing.expect(t.wellFormed());
        for (t.nodes[0..t.n_nodes]) |n| kinds_seen[@intFromEnum(n.kind)] = true;
        const back = Tree.fromBytes(t.bytes()) orelse return error.RoundTripRejected;
        try std.testing.expectEqualSlices(u8, t.bytes(), back.bytes());
    }
    for (kinds_seen, 0..) |seen, k| if (!seen) {
        std.debug.print("generator never produced kind {s}\n", .{@tagName(@as(Kind, @enumFromInt(k)))});
        return error.KindUnreached;
    };
}

test "fromBytes rejects malformed input" {
    var b = Builder.init(0);
    const t = b.finish(b.cat(&.{ b.lit('a'), b.dot() }));
    try std.testing.expect(Tree.fromBytes(t.bytes()[1..]) == null); // wrong length
    var raw: [@sizeOf(Tree)]u8 = undefined;
    @memcpy(&raw, t.bytes());
    raw[@offsetOf(Tree, "nodes") + @offsetOf(Node, "kind")] = 0xEE; // bad Kind tag
    try std.testing.expect(Tree.fromBytes(&raw) == null);
    @memcpy(&raw, t.bytes());
    std.mem.writeInt(u16, raw[@offsetOf(Tree, "root")..][0..2], max_nodes + 3, .little); // root out of range
    try std.testing.expect(Tree.fromBytes(&raw) == null);
}

test "encodeUtf8" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "a", out[0..encodeUtf8('a', &out)]);
    try std.testing.expectEqualSlices(u8, "\xC3\xA9", out[0..encodeUtf8(0xE9, &out)]);
    try std.testing.expectEqualSlices(u8, "\xE2\x84\xAA", out[0..encodeUtf8(0x212A, &out)]);
    try std.testing.expectEqualSlices(u8, "\xF4\x8F\xBF\xBF", out[0..encodeUtf8(0x10FFFF, &out)]);
}
```

Add `pub const tree = @import("gen/tree.zig");` to `gen` in `fuzz/lib.zig` and `_ = @import("gen/tree.zig");` to its test block.

- [ ] **Step 4: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile — `use of undeclared identifier 'Builder'`.

- [ ] **Step 5: Implement `fuzz/gen/tree.zig`** (above the tests; keep the two imports)

```zig
//! The semantic pattern tree — ground truth for the reference, metamorphic, and
//! witness-planting checks.
//!
//! A `Tree` is generated from a `Smith`, printed to pattern text by `print.zig` in many
//! equivalent spellings, interpreted directly by the reference matcher (`ref/`), and
//! sampled for witness strings (`witness.zig`). It never touches ezi_gex's AST: every
//! node carries the flags (i/m/s) IN FORCE at it, so its meaning is independent of how it
//! is spelled. It is POD (`extern`) so it serializes into `FUZZ-CASE tree=…` and
//! `fuzz-min` can shrink it node by node.
//!
//! Loop lengths come from `valueRangeAtMost`, never `eos` (replay-mode `eos` is
//! `byte != 0` — see fuzz/health.zig).

const props = @import("props.zig");

pub const max_nodes = 48;
pub const max_kids = 96;
pub const max_items = 32;
pub const max_depth = 4;
pub const max_rep = 6;
pub const max_groups = 15;
/// `Node.c` for "no upper bound" (`*`, `+`, `{m,}`).
pub const unbounded: u8 = 0xFF;

pub const Flags = packed struct(u8) {
    i: bool = false,
    m: bool = false,
    s: bool = false,
    _pad: u5 = 0,

    pub fn eql(a: Flags, b: Flags) bool {
        return a.i == b.i and a.m == b.m and a.s == b.s;
    }
};

/// Semantics of each `check/common.zig` `opt_variants` entry, mirrored here so `gen`
/// and `ref` never import `check` (common.zig asserts the two stay in sync at comptime).
pub const OptSem = struct { unicode: bool = true, fold: bool = true, base: Flags = .{} };
pub const opt_sem = [_]OptSem{
    .{}, // 0 defaults
    .{ .unicode = false }, // 1 ASCII \d \w \s
    .{ .fold = false }, // 2 case_fold = .none — (?i) has no effect
    .{ .base = .{ .i = true } }, // 3 case_insensitive
    .{ .base = .{ .m = true } }, // 4 multiline
    .{ .base = .{ .s = true } }, // 5 dot_matches_newline
};

pub const Kind = enum(u8) { empty, lit, dot, class, assert, concat, alt, repeat, group, flags };
pub const Assert = enum(u8) { text_start, text_end, line_start, line_end, word_boundary, not_word_boundary };
pub const Perl = enum(u8) { digit, word, space };
pub const ItemKind = enum(u8) { range, perl, prop };

pub const Item = extern struct {
    kind: ItemKind,
    neg: bool = false,
    /// `Perl` tag or `props.table` index.
    which: u8 = 0,
    _pad: u8 = 0,
    lo: u32 = 0,
    hi: u32 = 0,
};

pub const Node = extern struct {
    kind: Kind,
    flags: Flags = .{},
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    _pad: u8 = 0,
    first: u16 = 0,
    len: u16 = 0,
    cp: u32 = 0,
};

pub const alphabet_cps = [_]u21{ 'a', 'b', 'A', 'B', 'c', '1', ' ', '\n', '_', 'k', 's' };
pub const trap_cps = [_]u21{
    0x212A, 0x017F, 'K',     'S',    0x023A, 0x2C65, 0x03A3, 0x03C3, 0x03C2, 0x00B5, 0x03BC,
    0x0130, 0x0131, 'i',     'I',    0x01C4, 0x01C5, 0x01C6, 0x10400, 0x10428, 0xFFFD, 0x7F,
    0x80,   0x7FF,  0x800,   0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF, 0x00E9, 0x65E5, 0x1F600,
    0x00DF, 0x1E9E, '.',     '#',    '$',    '\\',   '[',    ']',    '(',    ')',    '|',
    '?',    '*',    '+',     '{',    '}',    '^',    '-',    '\t',   0x00,   0x1B,
};

pub const Tree = extern struct {
    nodes: [max_nodes]Node,
    kids: [max_kids]u16,
    items: [max_items]Item,
    n_nodes: u16,
    n_kids: u16,
    n_items: u16,
    root: u16,
    opt: u8,
    n_groups: u8,
    _pad: [2]u8,

    /// Only the shared empty leaf (node 0), which `add` falls back to when full.
    pub fn init(opt: u8) Tree {
        var t = std.mem.zeroes(Tree);
        t.opt = opt;
        t.nodes[0] = .{ .kind = .empty, .flags = opt_sem[opt].base };
        t.n_nodes = 1;
        return t;
    }

    pub fn add(t: *Tree, n: Node) u16 {
        if (t.n_nodes >= max_nodes) return 0;
        t.nodes[t.n_nodes] = n;
        t.n_nodes += 1;
        return t.n_nodes - 1;
    }

    pub fn addParent(t: *Tree, kind: Kind, f: Flags, kids: []const u16) u16 {
        if (t.n_kids + kids.len > max_kids or t.n_nodes >= max_nodes) return 0;
        const first = t.n_kids;
        @memcpy(t.kids[first..][0..kids.len], kids);
        t.n_kids += @intCast(kids.len);
        return t.add(.{ .kind = kind, .flags = f, .first = first, .len = @intCast(kids.len) });
    }

    pub fn addItems(t: *Tree, its: []const Item) ?u16 {
        if (its.len == 0 or t.n_items + its.len > max_items) return null;
        const first = t.n_items;
        @memcpy(t.items[first..][0..its.len], its);
        t.n_items += @intCast(its.len);
        return first;
    }

    pub fn kidsOf(t: *const Tree, n: Node) []const u16 {
        return t.kids[n.first..][0..n.len];
    }

    pub fn itemsOf(t: *const Tree, n: Node) []const Item {
        return t.items[n.first..][0..n.len];
    }

    /// Can node `i` match the empty string? (Rust's `is_match_empty`: assertions count.)
    pub fn nullable(t: *const Tree, i: u16) bool {
        const n = t.nodes[i];
        return switch (n.kind) {
            .empty, .assert => true,
            .lit, .dot, .class => false,
            .concat => for (t.kidsOf(n)) |k| {
                if (!t.nullable(k)) break false;
            } else true,
            .alt => for (t.kidsOf(n)) |k| {
                if (t.nullable(k)) break true;
            } else false,
            .repeat => n.b == 0 or t.nullable(n.first),
            .group, .flags => t.nullable(n.first),
        };
    }

    pub fn hasCapture(t: *const Tree, i: u16) bool {
        const n = t.nodes[i];
        return switch (n.kind) {
            .group => true,
            .concat, .alt => for (t.kidsOf(n)) |k| {
                if (t.hasCapture(k)) break true;
            } else false,
            .repeat, .flags => t.hasCapture(n.first),
            else => false,
        };
    }

    /// Node count of the subtree at `i`.
    pub fn size(t: *const Tree, i: u16) usize {
        const n = t.nodes[i];
        return 1 + switch (n.kind) {
            .concat, .alt => blk: {
                var s: usize = 0;
                for (t.kidsOf(n)) |k| s += t.size(k);
                break :blk s;
            },
            .repeat, .group, .flags => t.size(n.first),
            else => 0,
        };
    }

    /// Number capture groups 1.. in pre-order (= order of `(` in any printing) and set
    /// `n_groups`. Call after building or shrinking.
    pub fn renumberGroups(t: *Tree) void {
        var next: u8 = 0;
        t.renumberFrom(t.root, &next);
        t.n_groups = next;
    }

    fn renumberFrom(t: *Tree, i: u16, next: *u8) void {
        const n = t.nodes[i];
        switch (n.kind) {
            .group => {
                next.* += 1;
                t.nodes[i].b = next.*;
                t.renumberFrom(n.first, next);
            },
            .concat, .alt => for (t.kidsOf(n)) |k| t.renumberFrom(k, next),
            .repeat, .flags => t.renumberFrom(n.first, next),
            else => {},
        }
    }

    pub fn bytes(t: *const Tree) []const u8 {
        return std.mem.asBytes(t);
    }

    /// Deserialize + validate (tags are checked on the raw bytes BEFORE any enum field is
    /// read, since an out-of-range tag is illegal behaviour to load).
    pub fn fromBytes(b: []const u8) ?Tree {
        if (b.len != @sizeOf(Tree)) return null;
        for (0..max_nodes) |i| {
            const off = @offsetOf(Tree, "nodes") + i * @sizeOf(Node) + @offsetOf(Node, "kind");
            if (b[off] > @intFromEnum(Kind.flags)) return null;
        }
        for (0..max_items) |i| {
            const base = @offsetOf(Tree, "items") + i * @sizeOf(Item);
            if (b[base + @offsetOf(Item, "kind")] > @intFromEnum(ItemKind.prop)) return null;
            if (b[base + @offsetOf(Item, "neg")] > 1) return null;
        }
        var t: Tree = undefined;
        @memcpy(std.mem.asBytes(&t), b);
        return if (t.wellFormed()) t else null;
    }

    /// Structural validity. Children always have smaller indices than their parent
    /// (bottom-up construction), which also rules out cycles.
    pub fn wellFormed(t: *const Tree) bool {
        if (t.n_nodes == 0 or t.n_nodes > max_nodes or t.n_kids > max_kids or t.n_items > max_items) return false;
        if (t.root >= t.n_nodes or t.opt >= opt_sem.len or t.n_groups > max_groups) return false;
        for (t.nodes[0..t.n_nodes], 0..) |n, i| {
            switch (n.kind) {
                .concat, .alt => {
                    if (@as(usize, n.first) + n.len > t.n_kids) return false;
                    for (t.kidsOf(n)) |k| if (k >= i) return false;
                },
                .repeat, .group, .flags => if (n.first >= i) return false,
                .class => {
                    if (n.len == 0 or @as(usize, n.first) + n.len > t.n_items) return false;
                    for (t.itemsOf(n)) |it| switch (it.kind) {
                        .range => if (it.lo > it.hi or !isScalar(it.lo) or !isScalar(it.hi)) return false,
                        .perl => if (it.which > @intFromEnum(Perl.space)) return false,
                        .prop => if (it.which >= props.table.len) return false,
                    };
                },
                .assert => if (n.a > @intFromEnum(Assert.not_word_boundary)) return false,
                .lit => if (!isScalar(n.cp)) return false,
                .empty, .dot => {},
            }
            if (n.kind == .repeat and n.c != unbounded and n.b > n.c) return false;
        }
        return true;
    }
};

pub fn isScalar(cp: u32) bool {
    return cp <= 0x10FFFF and !(cp >= 0xD800 and cp <= 0xDFFF);
}

pub fn encodeUtf8(cp: u21, out: *[4]u8) u3 {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    }
    if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = @intCast(0xF0 | (cp >> 18));
    out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    out[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

// ══════════════════════════════════════════════════════════════════════════════
// Builder (tests, reference self-check, fuzz-min)
// ══════════════════════════════════════════════════════════════════════════════

/// Bottom-up construction; every node is stamped with `f` (set it before building a
/// flag-scoped subtree). `finish` renumbers groups in pre-order.
pub const Builder = struct {
    t: Tree,
    f: Flags,

    pub fn init(opt: u8) Builder {
        return .{ .t = Tree.init(opt), .f = opt_sem[opt].base };
    }
    pub fn empty(b: *Builder) u16 {
        return b.t.add(.{ .kind = .empty, .flags = b.f });
    }
    pub fn lit(b: *Builder, cp: u21) u16 {
        return b.t.add(.{ .kind = .lit, .flags = b.f, .cp = cp });
    }
    pub fn dot(b: *Builder) u16 {
        return b.t.add(.{ .kind = .dot, .flags = b.f });
    }
    pub fn assert(b: *Builder, k: Assert) u16 {
        return b.t.add(.{ .kind = .assert, .flags = b.f, .a = @intFromEnum(k) });
    }
    pub fn range(lo: u21, hi: u21) Item {
        return .{ .kind = .range, .lo = lo, .hi = hi };
    }
    pub fn perl(p: Perl, neg: bool) Item {
        return .{ .kind = .perl, .which = @intFromEnum(p), .neg = neg };
    }
    pub fn prop(short: []const u8, neg: bool) Item {
        return .{ .kind = .prop, .which = props.indexOf(short).?, .neg = neg };
    }
    pub fn class(b: *Builder, its: []const Item, negated: bool) u16 {
        const first = b.t.addItems(its) orelse return 0;
        return b.t.add(.{ .kind = .class, .flags = b.f, .a = @intFromBool(negated), .first = first, .len = @intCast(its.len) });
    }
    pub fn cat(b: *Builder, kids: []const u16) u16 {
        return b.t.addParent(.concat, b.f, kids);
    }
    pub fn alt(b: *Builder, kids: []const u16) u16 {
        return b.t.addParent(.alt, b.f, kids);
    }
    pub fn rep(b: *Builder, child: u16, min: u8, max: u8, greedy: bool) u16 {
        return b.t.add(.{ .kind = .repeat, .flags = b.f, .a = @intFromBool(greedy), .b = min, .c = max, .first = child });
    }
    pub fn star(b: *Builder, child: u16) u16 {
        return b.rep(child, 0, unbounded, true);
    }
    pub fn plus(b: *Builder, child: u16) u16 {
        return b.rep(child, 1, unbounded, true);
    }
    pub fn opt(b: *Builder, child: u16) u16 {
        return b.rep(child, 0, 1, true);
    }
    /// A capturing group; its index is assigned by `finish` (pre-order).
    pub fn group(b: *Builder, child: u16) u16 {
        return b.t.add(.{ .kind = .group, .flags = b.f, .first = child });
    }
    /// A flag scope: `child` must have been built with `b.f` already set to the result
    /// flags; this node carries the flags OUTSIDE the scope (`outer`).
    pub fn flags(b: *Builder, outer: Flags, set: Flags, clear: Flags, child: u16) u16 {
        return b.t.add(.{ .kind = .flags, .flags = outer, .a = @bitCast(set), .b = @bitCast(clear), .first = child });
    }
    pub fn finish(b: *Builder, root: u16) Tree {
        b.t.root = root;
        b.t.renumberGroups();
        return b.t;
    }
};

// ══════════════════════════════════════════════════════════════════════════════
// Smith generator
// ══════════════════════════════════════════════════════════════════════════════

/// Pick an option variant: defaults dominate (the common path), each other variant ~8%.
pub fn pickOpt(smith: *Smith) u8 {
    @disableInstrumentation();
    const r = smith.valueRangeAtMost(u8, 0, 11);
    return if (r < opt_sem.len) r else 0;
}

pub fn generate(smith: *Smith, opt: u8) Tree {
    @disableInstrumentation();
    var g: Gen = .{ .smith = smith, .t = Tree.init(opt) };
    g.t.root = g.alt(opt_sem[opt].base, 0);
    g.t.renumberGroups();
    return g.t;
}

const Gen = struct {
    smith: *Smith,
    t: Tree,

    fn roomy(g: *const Gen) bool {
        return g.t.n_nodes + 10 < max_nodes and g.t.n_kids + 8 < max_kids and g.t.n_items + 4 < max_items;
    }

    fn alt(g: *Gen, f: Flags, depth: u8) u16 {
        var br: [3]u16 = undefined;
        const want: usize = if (g.smith.valueRangeAtMost(u8, 0, 5) == 0) g.smith.valueRangeAtMost(u8, 2, 3) else 1;
        var n: usize = 0;
        while (n < want and (n == 0 or g.roomy())) : (n += 1) br[n] = g.concat(f, depth);
        return if (n == 1) br[0] else g.t.addParent(.alt, f, br[0..n]);
    }

    fn concat(g: *Gen, f: Flags, depth: u8) u16 {
        var xs: [5]u16 = undefined;
        const want = g.smith.valueRangeAtMost(u8, 0, 4);
        var n: usize = 0;
        while (n < want and g.roomy()) : (n += 1) xs[n] = g.quantified(f, depth);
        return switch (n) {
            0 => g.t.add(.{ .kind = .empty, .flags = f }),
            1 => xs[0],
            else => g.t.addParent(.concat, f, xs[0..n]),
        };
    }

    fn quantified(g: *Gen, f: Flags, depth: u8) u16 {
        const atom = g.atom(f, depth);
        if (g.smith.valueRangeAtMost(u8, 0, 2) != 0) return atom; // ~1/3 quantified
        var min: u8 = 0;
        var max: u8 = unbounded;
        switch (g.smith.valueRangeAtMost(u8, 0, 4)) {
            0 => {}, // *
            1 => min = 1, // +
            2 => max = 1, // ?
            3 => { // {m} / {m,n}
                min = g.smith.valueRangeAtMost(u8, 0, max_rep);
                max = g.smith.valueRangeAtMost(u8, min, max_rep);
            },
            else => min = g.smith.valueRangeAtMost(u8, 0, max_rep), // {m,}
        }
        const greedy = g.smith.valueRangeAtMost(u8, 0, 3) != 0;
        return g.t.add(.{ .kind = .repeat, .flags = f, .a = @intFromBool(greedy), .b = min, .c = max, .first = atom });
    }

    fn atom(g: *Gen, f: Flags, depth: u8) u16 {
        const nest = depth < max_depth and g.roomy();
        switch (g.smith.valueRangeAtMost(u8, 0, if (nest) 9 else 5)) {
            0, 1, 2 => return g.t.add(.{ .kind = .lit, .flags = f, .cp = g.pickCp() }),
            3 => return g.t.add(.{ .kind = .dot, .flags = f }),
            4 => return g.class(f),
            5 => return g.assertion(f),
            6, 7 => { // capturing group (index assigned by renumberGroups)
                const child = g.alt(f, depth + 1);
                return g.t.add(.{ .kind = .group, .flags = f, .first = child });
            },
            8 => return g.alt(f, depth + 1), // nested alternation — the printer groups it
            else => { // flag scope
                const set: Flags = @bitCast(g.smith.valueRangeAtMost(u8, 0, 7));
                const clear: Flags = @bitCast(g.smith.valueRangeAtMost(u8, 0, 7) & ~@as(u8, @bitCast(set)));
                const nf: Flags = .{
                    .i = (f.i or set.i) and !clear.i,
                    .m = (f.m or set.m) and !clear.m,
                    .s = (f.s or set.s) and !clear.s,
                };
                const child = g.alt(nf, depth + 1);
                return g.t.add(.{ .kind = .flags, .flags = f, .a = @bitCast(set), .b = @bitCast(clear), .first = child });
            },
        }
    }

    fn pickCp(g: *Gen) u21 {
        // 3:1 the small alphabet shared with haystacks (so matches happen), else a trap.
        if (g.smith.valueRangeAtMost(u8, 0, 3) != 0) return alphabet_cps[g.smith.index(alphabet_cps.len)];
        return trap_cps[g.smith.index(trap_cps.len)];
    }

    fn class(g: *Gen, f: Flags) u16 {
        var its: [3]Item = undefined;
        const n = g.smith.valueRangeAtMost(u8, 1, 3);
        for (its[0..n]) |*it| it.* = g.item();
        const first = g.t.addItems(its[0..n]) orelse return g.t.add(.{ .kind = .dot, .flags = f });
        const neg = g.smith.valueRangeAtMost(u8, 0, 3) == 0;
        return g.t.add(.{ .kind = .class, .flags = f, .a = @intFromBool(neg), .first = first, .len = n });
    }

    fn item(g: *Gen) Item {
        switch (g.smith.valueRangeAtMost(u8, 0, 4)) {
            0, 1 => {
                const a = g.pickCp();
                const b = g.pickCp();
                return .{ .kind = .range, .lo = @min(a, b), .hi = @max(a, b) };
            },
            2 => return .{ .kind = .perl, .which = g.smith.valueRangeAtMost(u8, 0, 2), .neg = g.smith.valueRangeAtMost(u8, 0, 2) == 0 },
            else => return .{ .kind = .prop, .which = @intCast(g.smith.index(props.table.len)), .neg = g.smith.valueRangeAtMost(u8, 0, 2) == 0 },
        }
    }

    fn assertion(g: *Gen, f: Flags) u16 {
        // The spelling decides the meaning under the flags in force: `^`/`$` are line
        // anchors only under `m`.
        const k: Assert = switch (g.smith.valueRangeAtMost(u8, 0, 5)) {
            0 => if (f.m) .line_start else .text_start, // ^
            1 => if (f.m) .line_end else .text_end, // $
            2 => .text_start, // \A
            3 => .text_end, // \z
            4 => .word_boundary,
            else => .not_word_boundary,
        };
        return g.t.add(.{ .kind = .assert, .flags = f, .a = @intFromEnum(k) });
    }
};
```

In `fuzz/check/common.zig`, add below `opt_variants`:

```zig
const tree = @import("../gen/tree.zig");
comptime {
    std.debug.assert(opt_variants.len == tree.opt_sem.len);
    for (opt_variants, tree.opt_sem) |o, s| {
        std.debug.assert(o.unicode == s.unicode);
        std.debug.assert((o.case_fold != .none) == s.fold);
        std.debug.assert(o.case_insensitive == s.base.i and o.multiline == s.base.m and o.dot_matches_newline == s.base.s);
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS (all five tree tests). If `KindUnreached` fires for `flags`/`group`, the `roomy` headroom is too tight for depth — lower the `+ 10` margin to `+ 8` and re-run.

- [ ] **Step 7: Commit**

```sh
git add fuzz/gen/props.zig fuzz/gen/tree.zig fuzz/check/common.zig fuzz/lib.zig
git commit -m "test(fuzz): semantic pattern tree — generator, builder, serialization"
```

---

### Task 6: `gen/print.zig` — canonical and randomized-equivalent printing

**Files:**
- Create: `fuzz/gen/print.zig`
- Modify: `fuzz/lib.zig`

**Interfaces:**
- Consumes: `tree.*`, `props.table`.
- Produces: `max_len = 1024`; `Printed{ buf, len, slice() }`; `canonical(*const Tree, opt_print: u8) ?Printed`; `variant(*const Tree, opt_print: u8, seed: u64) ?Printed` (`seed == 0` ⇒ canonical); `printLimited(*const Tree, opt_print, seed, limit) ?Printed`; `compatibleOpts(tree_opt, print_opt) bool`.
- Rewrites the printer may apply (each must be a no-op for the front end): literal as raw / `\x{H}` / `\u{h}` / `\xHH` (≤ U+FF) / `\uHHHH` (≤ U+FFFF) / named escape / `\cX` / `[c]`; single-item class printed bare (`[\d]`→`\d`, `[\p{L}]`→`\pL`); property short/long name; `(?:…)` wrappers; flags scoped, bare at a group-body start, pushed down to leaves, or seeded via `Options`; `(?x)` with whitespace/comments; `\A`↔`^`, `\z`↔`$`↔`\Z` (m off); `*`↔`{0,}`, `+`↔`{1,}`, `?`↔`{0,1}`, `{m}`↔`{m,m}`; for non-nullable, capture-free operands of ≤ 4 nodes: `x*`→`(?:x+)?`, `x{m,}`→`x…x x*`, `x{m,n}`→`x…x(?:x(?:x)?)?`; named ↔ numbered groups (`(?<nK>`, `(?P<nK>`).

- [ ] **Step 1: Write the failing tests** — create `fuzz/gen/print.zig` with imports and tests only:

```zig
const std = @import("std");
const tree = @import("tree.zig");
const Smith = std.testing.Smith;

fn canon(t: tree.Tree) ![]const u8 {
    const S = struct {
        var p: Printed = .{};
    };
    S.p = canonical(&t, t.opt) orelse return error.Overflow;
    return S.p.slice();
}

test "canonical spellings" {
    const B = tree.Builder;
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("\\.", try canon(b.finish(b.lit('.'))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("\xE2\x84\xAA", try canon(b.finish(b.lit(0x212A))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("[^a-c\\d]", try canon(b.finish(b.class(&.{ B.range('a', 'c'), B.perl(.digit, false) }, true))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("a{2,4}?", try canon(b.finish(b.rep(b.lit('a'), 2, 4, false))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("a(?:b|c)", try canon(b.finish(b.cat(&.{ b.lit('a'), b.alt(&.{ b.lit('b'), b.lit('c') }) }))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("(?:a*)?", try canon(b.finish(b.opt(b.star(b.lit('a'))))));
    }
    {
        var b = B.init(0);
        const outer = b.f;
        b.f.i = true;
        const inner = b.lit('a');
        try std.testing.expectEqualStrings("(?i:a)", try canon(b.finish(b.flags(outer, .{ .i = true }, .{}, inner))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("\\A\\z", try canon(b.finish(b.cat(&.{ b.assert(.text_start), b.assert(.text_end) }))));
    }
    {
        var b = B.init(4); // multiline seeded from Options
        try std.testing.expectEqualStrings("^b$", try canon(b.finish(b.cat(&.{ b.assert(.line_start), b.lit('b'), b.assert(.line_end) }))));
    }
    {
        var b = B.init(0);
        try std.testing.expectEqualStrings("(a)(b)", try canon(b.finish(b.cat(&.{ b.group(b.lit('a')), b.group(b.lit('b')) }))));
    }
}

test "printer overflow returns null, never a truncated pattern" {
    var b = tree.Builder.init(0);
    var kids: [8]u16 = undefined;
    for (&kids) |*k| k.* = b.lit(0x10FFFF);
    const t = b.finish(b.cat(&kids));
    try std.testing.expect(printLimited(&t, 0, 0, 16) == null);
    try std.testing.expect(printLimited(&t, 0, 0, max_len) != null);
}

test "every printing of generated trees compiles with the right capture count" {
    const gex = @import("ezi_gex");
    const common = @import("../check/common.zig");
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(23);
    var buf: [1024]u8 = undefined;
    var printed: usize = 0;
    for (0..1500) |iter| {
        prng.random().bytes(&buf);
        var s: Smith = .{ .in = &buf };
        const opt = tree.pickOpt(&s);
        const t = tree.generate(&s, opt);
        for ([_]u64{ 0, iter + 1, iter * 7919 + 3 }) |seed| {
            const pr = variant(&t, opt, seed) orelse continue;
            printed += 1;
            var diag: gex.Diagnostic = .{};
            var re = common.compileVariant(gex.backends.pikevm, gpa, pr.slice(), &diag, opt) catch |e| {
                std.debug.print("printed tree failed to compile ({s}, {s}): /{s}/ seed={d}\n", .{ @errorName(e), @tagName(diag.code), pr.slice(), seed });
                return error.PrintedPatternRejected;
            };
            defer re.deinit();
            if (re.captureCount() != t.n_groups) {
                std.debug.print("capture count {d} != tree groups {d}: /{s}/\n", .{ re.captureCount(), t.n_groups, pr.slice() });
                return error.CaptureCountMismatch;
            }
        }
    }
    try std.testing.expect(printed > 4000);
}

test "compatibleOpts" {
    try std.testing.expect(compatibleOpts(0, 3) and compatibleOpts(3, 5) and compatibleOpts(4, 0));
    try std.testing.expect(!compatibleOpts(0, 1) and !compatibleOpts(2, 0) and compatibleOpts(1, 1));
}
```

Add `pub const print = @import("gen/print.zig");` to `gen` in `fuzz/lib.zig` and `_ = @import("gen/print.zig");` to its test block.

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile — `use of undeclared identifier 'Printed'`.

- [ ] **Step 3: Implement the printer** (above the tests)

```zig
//! Tree → pattern text, canonically or through randomized EQUIVALENT spellings.
//!
//! Every randomized choice is a rewrite the ezi_gex front end must treat as a no-op; two
//! printings of one tree are the metamorphic check's pair, and the canonical printing is
//! what reports and `fuzz-min` show. The printer tracks the flags in force in the text it
//! has written (`pf`; the lexical `x` as `px`) and, wherever a node's own flags differ,
//! opens a scoped `(?…:…)` — or, at the start of a group body, a bare `(?…)` toggle — so
//! flags can be scoped, bare, pushed down to leaves, or seeded via `Options` without
//! changing the meaning.

const props = @import("props.zig");
const Tree = tree.Tree;
const Node = tree.Node;
const Item = tree.Item;
const Flags = tree.Flags;

pub const max_len = 1024;

pub const Printed = struct {
    buf: [max_len]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Printed) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Deterministic printing.
pub fn canonical(t: *const Tree, opt_print: u8) ?Printed {
    return printLimited(t, opt_print, 0, max_len);
}

/// Randomized equivalent printing (`seed == 0` ⇒ canonical). `opt_print` is the option
/// variant the text will be compiled with; it must satisfy `compatibleOpts(t.opt, opt_print)`.
pub fn variant(t: *const Tree, opt_print: u8, seed: u64) ?Printed {
    return printLimited(t, opt_print, seed, max_len);
}

/// Only the Options-seeded base flags may differ between the tree's variant and the
/// printing's — the printer re-establishes each node's flags inline.
pub fn compatibleOpts(tree_opt: u8, print_opt: u8) bool {
    const a = tree.opt_sem[tree_opt];
    const b = tree.opt_sem[print_opt];
    return a.unicode == b.unicode and a.fold == b.fold;
}

/// `null` when the text would exceed `limit` bytes — never a truncated pattern.
pub fn printLimited(t: *const Tree, opt_print: u8, seed: u64, limit: usize) ?Printed {
    std.debug.assert(limit <= max_len);
    std.debug.assert(compatibleOpts(t.opt, opt_print));
    var out: Printed = .{};
    var prng = std.Random.DefaultPrng.init(seed);
    var p: P = .{
        .t = t,
        .out = &out,
        .limit = limit,
        .rng = if (seed == 0) null else prng.random(),
        .pf = tree.opt_sem[opt_print].base,
    };
    p.body(t.root);
    if (p.overflow) return null;
    return out;
}

const Ctx = enum { top, elem, operand };

fn isComposite(k: tree.Kind) bool {
    return switch (k) {
        .empty, .concat, .alt, .repeat, .group, .flags => true,
        else => false,
    };
}

fn isMeta(c: u8) bool {
    return std.mem.indexOfScalar(u8, ".^$|?*+()[]{}\\", c) != null;
}

fn namedEscape(cp: u21) ?[]const u8 {
    return switch (cp) {
        0x0A => "\\n",
        0x0D => "\\r",
        0x09 => "\\t",
        0x0C => "\\f",
        0x0B => "\\v",
        0x07 => "\\a",
        0x1B => "\\e",
        0x00 => "\\0",
        else => null,
    };
}

fn canExpand(t: *const Tree, n: Node) bool {
    return !t.nullable(n.first) and !t.hasCapture(n.first) and t.size(n.first) <= 4;
}

const P = struct {
    t: *const Tree,
    out: *Printed,
    limit: usize,
    rng: ?std.Random,
    pf: Flags,
    px: bool = false,
    overflow: bool = false,

    fn chance(p: *P, num: u32, den: u32) bool {
        const r = p.rng orelse return false;
        return r.uintLessThan(u32, den) < num;
    }

    fn pick(p: *P, n: u8) u8 {
        const r = p.rng orelse return 0;
        return r.uintLessThan(u8, n);
    }

    fn put(p: *P, c: u8) void {
        if (p.out.len >= p.limit) {
            p.overflow = true;
            return;
        }
        p.out.buf[p.out.len] = c;
        p.out.len += 1;
    }

    fn puts(p: *P, s: []const u8) void {
        for (s) |c| p.put(c);
    }

    fn printf(p: *P, comptime fmt: []const u8, args: anytype) void {
        var b: [48]u8 = undefined;
        p.puts(std.fmt.bufPrint(&b, fmt, args) catch unreachable);
    }

    fn raw(p: *P, cp: u21) void {
        var b: [4]u8 = undefined;
        p.puts(b[0..tree.encodeUtf8(cp, &b)]);
    }

    /// Insignificant text between concat elements / around `|`, only while `x` is on.
    fn junk(p: *P) void {
        if (!p.px or !p.chance(1, 3)) return;
        switch (p.pick(3)) {
            0 => p.put(' '),
            1 => p.puts("\t "),
            else => p.puts(" #c\n"),
        }
    }

    /// Emit `(?adds-removes` + `term`, moving the text's flags from (pf, px) to (want, want_x).
    fn toggle(p: *P, want: Flags, want_x: bool, term: u8) void {
        p.puts("(?");
        if (want.i and !p.pf.i) p.put('i');
        if (want.m and !p.pf.m) p.put('m');
        if (want.s and !p.pf.s) p.put('s');
        if (want_x and !p.px) p.put('x');
        const ri = !want.i and p.pf.i;
        const rm = !want.m and p.pf.m;
        const rs = !want.s and p.pf.s;
        const rx = !want_x and p.px;
        if (ri or rm or rs or rx) {
            p.put('-');
            if (ri) p.put('i');
            if (rm) p.put('m');
            if (rs) p.put('s');
            if (rx) p.put('x');
        }
        p.put(term);
        p.pf = want;
        p.px = want_x;
    }

    /// Node `i` as the whole body of a group or the pattern: alternation needs no grouping,
    /// and a bare `(?…)` toggle may set flags for the rest of the body.
    fn body(p: *P, i: u16) void {
        const n = p.t.nodes[i];
        if (p.rng != null) {
            const want_x = p.px or p.chance(1, 8);
            const differs = !n.flags.eql(p.pf) or want_x != p.px;
            // A bare toggle must change something — `(?)` is `empty_flag_group`.
            if (differs and p.chance(1, 2)) p.toggle(n.flags, want_x, ')');
        }
        p.node(i, .top);
    }

    fn node(p: *P, i: u16, ctx: Ctx) void {
        const n = p.t.nodes[i];
        if (!n.flags.eql(p.pf)) {
            // Composites have no flag-dependent syntax: optionally push the mismatch down
            // to their children instead of scoping here.
            if (isComposite(n.kind) and p.chance(1, 3)) return p.inner(i, ctx);
            return p.scoped(i, n.flags);
        }
        if (p.chance(1, 12)) return p.scoped(i, n.flags); // gratuitous (?:…) / (?x:…)
        p.inner(i, ctx);
    }

    /// `(?toggle:` node `)` — an atom in any context.
    fn scoped(p: *P, i: u16, want: Flags) void {
        const sf = p.pf;
        const sx = p.px;
        const want_x = if (p.px) !p.chance(1, 4) else p.chance(1, 6);
        p.toggle(want, want_x, ':');
        p.inner(i, .top);
        p.put(')');
        p.pf = sf;
        p.px = sx;
    }

    fn inner(p: *P, i: u16, ctx: Ctx) void {
        const n = p.t.nodes[i];
        switch (n.kind) {
            .empty => if (ctx == .operand) p.puts("(?:)"),
            .lit => p.literal(@intCast(n.cp)),
            .dot => p.put('.'),
            .class => p.class(n),
            .assert => p.assertion(n),
            .concat => p.concat(n, ctx),
            .alt => p.alt(n, ctx),
            .repeat => p.repeat(n, ctx),
            .group => p.group(n),
            .flags => p.node(n.first, ctx),
        }
    }

    fn concat(p: *P, n: Node, ctx: Ctx) void {
        const wrap = ctx == .operand;
        const sf = p.pf;
        const sx = p.px;
        if (wrap) p.puts("(?:");
        for (p.t.kidsOf(n), 0..) |k, j| {
            if (j > 0) p.junk();
            p.node(k, .elem);
        }
        if (wrap) {
            p.put(')');
            p.pf = sf;
            p.px = sx;
        }
    }

    fn alt(p: *P, n: Node, ctx: Ctx) void {
        const wrap = ctx != .top;
        const sf = p.pf;
        const sx = p.px;
        if (wrap) p.puts("(?:");
        for (p.t.kidsOf(n), 0..) |k, j| {
            if (j > 0) {
                p.junk();
                p.put('|');
                p.junk();
            }
            p.node(k, .top);
        }
        if (wrap) {
            p.put(')');
            p.pf = sf;
            p.px = sx;
        }
    }

    fn repeat(p: *P, n: Node, ctx: Ctx) void {
        const wrap = ctx == .operand; // `a**` is `multiple_quantifiers`
        const sf = p.pf;
        const sx = p.px;
        if (wrap) p.puts("(?:");
        const greedy = n.a != 0;
        if (p.rng != null and canExpand(p.t, n) and p.chance(1, 4)) {
            p.expand(n, greedy);
        } else {
            p.node(n.first, .operand);
            p.quant(n.b, n.c, greedy);
        }
        if (wrap) {
            p.put(')');
            p.pf = sf;
            p.px = sx;
        }
    }

    fn quant(p: *P, min: u8, max: u8, greedy: bool) void {
        const unb = max == tree.unbounded;
        const canon = p.rng == null or p.chance(1, 2);
        if (canon and unb and min == 0) {
            p.put('*');
        } else if (canon and unb and min == 1) {
            p.put('+');
        } else if (canon and !unb and min == 0 and max == 1) {
            p.put('?');
        } else if (unb) {
            p.printf("{{{d},}}", .{min});
        } else if (min == max and (canon or p.chance(1, 2))) {
            p.printf("{{{d}}}", .{min});
        } else {
            p.printf("{{{d},{d}}}", .{ min, max });
        }
        if (!greedy) p.put('?');
    }

    /// Structural rewrites for a non-nullable, capture-free, small operand.
    fn expand(p: *P, n: Node, greedy: bool) void {
        const lazy: []const u8 = if (greedy) "" else "?";
        const min = n.b;
        const max = n.c;
        if (max == tree.unbounded and min == 0) { // x* ≡ (?:x+)?
            p.puts("(?:");
            p.node(n.first, .operand);
            p.put('+');
            p.puts(lazy);
            p.puts(")?");
            p.puts(lazy);
            return;
        }
        var k: u8 = 0;
        while (k < min) : (k += 1) p.node(n.first, .operand); // m copies
        if (max == tree.unbounded) { // x{m,} ≡ x…x x*
            p.node(n.first, .operand);
            p.put('*');
            p.puts(lazy);
            return;
        }
        // x{m,n} ≡ x…x (?:x(?:x)?)?  — (n−m) nested optionals, as Rust compiles it
        k = 0;
        while (k < max - min) : (k += 1) {
            p.puts("(?:");
            p.node(n.first, .elem);
        }
        k = 0;
        while (k < max - min) : (k += 1) {
            p.puts(")?");
            p.puts(lazy);
        }
    }

    fn group(p: *P, n: Node) void {
        const sf = p.pf;
        const sx = p.px;
        switch (p.pick(3)) {
            0 => p.put('('),
            1 => p.printf("(?<n{d}>", .{n.b}),
            else => p.printf("(?P<n{d}>", .{n.b}),
        }
        p.body(n.first);
        p.put(')');
        p.pf = sf;
        p.px = sx;
    }

    fn assertion(p: *P, n: Node) void {
        const k: tree.Assert = @enumFromInt(n.a);
        p.puts(switch (k) {
            .text_start => if (!p.pf.m and p.chance(1, 2)) "^" else "\\A",
            .text_end => if (!p.pf.m and p.chance(1, 3)) "$" else if (p.chance(1, 2)) "\\Z" else "\\z",
            .line_start => "^", // node flags == pf here, and the generator only makes it under m
            .line_end => "$",
            .word_boundary => "\\b",
            .not_word_boundary => "\\B",
        });
    }

    fn literal(p: *P, cp: u21) void {
        if (p.rng != null) switch (p.pick(9)) {
            0 => return p.printf("\\x{{{X}}}", .{cp}),
            1 => return p.printf("\\u{{{x}}}", .{cp}),
            2 => if (cp <= 0xFF) return p.printf("\\x{X:0>2}", .{cp}),
            3 => if (cp <= 0xFFFF) return p.printf("\\u{x:0>4}", .{cp}),
            4 => if (namedEscape(cp)) |e| return p.puts(e),
            5 => {
                p.put('[');
                p.classLit(cp);
                p.put(']');
                return;
            },
            6 => if (cp >= 1 and cp <= 26) {
                const base: u8 = if (p.chance(1, 2)) '@' else '`';
                return p.printf("\\c{c}", .{base + @as(u8, @intCast(cp))});
            },
            else => {},
        };
        p.plainLit(cp);
    }

    fn plainLit(p: *P, cp: u21) void {
        if (cp < 0x80) {
            const c: u8 = @intCast(cp);
            if (isMeta(c) or (p.px and c == '#')) {
                p.put('\\');
                return p.put(c);
            }
            if (p.px and c == ' ') return p.puts("\\ ");
            if (c < 0x20 or c == 0x7F) return p.printf("\\x{{{X}}}", .{cp}); // controls (incl. \t \n)
            return p.put(c);
        }
        p.raw(cp);
    }

    fn class(p: *P, n: Node) void {
        const its = p.t.itemsOf(n);
        if (n.a == 0 and its.len == 1 and its[0].kind != .range and p.chance(1, 2)) {
            return p.classItem(its[0]); // `[\d]` ≡ `\d`, `[\p{L}]` ≡ `\p{L}`
        }
        p.put('[');
        if (n.a != 0) p.put('^');
        for (its) |it| p.classItem(it);
        p.put(']');
    }

    fn classItem(p: *P, it: Item) void {
        switch (it.kind) {
            .range => {
                p.classLit(@intCast(it.lo));
                if (it.hi != it.lo) {
                    p.put('-');
                    p.classLit(@intCast(it.hi));
                }
            },
            .perl => {
                const c = "dws"[it.which];
                p.put('\\');
                p.put(if (it.neg) std.ascii.toUpper(c) else c);
            },
            .prop => {
                const pr = props.table[it.which];
                const name = if (p.chance(1, 2)) pr.long else pr.short;
                if (name.len == 1 and p.chance(1, 2)) {
                    p.put('\\');
                    p.put(if (it.neg) 'P' else 'p');
                    return p.puts(name); // `\pL`
                }
                p.puts(if (it.neg) "\\P{" else "\\p{");
                p.puts(name);
                p.put('}');
            },
        }
    }

    /// A code point inside `[...]`: `]` `\` `[` `-` `^` are escaped (so `[` never forms
    /// `[:` and `-` never forms a range); controls use `\x{…}`.
    fn classLit(p: *P, cp: u21) void {
        if (p.rng != null) switch (p.pick(4)) {
            0 => return p.printf("\\x{{{X}}}", .{cp}),
            1 => return p.printf("\\u{{{x}}}", .{cp}),
            2 => if (cp <= 0xFF) return p.printf("\\x{X:0>2}", .{cp}),
            else => {},
        };
        if (cp < 0x80) {
            const c: u8 = @intCast(cp);
            if (std.mem.indexOfScalar(u8, "]\\[-^", c) != null) {
                p.put('\\');
                return p.put(c);
            }
            if (c < 0x20 or c == 0x7F) return p.printf("\\x{{{X}}}", .{cp});
            return p.put(c);
        }
        p.raw(cp);
    }
};
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS. If `PrintedPatternRejected` fires, decide which side is wrong from the printed pattern:
the printer (fix the printer) or the scanner rejecting a documented-valid spelling (a finding: add it to
`fuzz/README.md` → *Open (to triage)*, then stop the printer from emitting that one spelling, with a comment citing
the README entry).

- [ ] **Step 5: Commit**

```sh
git add fuzz/gen/print.zig fuzz/lib.zig
git commit -m "test(fuzz): tree printer with randomized equivalent spellings"
```

---

## Phase C — The independent reference matcher

### Task 7: `ref/uni.zig` — strict UTF-8, per-code-point predicates, fold orbits

**Files:**
- Create: `fuzz/ref/uni.zig`
- Modify: `fuzz/lib.zig`

**Interfaces:**
- Consumes: `ezi_code.unicode.{properties, scripts, casing}` point lookups; `gen/props.zig`; `gen/tree.zig` (`Tree`, `Node`, `Item`, `Perl`, `OptSem`).
- Produces: `Decoded{ cp: u21, len: u8, valid: bool }`; `decode(s, i) Decoded`; `decodeBefore(s, i) ?Decoded`; `isWord(u21) bool`; `perl(tree.Perl, u21, unicode: bool) bool`; `prop(which: u8, u21) bool`; `fold(u21) u21`; `orbit(u21, *[8]u21) []const u21`; `litMatches(x, c, ci) bool`; `classMatches(*const Tree, Node, u21, OptSem) bool`; `charMatches(*const Tree, Node, u21, OptSem) bool`.
- Independence rule: this file never imports `ezi_gex` and never uses `ezi_code`'s range tables (`*_runs`, `*_ranges`) — only per-code-point queries.

- [ ] **Step 1: Write the failing tests** — create `fuzz/ref/uni.zig` with imports + tests:

```zig
const std = @import("std");
const ez = @import("ezi_code");
const P = ez.unicode.properties;
const S = ez.unicode.scripts;
const casing = ez.unicode.casing;
const props = @import("../gen/props.zig");
const tree = @import("../gen/tree.zig");
const testing = std.testing;

test "decode: valid and every flavour of malformed" {
    const V = struct { s: []const u8, cp: u21, len: u8 };
    for ([_]V{
        .{ .s = "a", .cp = 'a', .len = 1 },
        .{ .s = "\xC3\xA9", .cp = 0xE9, .len = 2 },
        .{ .s = "\xE2\x84\xAA", .cp = 0x212A, .len = 3 },
        .{ .s = "\xF0\x90\x90\x80", .cp = 0x10400, .len = 4 },
        .{ .s = "\xEF\xBF\xBD", .cp = 0xFFFD, .len = 3 },
    }) |v| {
        const d = decode(v.s, 0);
        try testing.expect(d.valid);
        try testing.expectEqual(v.cp, d.cp);
        try testing.expectEqual(v.len, d.len);
    }
    for ([_][]const u8{
        "\xC3", "\xE6\x97", "\xF0\x9F\x98", "\x80", "\xBF", "\xC0\x80", "\xC1\xBF", "\xE0\x80\x80",
        "\xF0\x80\x80\x80", "\xED\xA0\x80", "\xED\xBF\xBF", "\xF4\x90\x80\x80", "\xF5\x80\x80\x80", "\xFF", "\xE6a",
    }) |s| {
        const d = decode(s, 0);
        try testing.expect(!d.valid);
        try testing.expectEqual(@as(u8, 1), d.len);
    }
}

test "decodeBefore" {
    try testing.expect(decodeBefore("ab", 0) == null);
    try testing.expectEqual(@as(u21, 'a'), decodeBefore("ab", 1).?.cp);
    try testing.expectEqual(@as(u21, 0xE9), decodeBefore("a\xC3\xA9", 3).?.cp);
    try testing.expect(!decodeBefore("\xC3", 1).?.valid);
    try testing.expect(!decodeBefore("\x80", 1).?.valid);
    try testing.expect(!decodeBefore("a\xC3\xA9", 2).?.valid); // ends mid-sequence
}

test "predicates" {
    try testing.expect(isWord('_') and isWord(0x0663) and isWord(0x200D) and isWord(0x0301) and !isWord(' '));
    try testing.expect(perl(.space, 0x3000, true) and !perl(.space, 0x3000, false));
    try testing.expect(perl(.digit, 0x0663, true) and !perl(.digit, 0x0663, false));
    try testing.expect(perl(.space, 0x0B, false) and !perl(.word, 0xE9, false) and perl(.word, 0xE9, true));
    for (props.table, 0..) |p, i| {
        if (!prop(@intCast(i), p.sample)) {
            std.debug.print("props.table[{d}] {s}: sample U+{X:0>4} not a member\n", .{ i, p.long, p.sample });
            return error.BadPropSample;
        }
    }
}

test "fold orbits" {
    var buf: [8]u21 = undefined;
    const has = struct {
        fn f(o: []const u21, c: u21) bool {
            return std.mem.indexOfScalar(u21, o, c) != null;
        }
    }.f;
    const k = orbit('k', &buf);
    try testing.expect(has(k, 'K') and has(k, 'k') and has(k, 0x212A));
    const sig = orbit(0x03C2, &buf);
    try testing.expect(has(sig, 0x03A3) and has(sig, 0x03C3) and has(sig, 0x03C2));
    try testing.expectEqual(@as(usize, 1), orbit('1', &buf).len);
}

test "class membership follows Rust's rule under (?i)" {
    const B = tree.Builder;
    var b = B.init(3); // (?i) via Options
    const neg_a = b.class(&.{B.range('a', 'a')}, true); // (?i)[^a]
    const not_lu = b.class(&.{B.prop("Lu", true)}, false); // (?i)[\P{Lu}]
    const t = b.finish(b.cat(&.{ neg_a, not_lu }));
    const sem = tree.opt_sem[3];
    try testing.expect(!classMatches(&t, t.nodes[neg_a], 'A', sem)); // negation applied after closure
    try testing.expect(classMatches(&t, t.nodes[neg_a], 'b', sem));
    try testing.expect(classMatches(&t, t.nodes[not_lu], 'A', sem)); // item negation before closure: 'a' ∈ \P{Lu}
}
```

Add to `fuzz/lib.zig`: `pub const ref = struct { pub const uni = @import("ref/uni.zig"); };` and `_ = @import("ref/uni.zig");` in its test block.

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile — `use of undeclared identifier 'decode'`.

- [ ] **Step 3: Implement** (between the imports and the tests)

```zig
//! Reference-side Unicode: a strict, table-free UTF-8 decoder (dead-on-invalid), and
//! per-code-point predicates evaluated through ezi_code's POINT lookups — never
//! ezi_gex's code and never the enumerable range tables ezi_gex's HIR is built from —
//! plus simple-case-fold orbits for `(?i)`.

pub const Decoded = struct { cp: u21, len: u8, valid: bool };
const bad: Decoded = .{ .cp = 0xFFFD, .len = 1, .valid = false };

/// Strict decode at `i` (`i < s.len`). Overlong forms, surrogates, > U+10FFFF, stray
/// continuations and truncated sequences are invalid, consuming one byte.
pub fn decode(s: []const u8, i: usize) Decoded {
    const b0 = s[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1, .valid = true };
    var need: usize = undefined;
    var min: u32 = undefined;
    var cp: u32 = undefined;
    if (b0 >= 0xC2 and b0 <= 0xDF) {
        need = 1;
        min = 0x80;
        cp = b0 & 0x1F;
    } else if (b0 >= 0xE0 and b0 <= 0xEF) {
        need = 2;
        min = 0x800;
        cp = b0 & 0x0F;
    } else if (b0 >= 0xF0 and b0 <= 0xF4) {
        need = 3;
        min = 0x10000;
        cp = b0 & 0x07;
    } else return bad;
    if (s.len - i <= need) return bad;
    for (s[i + 1 .. i + 1 + need]) |c| {
        if (c & 0xC0 != 0x80) return bad;
        cp = (cp << 6) | (c & 0x3F);
    }
    if (cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return bad;
    return .{ .cp = @intCast(cp), .len = @intCast(need + 1), .valid = true };
}

/// The scalar ending exactly at byte `i` (for `\b`), `null` at the start of input. Any
/// malformed tail decodes as `valid = false` (a non-word character).
pub fn decodeBefore(s: []const u8, i: usize) ?Decoded {
    if (i == 0) return null;
    var j = i;
    var steps: usize = 0;
    while (j > 0 and steps < 4) {
        j -= 1;
        steps += 1;
        if (s[j] & 0xC0 != 0x80) {
            const d = decode(s, j);
            return if (d.valid and j + d.len == i) d else bad;
        }
    }
    return bad;
}

/// `\w` (Unicode): Alphabetic ∪ Mark ∪ Decimal_Number ∪ Connector_Punctuation ∪ Join_Control.
pub fn isWord(cp: u21) bool {
    if (P.isAlphabetic(cp) or P.isJoinControl(cp)) return true;
    return switch (P.generalCategory(cp)) {
        .decimal_number, .non_spacing_mark, .spacing_mark, .enclosing_mark, .connector_punctuation => true,
        else => false,
    };
}

fn isAsciiWord(cp: u21) bool {
    return (cp >= '0' and cp <= '9') or (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or cp == '_';
}

pub fn perl(p: tree.Perl, cp: u21, unicode: bool) bool {
    return switch (p) {
        .digit => if (unicode) P.generalCategory(cp) == .decimal_number else cp >= '0' and cp <= '9',
        .word => if (unicode) isWord(cp) else isAsciiWord(cp),
        .space => if (unicode) P.isWhitespace(cp) else (cp >= 0x09 and cp <= 0x0D) or cp == ' ',
    };
}

fn inGroup(gc: P.GeneralCategory, g: props.Group) bool {
    return switch (g) {
        .letter => switch (gc) {
            .uppercase_letter, .lowercase_letter, .titlecase_letter, .modifier_letter, .other_letter => true,
            else => false,
        },
        .cased_letter => switch (gc) {
            .uppercase_letter, .lowercase_letter, .titlecase_letter => true,
            else => false,
        },
        .mark => switch (gc) {
            .non_spacing_mark, .spacing_mark, .enclosing_mark => true,
            else => false,
        },
        .number => switch (gc) {
            .decimal_number, .letter_number, .other_number => true,
            else => false,
        },
        .punctuation => switch (gc) {
            .connector_punctuation, .dash_punctuation, .open_punctuation, .close_punctuation, .initial_punctuation, .final_punctuation, .other_punctuation => true,
            else => false,
        },
        .symbol => switch (gc) {
            .math_symbol, .currency_symbol, .modifier_symbol, .other_symbol => true,
            else => false,
        },
        .separator => switch (gc) {
            .space_separator, .line_separator, .paragraph_separator => true,
            else => false,
        },
        .other => switch (gc) {
            .control, .format, .surrogate, .private_use, .unassigned => true,
            else => false,
        },
    };
}

pub fn prop(which: u8, cp: u21) bool {
    return switch (props.table[which].sem) {
        .gc => |g| P.generalCategory(cp) == g,
        .group => |g| inGroup(P.generalCategory(cp), g),
        .derived => |d| P.hasDerivedProperty(cp, d),
        .script => |sc| S.scriptType(cp) == sc,
    };
}

pub fn fold(cp: u21) u21 {
    return casing.caseFoldSimple(cp);
}

const Pair = struct { to: u21, from: u21 };
var inverse: [4096]Pair = undefined;
var inverse_len: usize = 0;
var inverse_built = false;

fn buildInverse() void {
    var n: usize = 0;
    var cp: u32 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue;
        const c: u21 = @intCast(cp);
        const f = fold(c);
        if (f == c) continue;
        if (n == inverse.len) @panic("ref/uni: fold inverse table too small");
        inverse[n] = .{ .to = f, .from = c };
        n += 1;
    }
    std.mem.sortUnstable(Pair, inverse[0..n], {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.to < b.to or (a.to == b.to and a.from < b.from);
        }
    }.lt);
    inverse_len = n;
    inverse_built = true;
}

/// Every code point whose simple fold equals `cp`'s (`cp` included). The inverse table is
/// built on first use — not thread-safe then (the fuzz bodies are single-threaded).
pub fn orbit(cp: u21, out: *[8]u21) []const u21 {
    if (!inverse_built) buildInverse();
    const f = fold(cp);
    out[0] = f;
    var n: usize = 1;
    var lo: usize = 0;
    var hi: usize = inverse_len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (inverse[mid].to < f) lo = mid + 1 else hi = mid;
    }
    while (lo < inverse_len and inverse[lo].to == f and n < out.len) : (lo += 1) {
        out[n] = inverse[lo].from;
        n += 1;
    }
    return out[0..n];
}

pub fn litMatches(x: u21, c: u21, ci: bool) bool {
    return if (ci) fold(x) == fold(c) else x == c;
}

fn itemsMatch(t: *const tree.Tree, n: tree.Node, y: u21, unicode: bool) bool {
    for (t.itemsOf(n)) |it| {
        const base = switch (it.kind) {
            .range => y >= it.lo and y <= it.hi,
            .perl => perl(@enumFromInt(it.which), y, unicode),
            .prop => prop(it.which, y),
        };
        if (base != it.neg) return true;
    }
    return false;
}

/// Rust's rule: each item's own negation applies first; under `(?i)` the union is closed
/// over simple-fold orbits; the class's `[^…]` applies last.
pub fn classMatches(t: *const tree.Tree, n: tree.Node, c: u21, sem: tree.OptSem) bool {
    const ci = n.flags.i and sem.fold;
    var hit = false;
    if (ci) {
        var ob: [8]u21 = undefined;
        for (orbit(c, &ob)) |y| {
            if (itemsMatch(t, n, y, sem.unicode)) {
                hit = true;
                break;
            }
        }
    } else hit = itemsMatch(t, n, c, sem.unicode);
    return hit != (n.a != 0);
}

/// Does the consuming node `n` (lit / dot / class) accept scalar `c`?
pub fn charMatches(t: *const tree.Tree, n: tree.Node, c: u21, sem: tree.OptSem) bool {
    return switch (n.kind) {
        .lit => litMatches(@intCast(n.cp), c, n.flags.i and sem.fold),
        .dot => c != '\n' or n.flags.s,
        .class => classMatches(t, n, c, sem),
        else => unreachable,
    };
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS. (`BadPropSample` means a `props.table` sample is wrong — fix the sample, not the predicate.)

- [ ] **Step 5: Commit**

```sh
git add fuzz/ref/uni.zig fuzz/lib.zig
git commit -m "test(fuzz): reference-side UTF-8 decoding, Unicode predicates, fold orbits"
```

---

### Task 8: `ref/nfa.zig` + `ref/pike.zig` + `ref/root.zig` — the reference matcher

**Files:**
- Create: `fuzz/ref/nfa.zig`, `fuzz/ref/pike.zig`, `fuzz/ref/root.zig`
- Modify: `fuzz/lib.zig` (`ref` becomes `@import("ref/root.zig")`)

**Interfaces:**
- Produces (`nfa`): `Op`, `Inst{ op, x, y, arg }`, `max_insts = 20_000`, `Prog{ insts, start, n_slots, deinit(gpa) }`, `compile(gpa, *const Tree) !Prog` (`error.ProgramTooBig` past `max_insts`).
- Produces (`pike`): `Search{ start = 0, anchored = false, span_end: ?usize = null }`, `Vm{ gpa, prog, t, sem }.search(input, Search, slots_out) !bool`, `assertHolds(tree.Assert, input, at) bool`.
- Produces (`ref` = `ref/root.zig`): `uni`, `nfa`, `pike` re-exports; `max_slots = 32`; `Ref{ init(gpa, *const Tree) !Ref, deinit(), slotCount() usize, find(input, pike.Search, slots) !?[2]usize, findAll(input, *std.ArrayList([2]usize), max) !void }`.
- `findAll`'s empty-match bump: one **scalar** on (decoded length when valid, one byte over a malformed byte) — the reference's reading of "dead-on-invalid, resync one byte".

- [ ] **Step 1: Write the failing tests** — create `fuzz/ref/root.zig` with only the imports and tests:

```zig
const std = @import("std");
const tree = @import("../gen/tree.zig");
const testing = std.testing;
const B = tree.Builder;

fn expectFind(t: tree.Tree, input: []const u8, so: pike.Search, want: ?[2]usize) !void {
    var r = try Ref.init(testing.allocator, &t);
    defer r.deinit();
    var slots: [max_slots]?usize = undefined;
    const got = try r.find(input, so, slots[0..r.slotCount()]);
    if ((got == null) != (want == null) or (got != null and (got.?[0] != want.?[0] or got.?[1] != want.?[1]))) {
        std.debug.print("ref: input \"{s}\" so={any}: want {?any} got {?any}\n", .{ input, so, want, got });
        return error.RefMismatch;
    }
}

test "leftmost-first alternation and laziness" {
    var b = B.init(0);
    try expectFind(b.finish(b.alt(&.{ b.lit('a'), b.cat(&.{ b.lit('a'), b.lit('b') }) })), "ab", .{}, .{ 0, 1 });
    b = B.init(0);
    try expectFind(b.finish(b.rep(b.lit('a'), 1, tree.unbounded, false)), "aaa", .{}, .{ 0, 1 });
    b = B.init(0);
    try expectFind(b.finish(b.rep(b.lit('a'), 2, 3, true)), "aaaa", .{}, .{ 0, 3 });
}

test "RE2/Rust empty-width loops (the 0.6.0 semantics)" {
    var b = B.init(0);
    try expectFind(b.finish(b.plus(b.alt(&.{ b.empty(), b.dot() }))), "c", .{}, .{ 0, 0 }); // (?:|.)+
    b = B.init(0);
    try expectFind(b.finish(b.star(b.group(b.alt(&.{ b.empty(), b.lit('a') })))), "aaa", .{}, .{ 0, 0 }); // (|a)*
    b = B.init(0);
    try expectFind(b.finish(b.plus(b.cat(&.{ b.opt(b.lit('a')), b.rep(b.lit('b'), 0, 1, false) }))), "ab", .{}, .{ 0, 1 }); // (?:a?b??)+
    b = B.init(0);
    try expectFind(b.finish(b.plus(b.cat(&.{ b.rep(b.lit('a'), 0, 1, false), b.rep(b.lit('b'), 0, 1, false) }))), "ab", .{}, .{ 0, 0 }); // (?:a??b??)+
}

test "anchors, word boundaries, dead-on-invalid" {
    var b = B.init(0);
    try expectFind(b.finish(b.cat(&.{ b.lit('a'), b.lit('b'), b.lit('c'), b.assert(.text_end) })), "abc\n", .{}, null); // abc$
    b = B.init(4); // (?m)
    try expectFind(b.finish(b.cat(&.{ b.assert(.line_start), b.lit('b') })), "a\nb", .{}, .{ 2, 3 });
    b = B.init(0);
    const w = b.plus(b.class(&.{B.perl(.word, false)}, false));
    try expectFind(b.finish(b.cat(&.{ b.assert(.word_boundary), w, b.assert(.word_boundary) })), "\xC3\xA9b", .{}, .{ 0, 3 });
    b = B.init(0);
    try expectFind(b.finish(b.dot()), "\xFF", .{}, null);
    b = B.init(0);
    try expectFind(b.finish(b.dot()), "\xFFa", .{}, .{ 1, 2 }); // resync one byte on
    b = B.init(0);
    try expectFind(b.finish(b.cat(&.{ b.lit('a'), b.dot(), b.lit('b') })), "a\xFFb", .{}, null);
    b = B.init(3); // (?i)
    try expectFind(b.finish(b.lit('k')), "\xE2\x84\xAA", .{}, .{ 0, 3 });
}

test "captures" {
    var b = B.init(0);
    const t = b.finish(b.cat(&.{ b.group(b.lit('a')), b.opt(b.group(b.lit('b'))) })); // (a)(b)?
    var r = try Ref.init(testing.allocator, &t);
    defer r.deinit();
    var slots: [max_slots]?usize = undefined;
    const s = slots[0..r.slotCount()];
    _ = (try r.find("a", .{}, s)).?;
    try testing.expectEqualSlices(?usize, &.{ 0, 1, 0, 1, null, null }, s);
}

test "odd search options never panic" {
    var b = B.init(0);
    const t = b.finish(b.dot());
    try expectFind(t, "\xC3\xA9", .{ .start = 1 }, null); // start inside a code point
    try expectFind(t, "\xC3\xA9x", .{ .start = 1 }, .{ 2, 3 });
    try expectFind(t, "ab", .{ .start = 2 }, null); // start == len
    try expectFind(t, "ab", .{ .start = 2, .span_end = 1 }, null); // span_end < start
    try expectFind(t, "ab", .{ .start = 1, .anchored = true }, .{ 1, 2 });
    try expectFind(t, "ab", .{ .span_end = 1 }, .{ 0, 1 });
}

test "findAll steps one scalar after an empty match (one byte over a malformed byte)" {
    var b = B.init(0);
    const t = b.finish(b.opt(b.lit('a'))); // a?
    var r = try Ref.init(testing.allocator, &t);
    defer r.deinit();
    var out: std.ArrayList([2]usize) = .empty;
    defer out.deinit(testing.allocator);
    try r.findAll("\xE6a", &out, 16);
    try testing.expectEqualSlices([2]usize, &.{ .{ 0, 0 }, .{ 1, 2 }, .{ 2, 2 } }, out.items);
}
```

In `fuzz/lib.zig` replace the `ref` struct with `pub const ref = @import("ref/root.zig");` and replace `_ = @import("ref/uni.zig");` with `_ = @import("ref/root.zig");`.

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile — `use of undeclared identifier 'Ref'`.

- [ ] **Step 3: Implement `fuzz/ref/nfa.zig`**

```zig
//! Tree → Thompson NFA following Rust `regex-automata`'s thompson compiler — the
//! empty-width-loop semantics ezi_gex adopted in 0.6.0 (RE2/Rust leftmost-first):
//!
//!   x?        split(x, next)
//!   x+        x ; split(x.start, next)
//!   x*        x nullable ? (x+)?  :  L: split(x, next); x → L
//!   x{n,}     x{n-1} x+
//!   x{m,n}    m copies, then n−m nested optionals that share one exit
//!
//! Lazy forms swap split priority. Compiled right-to-left: `node(i, next)` returns the
//! entry pc of node `i` whose exits continue at `next`.

const std = @import("std");
const tree = @import("../gen/tree.zig");

pub const Op = enum(u8) { match, char, split, jmp, save, assert };
/// `char`: arg = tree node index (lit/dot/class). `split`: x preferred, y alternative.
/// `save`: arg = slot. `assert`: arg = `tree.Assert`. Everything else continues at x.
pub const Inst = struct { op: Op, x: u32 = 0, y: u32 = 0, arg: u32 = 0 };
pub const max_insts = 20_000;

pub const Prog = struct {
    insts: []Inst,
    start: u32,
    n_slots: u32,

    pub fn deinit(p: *Prog, gpa: std.mem.Allocator) void {
        gpa.free(p.insts);
    }
};

pub fn compile(gpa: std.mem.Allocator, t: *const tree.Tree) !Prog {
    var c: Compiler = .{ .gpa = gpa, .t = t };
    errdefer c.list.deinit(gpa);
    const m = try c.emit(.{ .op = .match });
    const s1 = try c.emit(.{ .op = .save, .arg = 1, .x = m });
    const body = try c.node(t.root, s1);
    const s0 = try c.emit(.{ .op = .save, .arg = 0, .x = body });
    return .{ .insts = try c.list.toOwnedSlice(gpa), .start = s0, .n_slots = 2 * (@as(u32, t.n_groups) + 1) };
}

const Compiler = struct {
    gpa: std.mem.Allocator,
    t: *const tree.Tree,
    list: std.ArrayList(Inst) = .empty,

    fn emit(c: *Compiler, inst: Inst) !u32 {
        if (c.list.items.len >= max_insts) return error.ProgramTooBig;
        try c.list.append(c.gpa, inst);
        return @intCast(c.list.items.len - 1);
    }

    fn setSplit(c: *Compiler, at: u32, body: u32, exit: u32, greedy: bool) void {
        c.list.items[at] = if (greedy)
            .{ .op = .split, .x = body, .y = exit }
        else
            .{ .op = .split, .x = exit, .y = body };
    }

    fn node(c: *Compiler, i: u16, next: u32) anyerror!u32 {
        const n = c.t.nodes[i];
        switch (n.kind) {
            .empty => return next,
            .lit, .dot, .class => return c.emit(.{ .op = .char, .arg = i, .x = next }),
            .assert => return c.emit(.{ .op = .assert, .arg = n.a, .x = next }),
            .flags => return c.node(n.first, next),
            .concat => {
                var cur = next;
                const ks = c.t.kidsOf(n);
                var j = ks.len;
                while (j > 0) {
                    j -= 1;
                    cur = try c.node(ks[j], cur);
                }
                return cur;
            },
            .alt => {
                const ks = c.t.kidsOf(n);
                if (ks.len == 0) return next;
                var starts: [tree.max_kids]u32 = undefined;
                for (ks, 0..) |k, j| starts[j] = try c.node(k, next);
                var cur = starts[ks.len - 1];
                var j = ks.len - 1;
                while (j > 0) {
                    j -= 1;
                    cur = try c.emit(.{ .op = .split, .x = starts[j], .y = cur });
                }
                return cur;
            },
            .group => {
                const k: u32 = n.b;
                const close = try c.emit(.{ .op = .save, .arg = 2 * k + 1, .x = next });
                const b = try c.node(n.first, close);
                return c.emit(.{ .op = .save, .arg = 2 * k, .x = b });
            },
            .repeat => return c.repeat(n, next),
        }
    }

    fn exactly(c: *Compiler, child: u16, count: u8, next: u32) anyerror!u32 {
        var cur = next;
        var k: u8 = 0;
        while (k < count) : (k += 1) cur = try c.node(child, cur);
        return cur;
    }

    fn repeat(c: *Compiler, n: tree.Node, next: u32) anyerror!u32 {
        const greedy = n.a != 0;
        const min = n.b;
        const max = n.c;
        if (max != tree.unbounded) {
            if (max == 0) return next;
            if (min == max) return c.exactly(n.first, min, next);
            // m copies, then (n−m) nested optionals sharing the exit `next` (Rust c_bounded).
            var after = next;
            var k: u8 = max - min;
            while (k > 0) : (k -= 1) {
                const u = try c.emit(.{ .op = .split });
                const xs = try c.node(n.first, after);
                c.setSplit(u, xs, next, greedy);
                after = u;
            }
            return c.exactly(n.first, min, after);
        }
        if (min == 0) {
            const l = try c.emit(.{ .op = .split });
            const xs = try c.node(n.first, l);
            c.setSplit(l, xs, next, greedy);
            if (!c.t.nullable(n.first)) return l; // L: split(x, next); x → L
            // Nullable body: (x+)? — `l` is the `+` loop-back; the `?` goes in front. With
            // the plain loop, the empty path through x would outrank exiting (wrong tiebreak).
            const q = try c.emit(.{ .op = .split });
            c.setSplit(q, xs, next, greedy);
            return q;
        }
        // x{n,} (n ≥ 1) = x{n-1} x+
        const p = try c.emit(.{ .op = .split });
        const last = try c.node(n.first, p);
        c.setSplit(p, last, next, greedy);
        return c.exactly(n.first, min - 1, last);
    }
};
```

- [ ] **Step 4: Implement `fuzz/ref/pike.zig`**

```zig
//! A naive Pike VM over `nfa.Prog`: per-position thread lists in priority order; an
//! epsilon closure that visits each state at most once per position (the Thompson/Rust
//! dedup that defines the empty-loop tiebreak); per-thread capture slots; the unanchored
//! start thread appended at LOWEST priority until the first match. Steps by decoded
//! scalar; a malformed byte kills every consuming thread and the next position is one
//! byte on (dead-on-invalid). Slow and simple on purpose.

const std = @import("std");
const tree = @import("../gen/tree.zig");
const nfa = @import("nfa.zig");
const uni = @import("uni.zig");

pub const Search = struct { start: usize = 0, anchored: bool = false, span_end: ?usize = null };

const Threads = struct {
    sparse: []u32,
    dense: []u32,
    len: u32 = 0,
    slots: []?usize,
    ns: usize,

    fn init(gpa: std.mem.Allocator, n: usize, ns: usize) !Threads {
        const sparse = try gpa.alloc(u32, n);
        errdefer gpa.free(sparse);
        @memset(sparse, 0);
        const dense = try gpa.alloc(u32, n);
        errdefer gpa.free(dense);
        const slots = try gpa.alloc(?usize, n * ns);
        return .{ .sparse = sparse, .dense = dense, .slots = slots, .ns = ns };
    }

    fn deinit(self: *Threads, gpa: std.mem.Allocator) void {
        gpa.free(self.sparse);
        gpa.free(self.dense);
        gpa.free(self.slots);
    }

    fn contains(self: *const Threads, pc: u32) bool {
        const i = self.sparse[pc];
        return i < self.len and self.dense[i] == pc;
    }

    fn insert(self: *Threads, pc: u32) void {
        self.sparse[pc] = self.len;
        self.dense[self.len] = pc;
        self.len += 1;
    }

    fn slotsOf(self: *Threads, pc: u32) []?usize {
        return self.slots[pc * self.ns ..][0..self.ns];
    }
};

const Frame = union(enum) {
    explore: u32,
    restore: struct { slot: u32, val: ?usize },
};

fn wordBefore(input: []const u8, at: usize) bool {
    const d = uni.decodeBefore(input, at) orelse return false;
    return d.valid and uni.isWord(d.cp);
}

fn wordAfter(input: []const u8, at: usize) bool {
    if (at >= input.len) return false;
    const d = uni.decode(input, at);
    return d.valid and uni.isWord(d.cp);
}

pub fn assertHolds(k: tree.Assert, input: []const u8, at: usize) bool {
    return switch (k) {
        .text_start => at == 0,
        .text_end => at == input.len,
        .line_start => at == 0 or input[at - 1] == '\n',
        .line_end => at == input.len or input[at] == '\n',
        .word_boundary => wordBefore(input, at) != wordAfter(input, at),
        .not_word_boundary => wordBefore(input, at) == wordAfter(input, at),
    };
}

pub const Vm = struct {
    gpa: std.mem.Allocator,
    prog: *const nfa.Prog,
    t: *const tree.Tree,
    sem: tree.OptSem,

    /// Leftmost-first search. `slots_out.len == prog.n_slots`; on a match it holds the
    /// winning thread's slots (0/1 = the span). The haystack is clamped to `span_end`
    /// first, exactly as ezi_gex's `Engine` clamps it (assertions see the clamped end).
    pub fn search(vm: *const Vm, input_full: []const u8, so: Search, slots_out: []?usize) !bool {
        std.debug.assert(slots_out.len == vm.prog.n_slots);
        @memset(slots_out, null);
        const end = if (so.span_end) |e| @min(e, input_full.len) else input_full.len;
        if (so.start > end) return false;
        const input = input_full[0..end];
        const n = vm.prog.insts.len;
        const ns: usize = vm.prog.n_slots;
        var clist = try Threads.init(vm.gpa, n, ns);
        defer clist.deinit(vm.gpa);
        var nlist = try Threads.init(vm.gpa, n, ns);
        defer nlist.deinit(vm.gpa);
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(vm.gpa);
        const cur = try vm.gpa.alloc(?usize, ns);
        defer vm.gpa.free(cur);

        var matched = false;
        var at = so.start;
        while (true) {
            if (clist.len == 0 and (matched or (so.anchored and at > so.start))) break;
            if (!matched and (!so.anchored or at == so.start)) {
                @memset(cur, null);
                try vm.closure(input, at, vm.prog.start, cur, &clist, &stack);
            }
            const d: ?uni.Decoded = if (at < input.len) uni.decode(input, at) else null;
            const next_at = if (d) |dd| at + dd.len else at + 1;
            nlist.len = 0;
            for (clist.dense[0..clist.len]) |pc| {
                const inst = vm.prog.insts[pc];
                switch (inst.op) {
                    .match => {
                        @memcpy(slots_out, clist.slotsOf(pc));
                        matched = true;
                        break; // lower-priority threads are cut
                    },
                    .char => if (d) |dd| {
                        if (dd.valid and uni.charMatches(vm.t, vm.t.nodes[inst.arg], dd.cp, vm.sem)) {
                            @memcpy(cur, clist.slotsOf(pc));
                            try vm.closure(input, next_at, inst.x, cur, &nlist, &stack);
                        }
                    },
                    else => {},
                }
            }
            if (at >= input.len) break;
            std.mem.swap(Threads, &clist, &nlist);
            at = next_at;
        }
        return matched;
    }

    fn closure(vm: *const Vm, input: []const u8, at: usize, pc0: u32, cur: []?usize, list: *Threads, stack: *std.ArrayList(Frame)) !void {
        try stack.append(vm.gpa, .{ .explore = pc0 });
        while (stack.pop()) |f| {
            switch (f) {
                .restore => |r| cur[r.slot] = r.val,
                .explore => |start_pc| {
                    var pc = start_pc;
                    while (true) {
                        if (list.contains(pc)) break;
                        list.insert(pc);
                        const inst = vm.prog.insts[pc];
                        switch (inst.op) {
                            .match, .char => {
                                @memcpy(list.slotsOf(pc), cur);
                                break;
                            },
                            .jmp => pc = inst.x,
                            .split => {
                                try stack.append(vm.gpa, .{ .explore = inst.y });
                                pc = inst.x;
                            },
                            .save => {
                                if (inst.arg < cur.len) {
                                    try stack.append(vm.gpa, .{ .restore = .{ .slot = inst.arg, .val = cur[inst.arg] } });
                                    cur[inst.arg] = at;
                                }
                                pc = inst.x;
                            },
                            .assert => {
                                if (!assertHolds(@enumFromInt(inst.arg), input, at)) break;
                                pc = inst.x;
                            },
                        }
                    }
                },
            }
        }
    }
};
```

- [ ] **Step 5: Implement the façade** (top of `fuzz/ref/root.zig`, above the tests)

```zig
//! The reference matcher: an independent, deliberately naive regex engine that consumes
//! the generator's semantic `Tree` directly (no parser), so a bug anywhere in ezi_gex's
//! shared scanner → AST → HIR → nfa front end cannot make it agree. Never imports
//! `ezi_gex`; Unicode facts come from `ezi_code` point lookups (`uni.zig`).

pub const uni = @import("uni.zig");
pub const nfa = @import("nfa.zig");
pub const pike = @import("pike.zig");

pub const max_slots = 2 * (@as(usize, tree.max_groups) + 1);

pub const Ref = struct {
    gpa: std.mem.Allocator,
    t: *const tree.Tree,
    prog: nfa.Prog,

    pub fn init(gpa: std.mem.Allocator, t: *const tree.Tree) !Ref {
        return .{ .gpa = gpa, .t = t, .prog = try nfa.compile(gpa, t) };
    }

    pub fn deinit(r: *Ref) void {
        r.prog.deinit(r.gpa);
    }

    pub fn slotCount(r: *const Ref) usize {
        return r.prog.n_slots;
    }

    /// Leftmost-first match; `slots.len == slotCount()`, filled on a match.
    pub fn find(r: *const Ref, input: []const u8, so: pike.Search, slots: []?usize) !?[2]usize {
        const vm: pike.Vm = .{ .gpa = r.gpa, .prog = &r.prog, .t = r.t, .sem = tree.opt_sem[r.t.opt] };
        if (!try vm.search(input, so, slots)) return null;
        return .{ slots[0].?, slots[1].? };
    }

    /// Non-overlapping matches (at most `max`). After an empty match the next search starts
    /// one SCALAR on — the decoded length, or one byte over a malformed byte.
    pub fn findAll(r: *const Ref, input: []const u8, out: *std.ArrayList([2]usize), max: usize) !void {
        var slots: [max_slots]?usize = undefined;
        const s = slots[0..r.slotCount()];
        var pos: usize = 0;
        while (pos <= input.len and out.items.len < max) {
            const m = (try r.find(input, .{ .start = pos }, s)) orelse break;
            try out.append(r.gpa, m);
            pos = if (m[1] > m[0]) m[1] else if (m[1] >= input.len) input.len + 1 else m[1] + uni.decode(input, m[1]).len;
        }
    }
};
```

- [ ] **Step 6: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS (all six reference tests). A failure here is a reference bug — the expectations above are the
conformance-pinned ezi_gex semantics (`conformance.zig`: `nullable_alt_repetition_cases`,
`empty_loop_concat_cases`, `general_cases`).

- [ ] **Step 7: Commit**

```sh
git add fuzz/ref/nfa.zig fuzz/ref/pike.zig fuzz/ref/root.zig fuzz/lib.zig
git commit -m "test(fuzz): independent reference matcher (Rust Thompson construction + naive Pike VM)"
```

---

### Task 9: `ref/selfcheck.zig` — the reference reproduces the human-verified conformance expectations

**Files:**
- Create: `fuzz/ref/selfcheck.zig`
- Modify: `fuzz/lib.zig` (test block)

**Interfaces:**
- Consumes: `tree.Builder`, `Ref`.
- Produces: `cases` table (reused by Task 21's comptime check as a pattern/input source of known-good shapes) — `SelfCase{ name, opt, build: *const fn (*tree.Builder) u16, input, expect: ?[2]usize }`.

- [ ] **Step 1: Write the table and the test** (this file IS the test; each row transcribes a `conformance.zig` row — `general_cases` lines 228–284, `nullable_alt_repetition_cases`, `empty_loop_concat_cases`; `name` is the original pattern)

```zig
//! The reference's own guard: it must reproduce ezi_gex's HUMAN-VERIFIED conformance
//! expectations (not the differential-only `wide_cases`). A failure here means the
//! reference is wrong, never ezi_gex. Rows are transcribed from src/engine/conformance.zig
//! into Builder form; `name` is the original pattern text.

const std = @import("std");
const tree = @import("../gen/tree.zig");
const root = @import("root.zig");
const B = tree.Builder;

pub const SelfCase = struct {
    name: []const u8,
    opt: u8 = 0,
    build: *const fn (*B) u16,
    input: []const u8,
    expect: ?[2]usize,
};

fn word(b: *B) u16 {
    return b.class(&.{B.perl(.word, false)}, false);
}
fn str(b: *B, s: []const u8) u16 {
    var ks: [16]u16 = undefined;
    for (s, 0..) |c, i| ks[i] = b.lit(c);
    return if (s.len == 1) ks[0] else b.cat(ks[0..s.len]);
}

pub const cases = [_]SelfCase{
    .{ .name = "a|ab", .input = "ab", .expect = .{ 0, 1 }, .build = struct {
        fn f(b: *B) u16 { return b.alt(&.{ b.lit('a'), str(b, "ab") }); }
    }.f },
    .{ .name = "ab|a", .input = "ab", .expect = .{ 0, 2 }, .build = struct {
        fn f(b: *B) u16 { return b.alt(&.{ str(b, "ab"), b.lit('a') }); }
    }.f },
    .{ .name = "foo|foobar", .input = "foobar", .expect = .{ 0, 3 }, .build = struct {
        fn f(b: *B) u16 { return b.alt(&.{ str(b, "foo"), str(b, "foobar") }); }
    }.f },
    .{ .name = "a+?", .input = "aaaa", .expect = .{ 0, 1 }, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.lit('a'), 1, tree.unbounded, false); }
    }.f },
    .{ .name = "a{2,4}", .input = "aaaaaa", .expect = .{ 0, 4 }, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.lit('a'), 2, 4, true); }
    }.f },
    .{ .name = "a{2,4}?", .input = "aaaaaa", .expect = .{ 0, 2 }, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.lit('a'), 2, 4, false); }
    }.f },
    .{ .name = "a{3,}", .input = "aa", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.lit('a'), 3, tree.unbounded, true); }
    }.f },
    .{ .name = "(ab){2,3}", .input = "abababab", .expect = .{ 0, 6 }, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.group(str(b, "ab")), 2, 3, true); }
    }.f },
    .{ .name = "a??", .input = "a", .expect = .{ 0, 0 }, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.lit('a'), 0, 1, false); }
    }.f },
    .{ .name = "x*?y", .input = "xxxy", .expect = .{ 0, 4 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.rep(b.lit('x'), 0, tree.unbounded, false), b.lit('y') }); }
    }.f },
    .{ .name = "^abc$", .input = "abc\n", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.assert(.text_start), str(b, "abc"), b.assert(.text_end) }); }
    }.f },
    .{ .name = "a$", .input = "ba", .expect = .{ 1, 2 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.lit('a'), b.assert(.text_end) }); }
    }.f },
    .{ .name = "(?m)^line2", .opt = 4, .input = "line1\nline2\nline3", .expect = .{ 6, 11 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.assert(.line_start), str(b, "line2") }); }
    }.f },
    .{ .name = "(?m)line2$", .opt = 4, .input = "line2\nline3", .expect = .{ 0, 5 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ str(b, "line2"), b.assert(.line_end) }); }
    }.f },
    .{ .name = "^b$", .input = "a\nb\nc", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.assert(.text_start), b.lit('b'), b.assert(.text_end) }); }
    }.f },
    .{ .name = "\\bcat\\b", .input = "category", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.assert(.word_boundary), str(b, "cat"), b.assert(.word_boundary) }); }
    }.f },
    .{ .name = "\\Bcat\\B", .input = "locator", .expect = .{ 2, 5 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.assert(.not_word_boundary), str(b, "cat"), b.assert(.not_word_boundary) }); }
    }.f },
    .{ .name = "\\b\\w+\\b", .input = "(h\xC3\xA9llo)", .expect = .{ 1, 7 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.assert(.word_boundary), b.plus(word(b)), b.assert(.word_boundary) }); }
    }.f },
    .{ .name = "s\\b", .input = "cats dogs", .expect = .{ 3, 4 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.lit('s'), b.assert(.word_boundary) }); }
    }.f },
    .{ .name = "a.c", .input = "a\xFFc", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.lit('a'), b.dot(), b.lit('c') }); }
    }.f },
    .{ .name = ".", .input = "\xFFa", .expect = .{ 1, 2 }, .build = struct {
        fn f(b: *B) u16 { return b.dot(); }
    }.f },
    .{ .name = "\\w+", .input = "ab\xFFcd", .expect = .{ 0, 2 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(word(b)); }
    }.f },
    .{ .name = "a+b", .input = "aa\xFFb", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.plus(b.lit('a')), b.lit('b') }); }
    }.f },
    .{ .name = "(?i)k", .opt = 3, .input = "\u{212A}", .expect = .{ 0, 3 }, .build = struct {
        fn f(b: *B) u16 { return b.lit('k'); }
    }.f },
    .{ .name = "(?i)\u{017F}", .opt = 3, .input = "S", .expect = .{ 0, 1 }, .build = struct {
        fn f(b: *B) u16 { return b.lit(0x017F); }
    }.f },
    .{ .name = "(?i)\u{00C5}", .opt = 3, .input = "\u{212B}", .expect = .{ 0, 3 }, .build = struct {
        fn f(b: *B) u16 { return b.lit(0x00C5); }
    }.f },
    .{ .name = "(?i)[a-z]+", .opt = 3, .input = "ABCdef", .expect = .{ 0, 6 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.class(&.{B.range('a', 'z')}, false)); }
    }.f },
    .{ .name = "(?s)a.c", .opt = 5, .input = "a\nc", .expect = .{ 0, 3 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.lit('a'), b.dot(), b.lit('c') }); }
    }.f },
    .{ .name = "a.c", .input = "a\nc", .expect = null, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.lit('a'), b.dot(), b.lit('c') }); }
    }.f },
    .{ .name = "\\p{Nd}+", .input = "x\u{0664}\u{0665}\u{0666}y", .expect = .{ 1, 7 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.class(&.{B.prop("Nd", false)}, false)); }
    }.f },
    .{ .name = "\\P{L}+", .input = "abc123!!", .expect = .{ 3, 8 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.class(&.{B.prop("L", true)}, false)); }
    }.f },
    .{ .name = "[^a-z]+", .input = "abXY12cd", .expect = .{ 2, 6 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.class(&.{B.range('a', 'z')}, true)); }
    }.f },
    .{ .name = "(?:|.)+", .input = "c", .expect = .{ 0, 0 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.alt(&.{ b.empty(), b.dot() })); }
    }.f },
    .{ .name = "(?:|a)+", .input = "aa", .expect = .{ 0, 0 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.alt(&.{ b.empty(), b.lit('a') })); }
    }.f },
    .{ .name = "(|a)*", .input = "aaa", .expect = .{ 0, 0 }, .build = struct {
        fn f(b: *B) u16 { return b.star(b.group(b.alt(&.{ b.empty(), b.lit('a') }))); }
    }.f },
    .{ .name = "(?:a?b??)+", .input = "ab", .expect = .{ 0, 1 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.cat(&.{ b.opt(b.lit('a')), b.rep(b.lit('b'), 0, 1, false) })); }
    }.f },
    .{ .name = "(?:a??b??)+", .input = "ab", .expect = .{ 0, 0 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.cat(&.{ b.rep(b.lit('a'), 0, 1, false), b.rep(b.lit('b'), 0, 1, false) })); }
    }.f },
    .{ .name = "(?:a?b?c??)+", .input = "abc", .expect = .{ 0, 2 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.cat(&.{ b.opt(b.lit('a')), b.opt(b.lit('b')), b.rep(b.lit('c'), 0, 1, false) })); }
    }.f },
    .{ .name = "(?:a?b??){2,}", .input = "ab", .expect = .{ 0, 1 }, .build = struct {
        fn f(b: *B) u16 { return b.rep(b.cat(&.{ b.opt(b.lit('a')), b.rep(b.lit('b'), 0, 1, false) }), 2, tree.unbounded, true); }
    }.f },
    .{ .name = "(a?b??)+", .input = "ab", .expect = .{ 0, 1 }, .build = struct {
        fn f(b: *B) u16 { return b.plus(b.group(b.cat(&.{ b.opt(b.lit('a')), b.rep(b.lit('b'), 0, 1, false) }))); }
    }.f },
    .{ .name = "(?:a?b??)+x", .input = "abx", .expect = .{ 0, 3 }, .build = struct {
        fn f(b: *B) u16 { return b.cat(&.{ b.plus(b.cat(&.{ b.opt(b.lit('a')), b.rep(b.lit('b'), 0, 1, false) })), b.lit('x') }); }
    }.f },
};

test "reference reproduces the human-verified conformance expectations" {
    const gpa = std.testing.allocator;
    var failures: usize = 0;
    for (cases) |c| {
        var b = B.init(c.opt);
        const t = b.finish(c.build(&b));
        var r = try root.Ref.init(gpa, &t);
        defer r.deinit();
        var slots: [root.max_slots]?usize = undefined;
        const got = try r.find(c.input, .{}, slots[0..r.slotCount()]);
        const ok = if (c.expect) |e| (got != null and got.?[0] == e[0] and got.?[1] == e[1]) else got == null;
        if (!ok) {
            std.debug.print("selfcheck /{s}/ on \"{s}\": want {?any} got {?any}\n", .{ c.name, c.input, c.expect, got });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
```

Add `_ = @import("ref/selfcheck.zig");` to the test block of `fuzz/lib.zig`.

- [ ] **Step 2: Run it**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS. A row that fails is a reference bug: fix `nfa.zig`/`pike.zig`/`uni.zig` until every row passes —
never edit a row's expectation (each is pinned in `conformance.zig`).

- [ ] **Step 3: Commit**

```sh
git add fuzz/ref/selfcheck.zig fuzz/lib.zig
git commit -m "test(fuzz): reference self-check against human-verified conformance rows"
```

---

## Phase B′ — Generators that need the reference

### Task 10: `gen/witness.zig` — strings a tree provably matches

**Files:**
- Create: `fuzz/gen/witness.zig`
- Modify: `fuzz/lib.zig`

**Interfaces:**
- Consumes: `tree`, `ref.Ref`, `ref.uni.{charMatches, orbit}`, `tree.encodeUtf8`.
- Produces: `max_witness = 256`; `Witness{ buf, len, slice() }`; `sample(gpa, *const Tree, seed: u64) !?Witness` — the returned bytes are exactly the reference's anchored-at-0 match (so planting them yields a real match modulo context assertions); `null` when the structural sample doesn't match.

- [ ] **Step 1: Write the failing test** — create `fuzz/gen/witness.zig` with imports + test:

```zig
const std = @import("std");
const tree = @import("tree.zig");
const ref = @import("../ref/root.zig");
const Smith = std.testing.Smith;

test "witnesses match anchored at 0 and are produced for most trees" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(31);
    var buf: [1024]u8 = undefined;
    var produced: usize = 0;
    const n = 1500;
    for (0..n) |i| {
        prng.random().bytes(&buf);
        var s: Smith = .{ .in = &buf };
        const t = tree.generate(&s, tree.pickOpt(&s));
        const w = (try sample(gpa, &t, i + 1)) orelse continue;
        produced += 1;
        var r = try ref.Ref.init(gpa, &t);
        defer r.deinit();
        var slots: [ref.max_slots]?usize = undefined;
        const m = (try r.find(w.slice(), .{ .anchored = true }, slots[0..r.slotCount()])).?;
        try std.testing.expectEqual(@as(usize, 0), m[0]);
        try std.testing.expectEqual(w.len, m[1]);
    }
    // Most trees are satisfiable; a low rate means the sampler lost track of a node kind.
    try std.testing.expect(produced * 2 > n);
}
```

Add `pub const witness = @import("gen/witness.zig");` to `gen` and `_ = @import("gen/witness.zig");` to the lib test block.

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile — `use of undeclared identifier 'sample'`.

- [ ] **Step 3: Implement** (above the test)

```zig
//! Witness sampler: a string the tree matches when searched ANCHORED at offset 0, used to
//! plant real matches (and near-misses) in long haystacks. Sampled structurally, then
//! confirmed with the reference matcher and trimmed to exactly the reference's match.

pub const max_witness = 256;

pub const Witness = struct {
    buf: [max_witness]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Witness) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn sample(gpa: std.mem.Allocator, t: *const tree.Tree, seed: u64) !?Witness {
    var prng = std.Random.DefaultPrng.init(seed);
    var s: Sampler = .{ .t = t, .r = prng.random(), .sem = tree.opt_sem[t.opt] };
    s.node(t.root);
    if (s.overflow) return null;
    var r = ref.Ref.init(gpa, t) catch |e| switch (e) {
        error.ProgramTooBig => return null,
        else => return e,
    };
    defer r.deinit();
    var slots: [ref.max_slots]?usize = undefined;
    const m = (try r.find(s.w.slice(), .{ .anchored = true }, slots[0..r.slotCount()])) orelse return null;
    s.w.len = m[1];
    return s.w;
}

const pool = tree.alphabet_cps ++ tree.trap_cps ++ [_]u21{ '0', '7', 0x0663, 'Z', 'q', 0x00E9, 0x03B1, 0x0436, 0x3000, 0x0301, 0x200D, '!', '+', '_' };

const Sampler = struct {
    t: *const tree.Tree,
    r: std.Random,
    sem: tree.OptSem,
    w: Witness = .{},
    overflow: bool = false,

    fn emit(s: *Sampler, cp: u21) void {
        var b: [4]u8 = undefined;
        const n = tree.encodeUtf8(cp, &b);
        if (s.w.len + n > max_witness) {
            s.overflow = true;
            return;
        }
        @memcpy(s.w.buf[s.w.len..][0..n], b[0..n]);
        s.w.len += n;
    }

    /// A random member of `n` (lit / dot / class) from the pool plus item-derived
    /// candidates, or 'a' if none fits (the reference confirmation then rejects).
    fn member(s: *Sampler, n: tree.Node) u21 {
        if (n.kind == .lit) {
            const cp: u21 = @intCast(n.cp);
            if (n.flags.i and s.sem.fold and s.r.boolean()) {
                var ob: [8]u21 = undefined;
                const o = ref.uni.orbit(cp, &ob);
                return o[s.r.uintLessThan(usize, o.len)];
            }
            return cp;
        }
        var cands: [pool.len + 3 * tree.max_items]u21 = undefined;
        var k: usize = 0;
        for (pool) |c| {
            cands[k] = c;
            k += 1;
        }
        if (n.kind == .class) for (s.t.itemsOf(n)) |it| {
            switch (it.kind) {
                .range => {
                    cands[k] = @intCast(it.lo);
                    cands[k + 1] = @intCast(it.hi);
                    cands[k + 2] = @intCast(it.lo + (it.hi - it.lo) / 2);
                    k += 3;
                },
                .prop => {
                    cands[k] = @import("props.zig").table[it.which].sample;
                    k += 1;
                },
                .perl => {},
            }
        };
        var fits: [cands.len]u21 = undefined;
        var nf: usize = 0;
        for (cands[0..k]) |c| {
            if (!tree.isScalar(c)) continue;
            if (ref.uni.charMatches(s.t, n, c, s.sem)) {
                fits[nf] = c;
                nf += 1;
            }
        }
        return if (nf == 0) 'a' else fits[s.r.uintLessThan(usize, nf)];
    }

    fn node(s: *Sampler, i: u16) void {
        if (s.overflow) return;
        const n = s.t.nodes[i];
        switch (n.kind) {
            .empty, .assert => {},
            .lit, .dot, .class => s.emit(s.member(n)),
            .concat => for (s.t.kidsOf(n)) |k| s.node(k),
            .alt => {
                const ks = s.t.kidsOf(n);
                if (ks.len > 0) s.node(ks[s.r.uintLessThan(usize, ks.len)]);
            },
            .repeat => {
                const hi: u8 = if (n.c == tree.unbounded) n.b +| 2 else n.c;
                const count = n.b + s.r.uintAtMost(u8, hi - n.b);
                var j: u8 = 0;
                while (j < count) : (j += 1) s.node(n.first);
            },
            .group, .flags => s.node(n.first),
        }
    }
};
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add fuzz/gen/witness.zig fuzz/lib.zig
git commit -m "test(fuzz): witness sampler confirmed by the reference matcher"
```

---

### Task 11: `gen/input.zig` — evil UTF-8, long inputs with planted strings, fold-swap, small-input picker

**Files:**
- Modify: `fuzz/gen/input.zig`

**Interfaces:**
- Consumes: `pattern.alphabet`, `pattern.trap_raw`, `pattern.unicodeInput`, `ref.uni.{decode, orbit}`, `tree.encodeUtf8`.
- Produces: `evil_pieces`, `truncated_tails`; `evilInput(*Smith, []u8) []const u8`; `max_long_len = 12 * 1024`; `longLen(*Smith) usize`; `Long{ bytes: []u8, plants_at: [4]usize, n_plants: usize }`; `longInput(*Smith, out: []u8, motif: []const u8, plants: []const []const u8) Long`; `motif(*Smith, out: []u8) []const u8`; `foldSwap(in, out: []u8, seed) []const u8` (`out.len >= 4 * in.len`); `pickSmall(*Smith, buf: []u8) []const u8` (alphabet / valid Unicode / evil, ≤ `max_input_len`).

- [ ] **Step 1: Write the failing tests** (append to `fuzz/gen/input.zig`)

```zig
const uni = @import("../ref/uni.zig");

fn prngSmith(prng: *std.Random.DefaultPrng, buf: []u8) Smith {
    prng.random().bytes(buf);
    return .{ .in = buf };
}

test "evilInput is usually malformed somewhere" {
    var prng = std.Random.DefaultPrng.init(41);
    var sb: [256]u8 = undefined;
    var out: [128]u8 = undefined;
    var bad: usize = 0;
    for (0..1000) |_| {
        var s = prngSmith(&prng, &sb);
        const in = evilInput(&s, &out);
        var i: usize = 0;
        while (i < in.len) {
            const d = uni.decode(in, i);
            if (!d.valid) {
                bad += 1;
                break;
            }
            i += d.len;
        }
    }
    try std.testing.expect(bad >= 700);
}

test "longInput crosses 4096 often and plants where it says" {
    var prng = std.Random.DefaultPrng.init(43);
    var sb: [256]u8 = undefined;
    const out = try std.testing.allocator.alloc(u8, max_long_len);
    defer std.testing.allocator.free(out);
    var over: usize = 0;
    for (0..400) |_| {
        var s = prngSmith(&prng, &sb);
        const l = longInput(&s, out, "ab c\n", &.{ "NEEDLE", "XY" });
        if (l.bytes.len > 4096) over += 1;
        // Plants may overlap earlier ones, so only the LAST plant is guaranteed intact.
        if (l.n_plants > 0) {
            const p = [_][]const u8{ "NEEDLE", "XY" }[l.n_plants - 1];
            try std.testing.expectEqualSlices(u8, p, l.bytes[l.plants_at[l.n_plants - 1]..][0..p.len]);
        }
    }
    try std.testing.expect(over * 4 >= 400); // ≥ 25%
}

test "foldSwap preserves every scalar's fold and copies malformed bytes" {
    var out: [64]u8 = undefined;
    const in = "k\xE2\x84\xAAs\xC5\xBF\xCF\x82\xFFx";
    for (0..50) |seed| {
        const sw = foldSwap(in, &out, seed);
        var i: usize = 0;
        var j: usize = 0;
        while (i < in.len) {
            const a = uni.decode(in, i);
            const b = uni.decode(sw, j);
            try std.testing.expectEqual(a.valid, b.valid);
            if (a.valid) try std.testing.expectEqual(uni.fold(a.cp), uni.fold(b.cp)) else try std.testing.expectEqual(in[i], sw[j]);
            i += a.len;
            j += b.len;
        }
        try std.testing.expectEqual(sw.len, j);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile — `use of undeclared identifier 'evilInput'`.

- [ ] **Step 3: Implement** (below `genInput`)

```zig
const tree = @import("tree.zig");

/// Whole units of hostile UTF-8, mixed with ordinary text so matches still happen.
pub const evil_pieces = [_][]const u8{
    "\xC3",             "\xE6\x97",         "\xF0\x9F\x98", // truncated leads
    "\x80",             "\xBF", // stray continuations
    "\xC0\x80",         "\xC1\xBF",         "\xE0\x80\x80", "\xF0\x80\x80\x80", // overlong
    "\xED\xA0\x80",     "\xED\xBF\xBF", // surrogates
    "\xF4\x90\x80\x80", "\xF5",             "\xFF", // > U+10FFFF / never valid
    "\xEF\xBF\xBD", // a REAL U+FFFD (must differ from a malformed byte)
    "\xEF\xBF\xBF", // U+FFFF noncharacter (valid)
    "a",                "b",                "A", " ", "\n", "_", "1",
    "\xC3\xA9",         "\xE2\x84\xAA",     "\xF0\x90\x90\x80",
};
pub const truncated_tails = [_][]const u8{ "\xC3", "\xE6\x97", "\xF0\x9F\x98", "\xE2" };

pub fn evilInput(smith: *Smith, out: []u8) []const u8 {
    @disableInstrumentation();
    const n = smith.valueRangeAtMost(u8, 0, 16);
    var len: usize = 0;
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const p = evil_pieces[smith.index(evil_pieces.len)];
        if (len + p.len > out.len) break;
        @memcpy(out[len..][0..p.len], p);
        len += p.len;
    }
    if (smith.valueRangeAtMost(u8, 0, 2) == 0) { // end on a truncated sequence
        const tail = truncated_tails[smith.index(truncated_tails.len)];
        if (len + tail.len <= out.len) {
            @memcpy(out[len..][0..tail.len], tail);
            len += tail.len;
        }
    }
    return out[0..len];
}

pub const max_long_len = 12 * 1024;

/// Lengths biased to the regimes that switch code paths: around 4096 (auto's
/// backtrack→Pike-VM cut), SIMD block multiples ±1, and far past both.
pub fn longLen(smith: *Smith) usize {
    @disableInstrumentation();
    return switch (smith.valueRangeAtMost(u8, 0, 5)) {
        0 => 4095 + @as(usize, smith.valueRangeAtMost(u8, 0, 2)),
        1 => @as(usize, smith.valueRangeAtMost(u16, 1, 190)) * 64 + smith.valueRangeAtMost(u8, 0, 2) - 1,
        2 => smith.valueRangeAtMost(u16, 65, 4094),
        3 => smith.valueRangeAtMost(u16, 0, 200),
        else => smith.valueRangeAtMost(u16, 4097, max_long_len),
    };
}

/// A 4–32 byte motif of whole code points (alphabet + traps).
pub fn motif(smith: *Smith, out: []u8) []const u8 {
    @disableInstrumentation();
    const want = smith.valueRangeAtMost(u8, 4, 32);
    var len: usize = 0;
    while (len < want) {
        const piece: []const u8 = if (smith.valueRangeAtMost(u8, 0, 4) == 0)
            ps.trap_raw[smith.index(ps.trap_raw.len)]
        else
            ps.alphabet[smith.index(ps.alphabet.len)..][0..1];
        if (len + piece.len > out.len) break;
        @memcpy(out[len..][0..piece.len], piece);
        len += piece.len;
    }
    return out[0..len];
}

pub const Long = struct { bytes: []u8, plants_at: [4]usize = undefined, n_plants: usize = 0 };

/// `motif` repeated to an edge-biased length, then each of `plants` (≤ 4) copied in at a
/// block-edge / near-end offset. Later plants may overlap earlier ones; `plants_at` records
/// where each landed.
pub fn longInput(smith: *Smith, out: []u8, m: []const u8, plants: []const []const u8) Long {
    @disableInstrumentation();
    const len = @min(longLen(smith), out.len);
    if (m.len == 0) @memset(out[0..len], 'x') else for (out[0..len], 0..) |*b, i| {
        b.* = m[i % m.len];
    }
    var l: Long = .{ .bytes = out[0..len] };
    for (plants[0..@min(plants.len, 4)]) |p| {
        if (p.len == 0 or p.len > len) continue;
        const room = len - p.len;
        const pos: usize = switch (smith.valueRangeAtMost(u8, 0, 4)) {
            0 => room,
            1 => room -| smith.valueRangeAtMost(u8, 0, 3),
            2 => (@as(usize, smith.valueRangeAtMost(u16, 0, 760)) * 16 + smith.valueRangeAtMost(u8, 0, 2)) -| 1,
            3 => (@as(usize, smith.valueRangeAtMost(u16, 0, 380)) * 32 + smith.valueRangeAtMost(u8, 0, 2)) -| 1,
            else => (@as(usize, smith.valueRangeAtMost(u16, 0, 190)) * 64 + smith.valueRangeAtMost(u8, 0, 2)) -| 1,
        };
        const at = @min(pos, room);
        @memcpy(out[at..][0..p.len], p);
        l.plants_at[l.n_plants] = at;
        l.n_plants += 1;
    }
    return l;
}

/// Replace every valid scalar by a random member of its simple-fold orbit (lengths may
/// change: k ↔ K U+212A is 1 ↔ 3 bytes); malformed bytes are copied unchanged.
pub fn foldSwap(in: []const u8, out: []u8, seed: u64) []const u8 {
    std.debug.assert(out.len >= 4 * in.len);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var i: usize = 0;
    var j: usize = 0;
    while (i < in.len) {
        const d = uni.decode(in, i);
        if (!d.valid) {
            out[j] = in[i];
            j += 1;
            i += 1;
            continue;
        }
        var ob: [8]u21 = undefined;
        const o = uni.orbit(d.cp, &ob);
        var b: [4]u8 = undefined;
        const n = tree.encodeUtf8(o[r.uintLessThan(usize, o.len)], &b);
        @memcpy(out[j..][0..n], b[0..n]);
        j += n;
        i += d.len;
    }
    return out[0..j];
}

/// The small-input mix every check uses: 2:1:1 alphabet text, valid Unicode, evil bytes.
pub fn pickSmall(smith: *Smith, buf: []u8) []const u8 {
    @disableInstrumentation();
    return switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0, 1 => genInput(smith, buf),
        2 => buf[0..ps.unicodeInput(smith, buf[0..@min(buf.len, max_input_len)])],
        else => evilInput(smith, buf[0..@min(buf.len, max_input_len)]),
    };
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add fuzz/gen/input.zig
git commit -m "test(fuzz): evil UTF-8, long edge-biased inputs with plants, fold-swapped copies"
```

---

### Task 12: `gen/literals.zig` — literal sets for the literal/Teddy/prefix-set paths

**Files:**
- Create: `fuzz/gen/literals.zig`
- Modify: `fuzz/lib.zig`

**Interfaces:**
- Consumes: `pattern.alphabet`, `pattern.trap_raw`.
- Produces: `max_lits = 12`, `max_lit_len = 20` (code points); `LitSet{ n, ci, get(i) []const u8, pattern(out: []u8) ?[]const u8 }`; `genSet(*Smith) LitSet`; `nearMiss(lit, out) []const u8` (last byte of the last ASCII char flipped).

- [ ] **Step 1: Write the failing test** — create `fuzz/gen/literals.zig` with imports + test:

```zig
const std = @import("std");
const ps = @import("pattern.zig");
const Smith = std.testing.Smith;

test "literal sets cross the prefix-set and prefix-length limits and always parse" {
    const gex = @import("ezi_gex");
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(47);
    var sb: [512]u8 = undefined;
    var many: usize = 0; // > 8 branches (MAX_PREFIX_BRANCHES)
    var long: usize = 0; // a literal > 16 bytes (MAX_PREFIX_LEN)
    var pbuf: [2048]u8 = undefined;
    for (0..1000) |_| {
        prng.random().bytes(&sb);
        var s: Smith = .{ .in = &sb };
        const set = genSet(&s);
        if (set.n > 8) many += 1;
        for (0..set.n) |i| {
            if (set.get(i).len > 16) {
                long += 1;
                break;
            }
        }
        const pat = set.pattern(&pbuf) orelse continue;
        var diag: gex.Diagnostic = .{};
        const a = gex.parse(gpa, pat, &diag) catch {
            std.debug.print("literal set pattern rejected: /{s}/ ({s})\n", .{ pat, @tagName(diag.code) });
            return error.LiteralPatternRejected;
        };
        a.deinit(gpa);
    }
    try std.testing.expect(many >= 150 and long >= 150);
}
```

Add `pub const literals = @import("gen/literals.zig");` to `gen` and `_ = @import("gen/literals.zig");` to the lib test block.

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile — `use of undeclared identifier 'genSet'`.

- [ ] **Step 3: Implement** (above the test)

```zig
//! Literal sets for the literal backend, `auto`'s Teddy / memmem / prefix-set paths:
//! 1–12 literals (crossing MAX_PREFIX_BRANCHES = 8), 0–20 code points each (crossing
//! MAX_PREFIX_LEN = 16 bytes), with shared prefixes, one literal a prefix of another,
//! duplicates, the empty literal, and optional `(?i)` with fold traps.

pub const max_lits = 12;
pub const max_lit_len = 20;

pub const LitSet = struct {
    bufs: [max_lits][max_lit_len * 4]u8 = undefined,
    lens: [max_lits]usize = [_]usize{0} ** max_lits,
    n: usize = 0,
    ci: bool = false,

    pub fn get(self: *const LitSet, i: usize) []const u8 {
        return self.bufs[i][0..self.lens[i]];
    }

    /// `(?i)`? `lit|lit|…`, metacharacters escaped. `null` if it doesn't fit.
    pub fn pattern(self: *const LitSet, out: []u8) ?[]const u8 {
        var len: usize = 0;
        const put = struct {
            fn f(o: []u8, l: *usize, c: u8) bool {
                if (l.* >= o.len) return false;
                o[l.*] = c;
                l.* += 1;
                return true;
            }
        }.f;
        if (self.ci) for ("(?i)") |c| if (!put(out, &len, c)) return null;
        for (0..self.n) |i| {
            if (i > 0 and !put(out, &len, '|')) return null;
            for (self.get(i)) |c| {
                if (c < 0x80 and std.mem.indexOfScalar(u8, ".^$|?*+()[]{}\\#", c) != null) {
                    if (!put(out, &len, '\\')) return null;
                }
                if (!put(out, &len, c)) return null;
            }
        }
        return out[0..len];
    }
};

fn appendPiece(set: *LitSet, i: usize, piece: []const u8) void {
    if (set.lens[i] + piece.len > set.bufs[i].len) return;
    @memcpy(set.bufs[i][set.lens[i]..][0..piece.len], piece);
    set.lens[i] += piece.len;
}

pub fn genSet(smith: *Smith) LitSet {
    @disableInstrumentation();
    var set: LitSet = .{};
    set.ci = smith.valueRangeAtMost(u8, 0, 3) == 0;
    set.n = smith.valueRangeAtMost(u8, 1, max_lits);
    for (0..set.n) |i| {
        // 1 in 3 literals derive from an earlier one (prefix / extension / duplicate).
        if (i > 0 and smith.valueRangeAtMost(u8, 0, 2) == 0) {
            const src = set.get(smith.index(i));
            switch (smith.valueRangeAtMost(u8, 0, 2)) {
                0 => appendPiece(&set, i, src[0..smith.index(src.len + 1)]), // prefix of an earlier literal
                1 => { // extension
                    appendPiece(&set, i, src);
                    appendPiece(&set, i, ps.alphabet[smith.index(ps.alphabet.len)..][0..1]);
                },
                else => appendPiece(&set, i, src), // duplicate
            }
            continue;
        }
        const cps = smith.valueRangeAtMost(u8, 0, max_lit_len);
        var k: u8 = 0;
        while (k < cps) : (k += 1) {
            if (smith.valueRangeAtMost(u8, 0, 5) == 0) {
                appendPiece(&set, i, ps.trap_raw[smith.index(ps.trap_raw.len)]);
            } else {
                appendPiece(&set, i, ps.alphabet[smith.index(ps.alphabet.len)..][0..1]);
            }
        }
    }
    return set;
}

/// `lit` with its last ASCII byte changed — a near-miss plant.
pub fn nearMiss(lit: []const u8, out: []u8) []const u8 {
    const n = @min(lit.len, out.len);
    @memcpy(out[0..n], lit[0..n]);
    var i = n;
    while (i > 0) {
        i -= 1;
        if (out[i] < 0x80) {
            out[i] = if (out[i] == 'z') 'y' else 'z';
            break;
        }
    }
    return out[0..n];
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add fuzz/gen/literals.zig fuzz/lib.zig
git commit -m "test(fuzz): literal-set generator for literal/Teddy/prefix-set paths"
```

---

## Phase D — The checks

Every check module exposes the same two entry points and each gets its own group binary:

```zig
pub fn run(gpa: std.mem.Allocator, case: *const common.Case) anyerror!void; // deterministic, replayable
pub fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void;         // generate a Case, then known_open.runOrGate(gpa, &case, run)
```

`known_open.runOrGate` skips gated shapes and, on failure, prints the `FUZZ-CASE` line (so `run` itself only prints
diagnostics, never the replay line). Wiring a group is always the same three edits:

1. create `fuzz/groups/<name>.zig` (shown per task);
2. append `"<name>"` to the `fuzz_groups` array in `build.zig`;
3. add `_ = @import("groups/<name>.zig");` to the `test {}` block of `fuzz/root.zig`.

### Task 13: Shared check helpers + `known_open` hook + the `reference` group

**Files:**
- Modify: `fuzz/check/common.zig` (helpers below)
- Create: `fuzz/check/known_open.zig`, `fuzz/check/reference.zig`, `fuzz/groups/reference.zig`
- Modify: `fuzz/lib.zig`, `build.zig`, `fuzz/root.zig`

**Interfaces:**
- Produces (`common`): `NONE = maxInt(usize)`; `Built(B) = union(enum){ ok: gex.Compiled(B), invalid, skip }`; `build(comptime B, gpa, pattern, opt) error{OutOfMemory}!Built(B)`; `buildWith(comptime B, comptime opts: gex.Options, gpa, pattern) error{OutOfMemory}!Built(B)`; `slotsEq([]const ?usize, []const ?usize) bool`; `Summary{ v: [640]usize, n, push(usize), pushMatch(?gex.Match), eql(Summary) bool }`; `summarize(comptime B, gpa, *const gex.Compiled(B), input) !Summary` (find, isMatch, captures when `B.caps.captures`, first 32 findAll spans); `printOpt(*Smith, tree_opt) u8`; `PatBuf`, `Picked{ pattern, opt, tree: ?*const tree.Tree }`, `pickPattern(*Smith, *PatBuf) ?Picked`; `inputWithWitness(gpa, *Smith, *const tree.Tree, buf: []u8) ![]const u8`; `generic_corpus`; `isValidUtf8([]const u8) bool`; `scalarLen(input, i) usize`.
- Produces (`known_open`): `Gate{ id, check: ?CheckId, applies: *const fn (*const Case) bool }`, `gates`, `pub var active: []const Gate`, `gated(*const Case) bool`, `runOrGate(gpa, *const Case, comptime run) anyerror!void`.
- Produces (`reference`): `run`, `fuzzOne`.

- [ ] **Step 1: Write the failing tests**

Create `fuzz/groups/reference.zig`:

```zig
//! Fuzz group: the independent reference differential — Pike VM / backtrack / auto vs the
//! tree-driven reference matcher (span, every capture slot, findAll). See check/reference.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: engines agree with the independent reference (span, captures, findAll)" {
    try std.testing.fuzz({}, lib.check.reference.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
```

Append to the tests at the bottom of `fuzz/check/common.zig`:

```zig
test "summarize + build classify patterns" {
    const gpa = testing.allocator;
    var bad = try build(gex.backends.pikevm, gpa, "(", 0);
    try testing.expect(bad == .invalid);
    var good = try build(gex.backends.pikevm, gpa, "(a)b", 0);
    defer if (good == .ok) good.ok.deinit();
    const s = try summarize(gex.backends.pikevm, gpa, &good.ok, "xab ab");
    // find [1,3], isMatch, captures (0/1 = 1,3; group 1 = 1,2), findAll [1,3] [4,6]
    try testing.expectEqualSlices(usize, &.{ 1, 3, 1, 1, 3, 1, 2, 1, 3, 4, 6 }, s.v[0..s.n]);
}

test "pickPattern mostly yields parseable patterns" {
    var prng = std.Random.DefaultPrng.init(53);
    var sb: [1024]u8 = undefined;
    var pb: PatBuf = .{};
    var ok: usize = 0;
    for (0..500) |_| {
        prng.random().bytes(&sb);
        var s: std.testing.Smith = .{ .in = &sb };
        const p = pickPattern(&s, &pb) orelse continue;
        var diag: gex.Diagnostic = .{};
        if (gex.parse(testing.allocator, p.pattern, &diag)) |a| {
            ok += 1;
            a.deinit(testing.allocator);
        } else |_| {}
    }
    try testing.expect(ok >= 400);
}
```

Add `_ = @import("groups/reference.zig");` to `fuzz/root.zig`'s test block, `"reference"` to `fuzz_groups` in `build.zig`,
and to `fuzz/lib.zig`'s `check` struct: `pub const known_open = @import("check/known_open.zig");` and
`pub const reference = @import("check/reference.zig");` (plus both files in its test block).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile — `root source file struct 'check.reference' has no member named 'fuzzOne'` (or the file is missing).

- [ ] **Step 3: Add the shared helpers to `fuzz/check/common.zig`** (below `compileVariant`)

```zig
const print = @import("../gen/print.zig");
const pattern_gen = @import("../gen/pattern.zig");
const input_gen = @import("../gen/input.zig");
const witness = @import("../gen/witness.zig");
const uni = @import("../ref/uni.zig");
const Smith = std.testing.Smith;

pub const NONE = std.math.maxInt(usize);

pub fn Built(comptime B: type) type {
    return union(enum) { ok: gex.Compiled(B), invalid, skip };
}

/// Compile under option variant `opt`: InvalidPattern → `.invalid`; Unsupported /
/// PatternTooComplex / any routing decline → `.skip`; OOM propagates.
pub fn build(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, opt: u8) error{OutOfMemory}!Built(B) {
    var diag: gex.Diagnostic = .{};
    const re = compileVariant(B, gpa, pattern, &diag, opt) catch |e| return switch (e) {
        error.InvalidPattern => .invalid,
        error.OutOfMemory => error.OutOfMemory,
        else => .skip,
    };
    return .{ .ok = re };
}

/// `build` with an explicit comptime `Options` (strategy-tier variants).
pub fn buildWith(comptime B: type, comptime opts: gex.Options, gpa: std.mem.Allocator, pattern: []const u8) error{OutOfMemory}!Built(B) {
    var diag: gex.Diagnostic = .{};
    const re = gex.compileRuntimeWith(B, gpa, pattern, &diag, opts) catch |e| return switch (e) {
        error.InvalidPattern => .invalid,
        error.OutOfMemory => error.OutOfMemory,
        else => .skip,
    };
    return .{ .ok = re };
}

pub fn slotsEq(a: []const ?usize, b: []const ?usize) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if ((x == null) != (y == null)) return false;
        if (x != null and x.? != y.?) return false;
    }
    return true;
}

/// A flat, comparable record of what an engine returned.
pub const Summary = struct {
    v: [640]usize = undefined,
    n: usize = 0,

    pub fn push(s: *Summary, x: usize) void {
        if (s.n < s.v.len) {
            s.v[s.n] = x;
            s.n += 1;
        }
    }
    pub fn pushMatch(s: *Summary, m: ?gex.Match) void {
        s.push(if (m) |x| x.start else NONE);
        s.push(if (m) |x| x.end else NONE);
    }
    pub fn eql(a: *const Summary, b: *const Summary) bool {
        return a.n == b.n and std.mem.eql(usize, a.v[0..a.n], b.v[0..b.n]);
    }
};

/// find, isMatch, captures (capture backends), and the first 32 findAll spans.
pub fn summarize(comptime B: type, gpa: std.mem.Allocator, re: *const gex.Compiled(B), input: []const u8) !Summary {
    var sc = try re.initScratch(gpa);
    defer sc.deinit(gpa);
    var s: Summary = .{};
    s.pushMatch(re.find(&sc, input));
    s.push(@intFromBool(re.isMatch(&sc, input)));
    if (comptime B.caps.captures) {
        var slots: [96]?usize = undefined;
        const n = re.slotCount();
        if (n <= slots.len) {
            if (re.captures(&sc, slots[0..n], input)) |_| {
                for (slots[0..n]) |x| s.push(x orelse NONE);
            } else s.push(NONE);
        }
    }
    var it = re.findAll(&sc, input);
    var k: usize = 0;
    while (it.next()) |m| : (k += 1) {
        if (k == 32) break;
        s.pushMatch(m);
    }
    return s;
}

/// The option variant to PRINT and COMPILE a tree with: any variant whose only difference
/// from the tree's is the Options-seeded flags (the printer re-establishes them inline).
pub fn printOpt(smith: *Smith, tree_opt: u8) u8 {
    @disableInstrumentation();
    const flag_only = [_]u8{ 0, 3, 4, 5 };
    if (std.mem.indexOfScalar(u8, &flag_only, tree_opt) == null) return tree_opt;
    return flag_only[smith.index(flag_only.len)];
}

pub const PatBuf = struct {
    printed: print.Printed = .{},
    smithy: pattern_gen.PatternSmith = .{},
    t: tree.Tree = undefined,
};
pub const Picked = struct { pattern: []const u8, opt: u8, tree: ?*const tree.Tree };

/// 1:1 a string-level `pattern.gen` pattern (opt 0) or a randomly printed tree.
pub fn pickPattern(smith: *Smith, buf: *PatBuf) ?Picked {
    @disableInstrumentation();
    if (smith.valueRangeAtMost(u8, 0, 1) == 0) {
        buf.smithy = pattern_gen.gen(smith);
        return .{ .pattern = buf.smithy.slice(), .opt = 0, .tree = null };
    }
    buf.t = tree.generate(smith, tree.pickOpt(smith));
    const popt = printOpt(smith, buf.t.opt);
    buf.printed = print.variant(&buf.t, popt, smith.value(u64)) orelse return null;
    return .{ .pattern = buf.printed.slice(), .opt = popt, .tree = &buf.t };
}

/// Half the time a small generated input; half the time noise + a witness of `t` + noise,
/// so the tree actually matches somewhere.
pub fn inputWithWitness(gpa: std.mem.Allocator, smith: *Smith, t: *const tree.Tree, buf: []u8) ![]const u8 {
    @disableInstrumentation();
    if (smith.valueRangeAtMost(u8, 0, 1) == 0) return input_gen.pickSmall(smith, buf);
    var w = (try witness.sample(gpa, t, smith.value(u64))) orelse return input_gen.pickSmall(smith, buf);
    const pre = input_gen.pickSmall(smith, buf[0..@min(buf.len, 12)]);
    var len = pre.len;
    const ws = w.slice();
    if (len + ws.len > buf.len) return buf[0..len];
    @memcpy(buf[len..][0..ws.len], ws);
    len += ws.len;
    var tail: [12]u8 = undefined;
    const post = input_gen.pickSmall(smith, &tail);
    const n = @min(post.len, buf.len - len);
    @memcpy(buf[len..][0..n], post[0..n]);
    return buf[0 .. len + n];
}

pub fn isValidUtf8(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        const d = uni.decode(s, i);
        if (!d.valid) return false;
        i += d.len;
    }
    return true;
}

/// Bytes to the next scalar boundary from `i`: the decoded length, or 1 over a malformed
/// byte (the reference's reading of "resync one byte").
pub fn scalarLen(input: []const u8, i: usize) usize {
    if (i >= input.len) return 1;
    return uni.decode(input, i).len;
}

/// Seed byte streams for the new groups. Generators consume them through `Smith` count
/// draws, so each yields a different, non-trivial case in finite replay.
pub const generic_corpus = [_][]const u8{
    "",
    "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f",
    "\x03\x01\x04\x01\x05\x09\x02\x06\x05\x03\x05\x08\x09\x07\x09\x03\x02\x03\x08\x04",
    "\xff\xfe\xfd\xfc\xfb\xfa\xf9\xf8\xf7\xf6\xf5\xf4\xf3\xf2\xf1\xf0",
    "abcdefghijklmnopqrstuvwxyz0123456789",
    "\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02\x02",
    "\x07\x00\x07\x00\x07\x00\x07\x00\x07\x00\x07\x00\x07\x00\x07\x00",
    "\x10\x20\x30\x40\x50\x60\x70\x80\x90\xa0\xb0\xc0\xd0\xe0\xf0",
};
```

- [ ] **Step 4: Create `fuzz/check/known_open.zig`**

```zig
//! Known-open gates: each skips ONLY the minimized shape of one open finding so a group
//! keeps fuzzing past a bug it already reported. Every skip is counted
//! (`common.stats.gated`); fuzz/health.zig fails if any gate swallows > 1 % of cases. A
//! gate is added together with its ledger entry (fuzz/findings.zig) and removed with the fix.

const std = @import("std");
const common = @import("common.zig");

pub const Gate = struct {
    id: []const u8,
    /// Restrict to one check (null = any).
    check: ?common.CheckId = null,
    applies: *const fn (case: *const common.Case) bool,
};

pub const gates = [_]Gate{};

/// The gate list in force. Tests swap in a fake list to prove the rate guard fires.
pub var active: []const Gate = &gates;

pub fn gated(case: *const common.Case) bool {
    for (active, 0..) |g, i| {
        if (g.check) |c| if (c != case.check) continue;
        if (g.applies(case)) {
            if (i < common.max_gates) common.stats.gated[i] += 1;
            return true;
        }
    }
    return false;
}

/// Skip a gated case; otherwise run it and, on failure, print its replayable line.
pub fn runOrGate(
    gpa: std.mem.Allocator,
    case: *const common.Case,
    comptime run: fn (std.mem.Allocator, *const common.Case) anyerror!void,
) anyerror!void {
    if (gated(case)) return;
    run(gpa, case) catch |e| {
        case.report("check {s} failed: {s}", .{ @tagName(case.check), @errorName(e) });
        return e;
    };
}
```

- [ ] **Step 5: Create `fuzz/check/reference.zig`**

```zig
//! Reference differential — the one check that can catch a bug in ezi_gex's SHARED front
//! end: Pike VM, backtrack, and `auto` must agree with the independent reference matcher
//! (ref/) on the span, every capture slot, and the findAll sequence, over trees printed in
//! a random equivalent spelling under a random (compatible) option variant.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const tree = @import("../gen/tree.zig");
const print = @import("../gen/print.zig");
const witness = @import("../gen/witness.zig");
const ref = @import("../ref/root.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

const max_matches = 64;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    const t = tree.generate(smith, tree.pickOpt(smith));
    const popt = common.printOpt(smith, t.opt);
    const seed = smith.value(u64);
    var ibuf: [2 * witness.max_witness]u8 = undefined;
    const input = try common.inputWithWitness(gpa, smith, &t, &ibuf);
    const pr = print.variant(&t, popt, seed) orelse return;
    const case: Case = .{ .check = .reference, .pattern = pr.slice(), .input = input, .tree = t.bytes(), .opt = popt, .seed = seed };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    const t = tree.Tree.fromBytes(case.tree) orelse return error.BadTree;
    if (!print.compatibleOpts(t.opt, case.opt)) return error.BadCase;
    const pr = print.variant(&t, case.opt, case.seed) orelse return;
    var r = ref.Ref.init(gpa, &t) catch |e| switch (e) {
        error.ProgramTooBig => return,
        else => return e,
    };
    defer r.deinit();
    const ns = r.slotCount();
    var want_slots: [ref.max_slots]?usize = undefined;
    const want = try r.find(case.input, .{}, want_slots[0..ns]);
    var want_all: std.ArrayList([2]usize) = .empty;
    defer want_all.deinit(gpa);
    try r.findAll(case.input, &want_all, max_matches);
    common.noteRun(.reference, true);
    inline for (.{ gex.backends.pikevm, gex.backends.backtrack, gex.backends.auto }) |B| {
        try check(B, gpa, pr.slice(), case, want, want_slots[0..ns], want_all.items);
    }
}

fn check(comptime B: type, gpa: std.mem.Allocator, pattern: []const u8, case: *const Case, want: ?[2]usize, want_slots: []const ?usize, want_all: []const [2]usize) anyerror!void {
    var built = try common.build(B, gpa, pattern, case.opt);
    switch (built) {
        .ok => {},
        .invalid => {
            std.debug.print("reference: {s} rejected a printed tree /{s}/\n", .{ @typeName(B), pattern });
            return error.PrintedTreeRejected;
        },
        .skip => return common.noteSkipped(.reference, B),
    }
    const re = &built.ok;
    defer re.deinit();
    common.noteCompared(.reference, B);
    if (re.slotCount() != want_slots.len) {
        std.debug.print("reference ({s}): slot count {d} != reference {d}\n", .{ @typeName(B), re.slotCount(), want_slots.len });
        return error.CaptureCountMismatch;
    }
    var sc = try re.initScratch(gpa);
    defer sc.deinit(gpa);
    var slots: [ref.max_slots]?usize = undefined;
    const got = re.captures(&sc, slots[0..want_slots.len], case.input);
    const got_span: ?[2]usize = if (got) |c| .{ c.match().start, c.match().end } else null;
    if (!common.spanEq(want, got_span)) {
        std.debug.print("reference ({s}): span want {?any} got {?any}\n", .{ @typeName(B), want, got_span });
        return error.ReferenceSpan;
    }
    if (got != null and !common.slotsEq(want_slots, slots[0..want_slots.len])) {
        std.debug.print("reference ({s}): slots want {any} got {any}\n", .{ @typeName(B), want_slots, slots[0..want_slots.len] });
        return error.ReferenceCaptures;
    }
    var it = re.findAll(&sc, case.input);
    for (want_all, 0..) |w, k| {
        const m = it.next() orelse {
            std.debug.print("reference ({s}): findAll ended after {d} matches, reference has {d} (next {any})\n", .{ @typeName(B), k, want_all.len, w });
            return error.ReferenceFindAll;
        };
        if (m.start != w[0] or m.end != w[1]) {
            std.debug.print("reference ({s}): findAll[{d}] want {any} got [{d},{d}]\n", .{ @typeName(B), k, w, m.start, m.end });
            return error.ReferenceFindAll;
        }
    }
    if (want_all.len < max_matches) if (it.next()) |m| {
        std.debug.print("reference ({s}): findAll has an extra match [{d},{d}] after {d}\n", .{ @typeName(B), m.start, m.end, want_all.len });
        return error.ReferenceFindAll;
    };
}

test "reference check passes on a simple case and rejects a corrupt tree" {
    const gpa = std.testing.allocator;
    var b = tree.Builder.init(0);
    const t = b.finish(b.alt(&.{ b.lit('a'), b.cat(&.{ b.lit('a'), b.lit('b') }) }));
    const pr = print.canonical(&t, 0).?;
    try run(gpa, &.{ .check = .reference, .pattern = pr.slice(), .input = "xab", .tree = t.bytes() });
    try std.testing.expectError(error.BadTree, run(gpa, &.{ .check = .reference, .tree = "junk" }));
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS.

Run: `zig build fuzz-reference -Doptimize=ReleaseSafe`
Expected: exit 0 (finite seed replay).

Run: `zig build fuzz-reference -Doptimize=ReleaseSafe --fuzz=20K`
Expected: either exit 0, or a `check reference failed: …` report with a `FUZZ-CASE` line. **A report here is the
point of this task, not a failure of it.** Save the full line to `fuzz/README.md` → *Open (to triage)* (Task 30 triages
it) and continue — the task's deliverable is the check, and the finite smoke (previous command) must stay green.

- [ ] **Step 7: Commit**

```sh
git add fuzz/check/common.zig fuzz/check/known_open.zig fuzz/check/reference.zig fuzz/groups/reference.zig fuzz/lib.zig fuzz/root.zig build.zig fuzz/README.md
git commit -m "test(fuzz): reference differential group + shared check helpers + known-open hook"
```

---

### Task 14: `metamorphic` group — two printings of one tree must behave identically

**Files:**
- Create: `fuzz/check/metamorphic.zig`, `fuzz/groups/metamorphic.zig`
- Modify: `fuzz/lib.zig`, `build.zig`, `fuzz/root.zig`

**Interfaces:**
- Consumes: `common.{build, summarize, Summary, byteEnginesSafe, isByteEngine, printOpt, inputWithWitness}`, `print.variant`, `input_gen.foldSwap`.
- Produces: `run`, `fuzzOne`, `allCaseInsensitive(*const tree.Tree) bool`.
- Case fields: `tree`; `opt`/`seed` = printing A; `opt2`/`seed2` = printing B (`seed2` is never 0, so B is never canonical).

- [ ] **Step 1: Write the failing group file** `fuzz/groups/metamorphic.zig`:

```zig
//! Fuzz group: metamorphic printing — two equivalent spellings of one semantic tree must
//! give identical find / isMatch / captures / findAll on every backend; plus the fold-swap
//! relation for all-`(?i)` trees. See check/metamorphic.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: equivalent printings of one tree behave identically on every backend" {
    try std.testing.fuzz({}, lib.check.metamorphic.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
```

Wire it (group list, root import, `pub const metamorphic = @import("check/metamorphic.zig");` in lib `check` + test block).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile (missing `check/metamorphic.zig`).

- [ ] **Step 3: Implement `fuzz/check/metamorphic.zig`**

```zig
//! Metamorphic check. Each printer choice (escape spelling, grouping, flag placement,
//! `(?x)` text, quantifier spelling, `{m,n}` expansion, named vs numbered groups,
//! Options-seeded vs inline flags) is a no-op the front end must honour; so two printings
//! of one tree must produce the same Summary on every backend. And when every node is
//! `(?i)` under simple folding, swapping input code points within their fold orbits must
//! not change `isMatch` or the match count.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const tree = @import("../gen/tree.zig");
const print = @import("../gen/print.zig");
const input_gen = @import("../gen/input.zig");
const witness = @import("../gen/witness.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    const t = tree.generate(smith, tree.pickOpt(smith));
    const opt_a = common.printOpt(smith, t.opt);
    const opt_b = common.printOpt(smith, t.opt);
    const seed_a = smith.value(u64);
    const seed_b = smith.value(u64) | 1;
    var ibuf: [2 * witness.max_witness]u8 = undefined;
    const input = try common.inputWithWitness(gpa, smith, &t, &ibuf);
    const pa = print.variant(&t, opt_a, seed_a) orelse return;
    const case: Case = .{ .check = .metamorphic, .pattern = pa.slice(), .input = input, .tree = t.bytes(), .opt = opt_a, .seed = seed_a, .opt2 = opt_b, .seed2 = seed_b };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn allCaseInsensitive(t: *const tree.Tree) bool {
    for (t.nodes[0..t.n_nodes]) |n| if (!n.flags.i) return false;
    return true;
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    const t = tree.Tree.fromBytes(case.tree) orelse return error.BadTree;
    if (!print.compatibleOpts(t.opt, case.opt) or !print.compatibleOpts(t.opt, case.opt2)) return error.BadCase;
    const pa = print.variant(&t, case.opt, case.seed) orelse return;
    const pb = print.variant(&t, case.opt2, case.seed2) orelse return;
    common.noteRun(.metamorphic, true);
    const byte_safe = common.byteEnginesSafe(gpa, pa.slice(), case.input);
    inline for (common.all_backends) |B| try pair(B, gpa, case, pa.slice(), pb.slice(), byte_safe);
    if (allCaseInsensitive(&t) and tree.opt_sem[t.opt].fold) try foldSwapRelation(gpa, case, pa.slice());
}

fn pair(comptime B: type, gpa: std.mem.Allocator, case: *const Case, pa: []const u8, pb: []const u8, byte_safe: bool) anyerror!void {
    if (comptime common.isByteEngine(B)) if (!byte_safe) return common.noteSkipped(.metamorphic, B);
    var ba = try common.build(B, gpa, pa, case.opt);
    defer if (ba == .ok) ba.ok.deinit();
    var bb = try common.build(B, gpa, pb, case.opt2);
    defer if (bb == .ok) bb.ok.deinit();
    if (ba == .skip or bb == .skip) return common.noteSkipped(.metamorphic, B);
    if (ba == .invalid or bb == .invalid) {
        std.debug.print("metamorphic ({s}): validity A={s} B={s}\n  A=/{s}/\n  B=/{s}/\n", .{ @typeName(B), @tagName(ba), @tagName(bb), pa, pb });
        return error.PrintedTreeRejected;
    }
    common.noteCompared(.metamorphic, B);
    const sa = try common.summarize(B, gpa, &ba.ok, case.input);
    const sb = try common.summarize(B, gpa, &bb.ok, case.input);
    if (!sa.eql(&sb)) {
        std.debug.print("metamorphic ({s}): printings disagree\n  A=/{s}/ → {any}\n  B=/{s}/ → {any}\n", .{ @typeName(B), pa, sa.v[0..sa.n], pb, sb.v[0..sb.n] });
        return error.MetamorphicDivergence;
    }
}

fn foldSwapRelation(gpa: std.mem.Allocator, case: *const Case, pattern: []const u8) anyerror!void {
    var sbuf: [4 * 2 * witness.max_witness]u8 = undefined;
    const swapped = input_gen.foldSwap(case.input, &sbuf, case.seed2);
    inline for (.{ gex.backends.pikevm, gex.backends.auto }) |B| {
        var b = try common.build(B, gpa, pattern, case.opt);
        if (b == .ok) {
            defer b.ok.deinit();
            var sc = try b.ok.initScratch(gpa);
            defer sc.deinit(gpa);
            const m1 = b.ok.isMatch(&sc, case.input);
            const m2 = b.ok.isMatch(&sc, swapped);
            const c1 = b.ok.count(&sc, case.input);
            const c2 = b.ok.count(&sc, swapped);
            if (m1 != m2 or c1 != c2) {
                std.debug.print("fold-swap ({s}): /{s}/ isMatch {} vs {}, count {d} vs {d}\n  in  = \"{s}\"\n  swap= \"{s}\"\n", .{ @typeName(B), pattern, m1, m2, c1, c2, case.input, swapped });
                return error.FoldSwapDivergence;
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe && zig build fuzz-metamorphic -Doptimize=ReleaseSafe`
Expected: PASS / exit 0.

Run: `zig build fuzz-metamorphic -Doptimize=ReleaseSafe --fuzz=20K`
Expected: exit 0 or a reported `FUZZ-CASE` → record under *Open (to triage)* (as in Task 13, Step 6).

- [ ] **Step 5: Commit**

```sh
git add fuzz/check/metamorphic.zig fuzz/groups/metamorphic.zig fuzz/lib.zig fuzz/root.zig build.zig fuzz/README.md
git commit -m "test(fuzz): metamorphic printing group (+ fold-swap relation)"
```

---

### Task 15: `invariants` group — oracle-free laws on every backend

**Files:**
- Create: `fuzz/check/invariants.zig`, `fuzz/groups/invariants.zig`
- Modify: `fuzz/lib.zig`, `build.zig`, `fuzz/root.zig`

**Interfaces:**
- Consumes: `common.{build, pickPattern, PatBuf, byteEnginesSafe, isByteEngine, scalarLen, isValidUtf8, NONE}`, `input_gen.pickSmall`.
- Produces: `run`, `fuzzOne`. Laws (each backend `B`, from `case.searchOptions()`):
  1. `isMatchAt(so) == (findAt(so) != null)`.
  2. unanchored `findAt(so)` == first anchored `findAt(k)` over `k = so.start, k += scalarLen …` up to the clamped end (same `span_end`).
  3. `findAll`: `start ≤ end ≤ len`; non-overlapping; first == `findAt(0)`; each next == `findAt(resume)` where `resume` = previous end, or previous end + `scalarLen` after an empty match; `count == |findAll|` (≤ 64).
  4. captures (capture backends): slot 0/1 == find span; each group ⊆ group 0 with start ≤ end; over valid UTF-8 every offset is a scalar boundary.
  5. `replaceAllAlloc("$0") == input`; split pieces interleaved with the non-empty matches rebuild `input`.

- [ ] **Step 1: Write the failing group file + a law unit test**

`fuzz/groups/invariants.zig`:

```zig
//! Fuzz group: oracle-free laws on EVERY backend — isMatchAt/findAt consistency,
//! unanchored = first anchored, findAll resume consistency, capture-slot containment,
//! replace/split reconstruction. See check/invariants.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: oracle-free laws hold on every backend" {
    try std.testing.fuzz({}, lib.check.invariants.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
```

Wire it (group list, root import, lib `check.invariants` + test block).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile (missing module).

- [ ] **Step 3: Implement `fuzz/check/invariants.zig`**

```zig
//! Oracle-free invariants: laws every backend must satisfy on its own, independent of any
//! other engine. Because they need no oracle they hold for backends the differential can
//! only skip, and they pin the search API's contract (offsets, anchoring, span_end,
//! iteration resume) rather than a particular answer.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pb: common.PatBuf = .{};
    const p = common.pickPattern(smith, &pb) orelse return;
    var ibuf: [input_gen.max_input_len]u8 = undefined;
    const input = input_gen.pickSmall(smith, &ibuf);
    const start = smith.index(input.len + 1);
    const span_end: ?usize = if (smith.valueRangeAtMost(u8, 0, 3) == 0) start + smith.index(input.len - start + 1) else null;
    const case: Case = .{ .check = .invariants, .pattern = p.pattern, .input = input, .opt = p.opt, .start = start, .anchored = smith.valueRangeAtMost(u8, 0, 1) == 0, .span_end = span_end };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    if (case.start > case.input.len) return error.BadCase;
    common.noteRun(.invariants, true);
    const byte_safe = common.byteEnginesSafe(gpa, case.pattern, case.input);
    inline for (common.all_backends) |B| try laws(B, gpa, case, byte_safe);
}

fn fail(comptime B: type, case: *const Case, comptime what: []const u8, args: anytype, e: anyerror) anyerror {
    std.debug.print("invariant ({s}) on /{s}/: " ++ what ++ "\n", .{ @typeName(B), case.pattern } ++ args);
    return e;
}

fn matchEq(a: ?gex.Match, b: ?gex.Match) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.start == b.?.start and a.?.end == b.?.end;
}

fn isBoundary(s: []const u8, off: usize) bool {
    return off == 0 or off >= s.len or (s[off] & 0xC0) != 0x80;
}

fn laws(comptime B: type, gpa: std.mem.Allocator, case: *const Case, byte_safe: bool) anyerror!void {
    if (comptime common.isByteEngine(B)) if (!byte_safe) return common.noteSkipped(.invariants, B);
    var built = try common.build(B, gpa, case.pattern, case.opt);
    switch (built) {
        .ok => {},
        .invalid => return,
        .skip => return common.noteSkipped(.invariants, B),
    }
    const re = &built.ok;
    defer re.deinit();
    common.noteCompared(.invariants, B);
    var sc = try re.initScratch(gpa);
    defer sc.deinit(gpa);
    var sc2 = try re.initScratch(gpa);
    defer sc2.deinit(gpa);
    const in = case.input;
    const so = case.searchOptions();

    // 1 ── isMatchAt == (findAt != null)
    const fa = re.findAt(&sc, in, so);
    if (re.isMatchAt(&sc, in, so) != (fa != null)) return fail(B, case, "isMatchAt != (findAt != null) at {any}", .{so}, error.IsMatchAtInconsistent);

    // 2 ── unanchored == first anchored success over scalar-stepped starts
    {
        var ua = so;
        ua.anchored = false;
        const u = re.findAt(&sc, in, ua);
        const end = if (so.span_end) |e| @min(e, in.len) else in.len;
        var first: ?gex.Match = null;
        var k = so.start;
        while (k <= end) {
            var a = ua;
            a.start = k;
            a.anchored = true;
            if (re.findAt(&sc, in, a)) |m| {
                first = m;
                break;
            }
            if (k == end) break;
            k += common.scalarLen(in[0..end], k);
        }
        if (!matchEq(u, first)) return fail(B, case, "unanchored {?any} != first anchored {?any} (start={d} span_end={?d})", .{ u, first, so.start, so.span_end }, error.UnanchoredNotFirstAnchored);
    }

    // 3 ── findAll resume consistency, monotonicity, count
    {
        var it = re.findAll(&sc, in);
        var prev: ?gex.Match = null;
        var n: usize = 0;
        while (it.next()) |m| : (n += 1) {
            if (n == 64) break;
            if (m.start > m.end or m.end > in.len) return fail(B, case, "findAll match [{d},{d}] out of range", .{ m.start, m.end }, error.FindAllRange);
            const resume = if (prev) |p| (if (p.end > p.start) p.end else p.end + common.scalarLen(in, p.end)) else 0;
            if (prev) |p| if (m.start < p.end) return fail(B, case, "findAll overlap [{d},{d}] after [{d},{d}]", .{ m.start, m.end, p.start, p.end }, error.FindAllOverlap);
            const want = if (resume <= in.len) re.findAt(&sc2, in, .{ .start = resume }) else null;
            if (!matchEq(want, m)) return fail(B, case, "findAll[{d}] = [{d},{d}] but findAt(resume={d}) = {?any}", .{ n, m.start, m.end, resume, want }, error.FindAllResume);
            prev = m;
        }
        if (n < 64) {
            const c = re.count(&sc2, in);
            if (c != n) return fail(B, case, "count {d} != findAll length {d}", .{ c, n }, error.CountMismatch);
            // The iteration also must not stop early: nothing left after the last resume point.
            if (prev) |p| {
                const resume = if (p.end > p.start) p.end else p.end + common.scalarLen(in, p.end);
                if (resume <= in.len) if (re.findAt(&sc2, in, .{ .start = resume })) |extra|
                    return fail(B, case, "findAll stopped but findAt(resume={d}) = [{d},{d}]", .{ resume, extra.start, extra.end }, error.FindAllStoppedEarly);
            }
        }
    }

    if (comptime !B.caps.captures) return;
    var slots: [96]?usize = undefined;
    const ns = re.slotCount();
    if (ns > slots.len) return;

    // 4 ── capture slots
    if (re.captures(&sc, slots[0..ns], in)) |_| {
        const f = re.find(&sc2, in) orelse return fail(B, case, "captures matched but find returned null", .{}, error.CaptureFindDisagree);
        if (slots[0] != f.start or slots[1] != f.end) return fail(B, case, "captures slot0 {?d}..{?d} != find [{d},{d}]", .{ slots[0], slots[1], f.start, f.end }, error.CaptureSpanMismatch);
        const valid = common.isValidUtf8(in);
        var g: usize = 1;
        while (2 * g + 1 < ns) : (g += 1) {
            const s = slots[2 * g] orelse continue;
            const e = slots[2 * g + 1] orelse return fail(B, case, "group {d} has a start but no end", .{g}, error.CaptureHalfSet);
            if (s > e or s < f.start or e > f.end) return fail(B, case, "group {d} [{d},{d}] outside group 0 [{d},{d}]", .{ g, s, e, f.start, f.end }, error.CaptureOutsideMatch);
            if (valid and (!isBoundary(in, s) or !isBoundary(in, e))) return fail(B, case, "group {d} [{d},{d}] splits a code point", .{ g, s, e }, error.CaptureMidCodePoint);
        }
    }

    // 5 ── replace / split reconstruction
    {
        const out = try re.replaceAllAlloc(gpa, &sc, in, "$0", slots[0..ns]);
        defer gpa.free(out);
        if (!std.mem.eql(u8, out, in)) return fail(B, case, "replaceAll(\"$0\") = \"{s}\" != input \"{s}\"", .{ out, in }, error.ReplaceIdentity);

        var rebuilt: std.ArrayList(u8) = .empty;
        defer rebuilt.deinit(gpa);
        var pieces = re.split(&sc, in);
        var matches = re.findAll(&sc2, in);
        try rebuilt.appendSlice(gpa, pieces.next() orelse "");
        var guard: usize = 0;
        while (matches.next()) |m| {
            guard += 1;
            if (guard > 256) return;
            if (m.isEmpty()) continue;
            try rebuilt.appendSlice(gpa, in[m.start..m.end]);
            try rebuilt.appendSlice(gpa, pieces.next() orelse return fail(B, case, "split ran out of pieces", .{}, error.SplitPieces));
        }
        if (!std.mem.eql(u8, rebuilt.items, in)) return fail(B, case, "split ⧺ matches = \"{s}\" != input \"{s}\"", .{ rebuilt.items, in }, error.SplitReconstruction);
    }
}

test "odd search options never panic (start mid-code-point / at len, span_end before start)" {
    // Only "no panic, no out-of-bounds" is asserted here; a law violation on these inputs
    // is a finding the fuzz group reports, not a failure of this test.
    const gpa = std.testing.allocator;
    for ([_]Case{
        .{ .check = .invariants, .pattern = ".", .input = "\xC3\xA9x", .start = 1 },
        .{ .check = .invariants, .pattern = "a*", .input = "ab", .start = 2 },
        .{ .check = .invariants, .pattern = "b", .input = "ab", .start = 2, .span_end = 1 },
        .{ .check = .invariants, .pattern = "\\b", .input = "\xC3\xA9", .start = 1, .anchored = true },
        .{ .check = .invariants, .pattern = "(a)|b", .input = "", .start = 0, .span_end = 0 },
    }) |c| run(gpa, &c) catch {};
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe && zig build fuzz-invariants -Doptimize=ReleaseSafe`
Expected: PASS / exit 0.

Run: `zig build fuzz-invariants -Doptimize=ReleaseSafe --fuzz=20K`
Expected: exit 0 or a report → *Open (to triage)*. Expect the empty-match resume law (#3) to be the first to fire
on inputs with a malformed lead byte after an empty match (the suspected `advanceCodePoint` over-skip, see Task 30).

- [ ] **Step 5: Commit**

```sh
git add fuzz/check/invariants.zig fuzz/groups/invariants.zig fuzz/lib.zig fuzz/root.zig build.zig fuzz/README.md
git commit -m "test(fuzz): oracle-free invariant laws on every backend"
```

---

### Task 16: `state` group — one long-lived Scratch, mutated buffers, abandoned iterators

**Files:**
- Create: `fuzz/check/state.zig`, `fuzz/groups/state.zig`
- Modify: `fuzz/lib.zig`, `build.zig`, `fuzz/root.zig`

**Interfaces:**
- Consumes: `common.{build, pickPattern, PatBuf, Summary, byteEnginesSafe, isByteEngine, NONE}`, `input_gen.pickSmall`, `gex.backends.backtrack.fits`.
- Produces: `run`, `fuzzOne`, `max_hay = 64`, `steps = 8`. `case.seed` drives the script PRNG; `case.input` is the initial buffer.
- Script moves per step: `0` new content/length in the same buffer · `1` **same ptr + len, bytes mutated in place** (the 2b48f18 class) · `2` shorter prefix of the same ptr · `3` same bytes at a different ptr · `4` unchanged (then `same_input` may honestly be set). After each step a SECOND regex (from `other_patterns`, same backend) runs findAll on its own long-lived scratch and must match a fresh Pike VM — state shared across compiled regexes shows up there. Ops: `0` findAt · `1` isMatchAt · `2` capturesAt · `3` count · `4` findAll (≤ 32) · `5` replaceAllAlloc("<$0>") · `6` findAll abandoned after `k` matches. Each op's result on the long-lived scratch — heap AND `initBuffer`-backed — must equal a FRESH-scratch Pike VM's.

- [ ] **Step 1: Write the failing group file** `fuzz/groups/state.zig`:

```zig
//! Fuzz group: scratch state — a script of searches on ONE long-lived Scratch (heap and
//! buffer-backed) over a buffer that is refilled in place, truncated, moved, and iterated
//! partially, must match a fresh-scratch Pike VM at every step. See check/state.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: a long-lived, dirty scratch behaves like a fresh one" {
    try std.testing.fuzz({}, lib.check.state.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
```

Wire it (group list, root import, lib `check.state` + test block).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile (missing module).

- [ ] **Step 3: Implement `fuzz/check/state.zig`**

```zig
//! Scratch-state check. Every built-in keeps mutable per-search state in the caller's
//! Scratch (generation stamps, lazy-DFA caches, `auto`'s input-derived verdicts). The
//! other groups always use a FRESH scratch, so none of them can see state leaking between
//! searches — the class of 2b48f18 (a `(ptr,len)`-keyed ASCII cache served a stale verdict
//! after the caller refilled the same buffer). Here one scratch lives through a script.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;
const Summary = common.Summary;

pub const max_hay = 64;
pub const steps = 8;

const mutation_bytes = "abAB1 \n_\xC3\xA9\xE2\x84\xAA\xFF\x80\xE6";

/// A second regex, driven on its OWN long-lived scratch between the main script's ops, to
/// catch state shared across compiled regexes (globals, static caches).
const other_patterns = [_][]const u8{ "\\b\\w+\\b", "a|ab", "(?i)k", "\\p{L}+", "[^a]" };

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pb: common.PatBuf = .{};
    const p = common.pickPattern(smith, &pb) orelse return;
    var ibuf: [max_hay]u8 = undefined;
    const input = input_gen.pickSmall(smith, &ibuf);
    const case: Case = .{ .check = .state, .pattern = p.pattern, .input = input, .opt = p.opt, .seed = smith.value(u64) };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    if (case.input.len > max_hay) return error.BadCase;
    common.noteRun(.state, true);
    inline for (common.all_backends) |B| try script(B, gpa, case);
}

fn doOp(comptime B: type, gpa: std.mem.Allocator, re: *const gex.Compiled(B), sc: *gex.Compiled(B).Scratch, op: u8, in: []const u8, so: gex.SearchOptions, k: usize) !Summary {
    var s: Summary = .{};
    var slots: [96]?usize = undefined;
    const ns = @min(re.slotCount(), slots.len);
    switch (op) {
        0 => s.pushMatch(re.findAt(sc, in, so)),
        1 => s.push(@intFromBool(re.isMatchAt(sc, in, so))),
        2 => if (comptime B.caps.captures) {
            if (re.capturesAt(sc, slots[0..ns], in, so)) |_| {
                for (slots[0..ns]) |x| s.push(x orelse common.NONE);
            } else s.push(common.NONE);
        } else unreachable,
        3 => s.push(re.count(sc, in)),
        4 => {
            var it = re.findAll(sc, in);
            var j: usize = 0;
            while (it.next()) |m| : (j += 1) {
                if (j == 32) break;
                s.pushMatch(m);
            }
        },
        5 => if (comptime B.caps.captures) {
            const out = try re.replaceAllAlloc(gpa, sc, in, "<$0>", slots[0..ns]);
            defer gpa.free(out);
            s.push(out.len);
            s.push(@intCast(std.hash.Wyhash.hash(0, out)));
        } else unreachable,
        else => { // abandon a findAll after k matches
            var it = re.findAll(sc, in);
            var j: usize = 0;
            while (j < k) : (j += 1) s.pushMatch(it.next() orelse break);
        },
    }
    return s;
}

fn script(comptime B: type, gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    var built = try common.build(B, gpa, case.pattern, case.opt);
    if (built != .ok) return if (built == .skip) common.noteSkipped(.state, B) else {};
    const re = &built.ok;
    defer re.deinit();
    var oracle_b = try common.build(gex.backends.pikevm, gpa, case.pattern, case.opt);
    if (oracle_b != .ok) return;
    const oracle = &oracle_b.ok;
    defer oracle.deinit();
    common.noteCompared(.state, B);

    const Re = @TypeOf(re.*);
    var heap = try re.initScratch(gpa);
    defer heap.deinit(gpa);
    const has_buf = comptime Re.Scratch.Buf != void;
    const cells: []Re.Scratch.Buf = if (has_buf) try gpa.alloc(Re.Scratch.Buf, re.scratchBufferLen()) else &.{};
    defer if (has_buf) gpa.free(cells);
    var buffered: Re.Scratch = if (has_buf) try re.initScratchBuffer(cells) else undefined;

    const other_pat = other_patterns[case.seed % other_patterns.len];
    var other_b = try common.build(B, gpa, other_pat, 0);
    defer if (other_b == .ok) other_b.ok.deinit();
    var other_ob = try common.build(gex.backends.pikevm, gpa, other_pat, 0);
    defer if (other_ob == .ok) other_ob.ok.deinit();
    const have_other = other_b == .ok and other_ob == .ok;
    var other_sc = if (have_other) try other_b.ok.initScratch(gpa) else undefined;
    defer if (have_other) other_sc.deinit(gpa);

    var hay_a: [max_hay]u8 = undefined;
    var hay_b: [max_hay]u8 = undefined;
    @memcpy(hay_a[0..case.input.len], case.input);
    var cur: []u8 = hay_a[0..case.input.len];
    var prev: ?[]const u8 = null;
    var prng = std.Random.DefaultPrng.init(case.seed);
    const r = prng.random();

    for (0..steps) |step| {
        const move = r.uintLessThan(u8, 5);
        switch (move) {
            0 => {
                const n = r.uintAtMost(usize, max_hay);
                const base: []u8 = if (@intFromPtr(cur.ptr) == @intFromPtr(&hay_a)) &hay_a else &hay_b;
                for (base[0..n]) |*b| b.* = mutation_bytes[r.uintLessThan(usize, mutation_bytes.len)];
                cur = base[0..n];
            },
            1 => if (cur.len > 0) {
                const k = 1 + r.uintLessThan(usize, cur.len);
                for (0..k) |_| cur[r.uintLessThan(usize, cur.len)] = mutation_bytes[r.uintLessThan(usize, mutation_bytes.len)];
            },
            2 => cur = cur[0..r.uintAtMost(usize, cur.len)],
            3 => {
                const other: []u8 = if (@intFromPtr(cur.ptr) == @intFromPtr(&hay_a)) &hay_b else &hay_a;
                @memcpy(other[0..cur.len], cur);
                cur = other[0..cur.len];
            },
            else => {},
        }
        const unchanged = move == 4 and prev != null and prev.?.ptr == cur.ptr and prev.?.len == cur.len;
        var op = r.uintLessThan(u8, 7);
        if (!B.caps.captures and (op == 2 or op == 5)) op = 0;
        const start = r.uintAtMost(usize, cur.len);
        var so: gex.SearchOptions = .{
            .start = start,
            .anchored = r.boolean(),
            .span_end = if (r.uintLessThan(u8, 4) == 0) start + r.uintAtMost(usize, cur.len - start) else null,
        };
        const k = r.uintAtMost(usize, 3);

        var osc = try oracle.initScratch(gpa);
        defer osc.deinit(gpa);
        const want = try doOp(gex.backends.pikevm, gpa, oracle, &osc, op, cur, so, k);

        so.same_input = unchanged and r.boolean(); // an HONEST assertion only
        const byte_ok = !common.isByteEngine(B) or common.byteEnginesSafe(gpa, case.pattern, cur);
        if (byte_ok) {
            const got = try doOp(B, gpa, re, &heap, op, cur, so, k);
            if (!got.eql(&want)) return report(B, "heap", case, step, move, op, cur, so, &want, &got);
            if (has_buf) {
                // A buffer-backed backtracker has a fixed visited-set ceiling; `fits` reports it
                // (exceeding it panics by contract). Other backends have no input ceiling.
                const fits = if (comptime B == gex.backends.backtrack) gex.backends.backtrack.fits(&re.program, &buffered.inner, cur) else true;
                if (fits) {
                    const gb = try doOp(B, gpa, re, &buffered, op, cur, so, k);
                    if (!gb.eql(&want)) return report(B, "buffer", case, step, move, op, cur, so, &want, &gb);
                }
            }
        }
        // Interleave the second regex on its own long-lived scratch.
        if (have_other and (!common.isByteEngine(B) or common.byteEnginesSafe(gpa, other_pat, cur))) {
            var fsc = try other_ob.ok.initScratch(gpa);
            defer fsc.deinit(gpa);
            const ow = try doOp(gex.backends.pikevm, gpa, &other_ob.ok, &fsc, 4, cur, .{}, 0);
            const og = try doOp(B, gpa, &other_b.ok, &other_sc, 4, cur, .{}, 0);
            if (!og.eql(&ow)) return report(B, "second-regex", case, step, move, 4, cur, .{}, &ow, &og);
        }
        prev = cur;
    }
}

fn report(comptime B: type, kind: []const u8, case: *const Case, step: usize, move: u8, op: u8, cur: []const u8, so: gex.SearchOptions, want: *const Summary, got: *const Summary) anyerror {
    std.debug.print("state ({s}, {s} scratch) on /{s}/: step {d} move {d} op {d} over \"{s}\" {any}\n  fresh pikevm: {any}\n  long-lived:   {any}\n", .{
        @typeName(B), kind, case.pattern, step, move, op, cur, so, want.v[0..want.n], got.v[0..got.n],
    });
    return error.StaleScratch;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe && zig build fuzz-state -Doptimize=ReleaseSafe`
Expected: PASS / exit 0.

Run: `zig build fuzz-state -Doptimize=ReleaseSafe --fuzz=20K`
Expected: exit 0 or a report → *Open (to triage)*.

- [ ] **Step 5: Revert-check the check (it must catch the 2b48f18 class)**

Temporarily change `const unchanged = move == 4 and …` to `const unchanged = prev != null and prev.?.ptr == cur.ptr and prev.?.len == cur.len;` (asserting `same_input` falsely after an in-place mutation), then run
`zig build fuzz-state -Doptimize=ReleaseSafe --fuzz=50K`.
Expected: a `StaleScratch` report on an `auto` + `\b` pattern over a refilled non-ASCII buffer within the run (the
caller-lie the 0.7.0 contract warns about). Revert the line. If nothing fires in 50K, the script is too weak — raise the
share of `move == 1` and `\b` patterns before committing. (Record the observed iteration count in the commit message.)

- [ ] **Step 6: Commit**

```sh
git add fuzz/check/state.zig fuzz/groups/state.zig fuzz/lib.zig fuzz/root.zig build.zig fuzz/README.md
git commit -m "test(fuzz): long-lived scratch scripts over mutated buffers (heap + buffer scratch)"
```

---

### Task 17: `large` group — inputs up to 12 KiB across auto's 4096 cut and SIMD block edges

**Files:**
- Create: `fuzz/check/large.zig`, `fuzz/groups/large.zig`
- Modify: `fuzz/lib.zig`, `build.zig`, `fuzz/root.zig`

**Interfaces:**
- Consumes: `tree.generate`, `print.variant`, `witness.sample`, `literals.nearMiss`, `input_gen.{motif, longInput, max_long_len}`.
- Produces: `run`, `fuzzOne`, `pub var over_4096: u32` (inputs > 4096 B seen — read by health). Bare `backtrack` only when `input.len ≤ 4096` (its documented stack-safe regime; `auto` itself never routes larger inputs to it).

- [ ] **Step 1: Write the failing group file** `fuzz/groups/large.zig`:

```zig
//! Fuzz group: long inputs (up to 12 KiB) with planted witnesses and near-misses at SIMD
//! block edges, around auto's 4096-byte backtrack→Pike-VM switch. See check/large.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: every backend agrees with the Pike VM on long inputs" {
    try std.testing.fuzz({}, lib.check.large.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
```

Wire it (group list, root import, lib `check.large` + test block).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile (missing module).

- [ ] **Step 3: Implement `fuzz/check/large.zig`**

```zig
//! Large-input differential. The small-input groups stop at 64 bytes, but `auto` only
//! switches its NFA engine at 4096 bytes, the DFA arms have per-search reach budgets, and
//! the memmem / Teddy / class-scan loops unroll across 16/32/64-byte blocks. Long inputs
//! built from a repeated motif, with the tree's witness (and a near-miss) planted at block
//! edges and near the end, reach all of that.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const tree = @import("../gen/tree.zig");
const print = @import("../gen/print.zig");
const witness = @import("../gen/witness.zig");
const lits = @import("../gen/literals.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub var over_4096: u32 = 0;
const max_spans = 256;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    const t = tree.generate(smith, tree.pickOpt(smith));
    const popt = common.printOpt(smith, t.opt);
    const pr = print.variant(&t, popt, smith.value(u64)) orelse return;
    var w = try witness.sample(gpa, &t, smith.value(u64));
    var nm: [witness.max_witness]u8 = undefined;
    var mbuf: [64]u8 = undefined;
    const m = input_gen.motif(smith, &mbuf);
    var plants: [3][]const u8 = undefined;
    var np: usize = 0;
    if (w) |*ww| {
        plants[0] = ww.slice();
        plants[1] = lits.nearMiss(ww.slice(), &nm);
        plants[2] = ww.slice();
        np = 3;
    }
    const out = try gpa.alloc(u8, input_gen.max_long_len);
    defer gpa.free(out);
    const l = input_gen.longInput(smith, out, m, plants[0..np]);
    if (l.bytes.len > 4096) over_4096 += 1;
    const case: Case = .{ .check = .large, .pattern = pr.slice(), .input = l.bytes, .opt = popt };
    try known_open.runOrGate(gpa, &case, run);
}

fn summarizeLong(comptime B: type, gpa: std.mem.Allocator, re: *const gex.Compiled(B), input: []const u8) !common.Summary {
    var sc = try re.initScratch(gpa);
    defer sc.deinit(gpa);
    var s: common.Summary = .{};
    s.pushMatch(re.find(&sc, input));
    s.push(@intFromBool(re.isMatch(&sc, input)));
    var it = re.findAll(&sc, input);
    var k: usize = 0;
    while (it.next()) |m| : (k += 1) {
        if (k == max_spans) break;
        s.pushMatch(m);
    }
    return s;
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    var ob = try common.build(gex.backends.pikevm, gpa, case.pattern, case.opt);
    if (ob != .ok) return;
    defer ob.ok.deinit();
    const want = try summarizeLong(gex.backends.pikevm, gpa, &ob.ok, case.input);
    common.noteRun(.large, true);
    const byte_safe = common.byteEnginesSafe(gpa, case.pattern, case.input);
    inline for (common.span_backends) |B| try one(B, gpa, case, byte_safe, &want);
}

fn one(comptime B: type, gpa: std.mem.Allocator, case: *const Case, byte_safe: bool, want: *const common.Summary) anyerror!void {
    if (comptime common.isByteEngine(B)) if (!byte_safe) return common.noteSkipped(.large, B);
    if (B == gex.backends.backtrack and case.input.len > 4096) return common.noteSkipped(.large, B);
    var b = try common.build(B, gpa, case.pattern, case.opt);
    if (b != .ok) return if (b == .skip) common.noteSkipped(.large, B) else error.ValidityDisagreement;
    defer b.ok.deinit();
    common.noteCompared(.large, B);
    const got = try summarizeLong(B, gpa, &b.ok, case.input);
    if (!got.eql(want)) {
        var first: usize = 0;
        while (first < @min(got.n, want.n) and got.v[first] == want.v[first]) first += 1;
        std.debug.print("large ({s}) on /{s}/ over {d} bytes: first difference at summary index {d}: pikevm {any} vs {any}\n", .{
            @typeName(B), case.pattern, case.input.len, first, want.v[first..@min(first + 4, want.n)], got.v[first..@min(first + 4, got.n)],
        });
        return error.LargeDivergence;
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe && zig build fuzz-large -Doptimize=ReleaseSafe`
Expected: PASS / exit 0.

Run: `zig build fuzz-large -Doptimize=ReleaseSafe --fuzz=5K`
Expected: exit 0 or a report → *Open (to triage)*. (Iterations are ~100× costlier here; 5K is the smoke size.)

- [ ] **Step 5: Commit**

```sh
git add fuzz/check/large.zig fuzz/groups/large.zig fuzz/lib.zig fuzz/root.zig build.zig fuzz/README.md
git commit -m "test(fuzz): large-input differential across auto's 4096 cut and SIMD block edges"
```

---

### Task 18: `literals` group — literal sets through literal / Teddy / memmem / prefix sets

**Files:**
- Create: `fuzz/check/literals.zig`, `fuzz/groups/literals.zig`
- Modify: `fuzz/lib.zig`, `build.zig`, `fuzz/root.zig`

**Interfaces:**
- Consumes: `lits.{genSet, nearMiss}`, `input_gen.{motif, longInput}`, `common.{build, buildWith, Summary}`.
- Produces: `run`, `fuzzOne`. Compared against the Pike VM: `literal`, `auto`, `auto{simd=.off}`, `auto{prefilter=false}`, `auto{byte_engine=.disabled}`, `dfa`, `edfa`, `bytepike`, `backtrack` (≤ 4096 B).

- [ ] **Step 1: Write the failing group file** `fuzz/groups/literals.zig`:

```zig
//! Fuzz group: literal sets (shared prefixes, prefix-of-another, duplicates, empty, (?i)
//! with fold traps, 1–12 branches, 0–20 code points) over long inputs with planted members
//! and near-misses — literal/Teddy/memmem/prefix-set paths vs the Pike VM, across the
//! strategy tier. See check/literals.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: literal-set searches agree across backends and strategies" {
    try std.testing.fuzz({}, lib.check.literal_sets.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
```

Wire it (group list, root import, and in `fuzz/lib.zig`'s `check` struct `pub const literal_sets = @import("check/literals.zig");` — named `literal_sets` so it doesn't read as `gen.literals` — plus the file in its test block).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile (missing module).

- [ ] **Step 3: Implement `fuzz/check/literals.zig`**

```zig
//! Literal-set differential. Pure literal alternations are where the literal backend, the
//! Teddy fingerprint scan (slim ≤ 8 / fat 16 buckets), the SIMD memmem, and `auto`'s
//! prefix-set / required-literal prefilters take over — each with its own chunking and
//! verification. Leftmost-FIRST priority among overlapping members (a member that is a
//! prefix of another) and length-changing case folds are the classic ways to get them wrong.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const lits = @import("../gen/literals.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    const set = lits.genSet(smith);
    var pbuf: [2048]u8 = undefined;
    const pattern = set.pattern(&pbuf) orelse return;
    var mbuf: [64]u8 = undefined;
    const m = input_gen.motif(smith, &mbuf);
    var nm: [lits.max_lit_len * 4]u8 = undefined;
    var plants: [3][]const u8 = undefined;
    plants[0] = set.get(smith.index(set.n));
    plants[1] = lits.nearMiss(set.get(smith.index(set.n)), &nm);
    plants[2] = set.get(smith.index(set.n));
    const out = try gpa.alloc(u8, input_gen.max_long_len);
    defer gpa.free(out);
    const l = input_gen.longInput(smith, out, m, &plants);
    const case: Case = .{ .check = .literals, .pattern = pattern, .input = l.bytes };
    try known_open.runOrGate(gpa, &case, run);
}

fn summarizeSet(comptime B: type, gpa: std.mem.Allocator, re: *const gex.Compiled(B), input: []const u8) !common.Summary {
    var sc = try re.initScratch(gpa);
    defer sc.deinit(gpa);
    var s: common.Summary = .{};
    s.pushMatch(re.find(&sc, input));
    var it = re.findAll(&sc, input);
    var k: usize = 0;
    while (it.next()) |x| : (k += 1) {
        if (k == 256) break;
        s.pushMatch(x);
    }
    return s;
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    var ob = try common.build(gex.backends.pikevm, gpa, case.pattern, 0);
    if (ob != .ok) return error.LiteralPatternRejected;
    defer ob.ok.deinit();
    const want = try summarizeSet(gex.backends.pikevm, gpa, &ob.ok, case.input);
    common.noteRun(.literals, true);
    inline for (.{ gex.backends.literal, gex.backends.auto, gex.backends.dfa, gex.backends.edfa, gex.backends.bytepike, gex.backends.backtrack }) |B| {
        try against(B, .{}, gpa, case, &want);
    }
    try against(gex.backends.auto, .{ .strategy = .{ .simd = .off } }, gpa, case, &want);
    try against(gex.backends.auto, .{ .strategy = .{ .prefilter = false } }, gpa, case, &want);
    try against(gex.backends.auto, .{ .strategy = .{ .byte_engine = .disabled } }, gpa, case, &want);
}

fn against(comptime B: type, comptime opts: gex.Options, gpa: std.mem.Allocator, case: *const Case, want: *const common.Summary) anyerror!void {
    if (B == gex.backends.backtrack and case.input.len > 4096) return;
    var b = try common.buildWith(B, opts, gpa, case.pattern);
    if (b != .ok) return common.noteSkipped(.literals, B);
    defer b.ok.deinit();
    common.noteCompared(.literals, B);
    const got = try summarizeSet(B, gpa, &b.ok, case.input);
    if (!got.eql(want)) {
        std.debug.print("literals ({s}, opts {any}) on /{s}/ over {d} bytes:\n  pikevm {any}\n  other  {any}\n", .{
            @typeName(B), opts.strategy, case.pattern, case.input.len, want.v[0..@min(want.n, 12)], got.v[0..@min(got.n, 12)],
        });
        return error.LiteralDivergence;
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe && zig build fuzz-literals -Doptimize=ReleaseSafe`
Expected: PASS / exit 0.

Run: `zig build fuzz-literals -Doptimize=ReleaseSafe --fuzz=5K`
Expected: exit 0 or a report → *Open (to triage)*.

- [ ] **Step 5: Commit**

```sh
git add fuzz/check/literals.zig fuzz/groups/literals.zig fuzz/lib.zig fuzz/root.zig build.zig fuzz/README.md
git commit -m "test(fuzz): literal-set differential across literal/Teddy/memmem and the strategy tier"
```

---

### Task 19: `api` group — split/replace/capturesAll/capturesAt/named groups and hostile templates

**Files:**
- Create: `fuzz/check/api.zig`, `fuzz/groups/api.zig`
- Modify: `fuzz/lib.zig`, `build.zig`, `fuzz/root.zig`

**Interfaces:**
- Consumes: `common.{build, pickPattern, PatBuf, Summary, NONE}`, `input_gen.pickSmall`.
- Produces: `run`, `fuzzOne`, `genTemplate(*Smith, []u8) []const u8`. `case.template` = template; `case.n` = the splitN/replaceN bound; `case.start` = capturesAt start. Capture backends (`backtrack`, `auto`, `onepass`, `bytepike`) compared to the Pike VM; laws: `replace == replaceN(1)`, `replaceAllAlloc == replaceAll(writer)`, `replaceAllWith(<g0>) == replaceAll("<$0>")`, `splitN(n)` yields ≤ n pieces, `groupIndex(groupName(k)) == k`.

- [ ] **Step 1: Write the failing group file** `fuzz/groups/api.zig`:

```zig
//! Fuzz group: the rest of the public surface — split/splitN, replace/replaceN/
//! replaceAllWith, capturesAll/capturesAt, groupIndex/groupName — with hostile `$`
//! templates (`${name}`, bare `$`, `$99`, unterminated `${`). See check/api.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: the whole public search/replace/split surface agrees across capture backends" {
    try std.testing.fuzz({}, lib.check.api.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
```

Wire it (group list, root import, lib `check.api` + test block).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile (missing module).

- [ ] **Step 3: Implement `fuzz/check/api.zig`**

```zig
//! Public-surface check: every search/replace/split entry point, not just find/findAll.
//! Each capture backend must match the Pike VM on all of them, and the entry points must
//! agree with each other (replace == replaceN(1), replaceAllAlloc == replaceAll, …).

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;
const Summary = common.Summary;

/// Templates mixing every `$` form, including the malformed ones the DSL defines as literal.
pub fn genTemplate(smith: *Smith, out: []u8) []const u8 {
    @disableInstrumentation();
    const pieces = [_][]const u8{ "$0", "$1", "$2", "${1}", "${n1}", "${n2}", "${nope}", "$$", "$", "$99", "${", "}", "x", "-", "$a" };
    var len: usize = 0;
    const parts = smith.valueRangeAtMost(u8, 0, 5);
    var i: u8 = 0;
    while (i < parts) : (i += 1) {
        const s = pieces[smith.index(pieces.len)];
        if (len + s.len > out.len) break;
        @memcpy(out[len..][0..s.len], s);
        len += s.len;
    }
    return out[0..len];
}

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pb: common.PatBuf = .{};
    const p = common.pickPattern(smith, &pb) orelse return;
    var ibuf: [input_gen.max_input_len]u8 = undefined;
    const input = input_gen.pickSmall(smith, &ibuf);
    var tbuf: [48]u8 = undefined;
    const template = genTemplate(smith, &tbuf);
    const case: Case = .{ .check = .api, .pattern = p.pattern, .input = input, .opt = p.opt, .template = template, .n = smith.valueRangeAtMost(u8, 0, 5), .start = smith.index(input.len + 1) };
    try known_open.runOrGate(gpa, &case, run);
}

const Wrap = struct {
    fn angle(_: void, caps: gex.Captures, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('<');
        if (caps.groupSlice(0)) |s| try w.writeAll(s);
        try w.writeByte('>');
    }
};

fn hashOut(s: *Summary, out: []const u8) void {
    s.push(out.len);
    s.push(@intCast(std.hash.Wyhash.hash(0, out)));
}

fn apiSummary(comptime B: type, gpa: std.mem.Allocator, re: *const gex.Compiled(B), case: *const Case) !Summary {
    var s: Summary = .{};
    const in = case.input;
    var sc = try re.initScratch(gpa);
    defer sc.deinit(gpa);
    var slots: [96]?usize = undefined;
    const ns = re.slotCount();
    if (ns > slots.len) return error.TooManyGroups;
    const sl = slots[0..ns];

    // split / splitN (pieces as offsets into `in`)
    var sp = re.split(&sc, in);
    var j: usize = 0;
    while (sp.next()) |piece| : (j += 1) {
        if (j == 32) break;
        s.push(@intFromPtr(piece.ptr) - @intFromPtr(in.ptr));
        s.push(piece.len);
    }
    s.push(NONE_MARK);
    var spn = re.splitN(&sc, in, case.n);
    j = 0;
    while (spn.next()) |piece| : (j += 1) {
        if (j >= case.n) return error.SplitNTooManyPieces;
        s.push(@intFromPtr(piece.ptr) - @intFromPtr(in.ptr));
        s.push(piece.len);
    }
    s.push(NONE_MARK);

    // replace family (+ internal agreement laws)
    var a1: std.Io.Writer.Allocating = .init(gpa);
    defer a1.deinit();
    try re.replace(&sc, in, case.template, sl, &a1.writer);
    var a2: std.Io.Writer.Allocating = .init(gpa);
    defer a2.deinit();
    try re.replaceN(&sc, in, case.template, sl, &a2.writer, 1);
    if (!std.mem.eql(u8, a1.written(), a2.written())) return error.ReplaceNotReplaceN1;
    hashOut(&s, a1.written());
    var a3: std.Io.Writer.Allocating = .init(gpa);
    defer a3.deinit();
    try re.replaceN(&sc, in, case.template, sl, &a3.writer, case.n);
    hashOut(&s, a3.written());
    var a4: std.Io.Writer.Allocating = .init(gpa);
    defer a4.deinit();
    try re.replaceAll(&sc, in, case.template, sl, &a4.writer);
    const alloc_out = try re.replaceAllAlloc(gpa, &sc, in, case.template, sl);
    defer gpa.free(alloc_out);
    if (!std.mem.eql(u8, a4.written(), alloc_out)) return error.ReplaceAllAllocDiffers;
    hashOut(&s, alloc_out);
    var a5: std.Io.Writer.Allocating = .init(gpa);
    defer a5.deinit();
    try re.replaceAllWith(&sc, in, sl, &a5.writer, {}, Wrap.angle);
    const angle_out = try re.replaceAllAlloc(gpa, &sc, in, "<$0>", sl);
    defer gpa.free(angle_out);
    if (!std.mem.eql(u8, a5.written(), angle_out)) return error.ReplaceAllWithDiffers;
    hashOut(&s, angle_out);

    // capturesAll (≤ 16 matches) and capturesAt
    var ca = re.capturesAll(&sc, sl, in);
    j = 0;
    while (ca.next()) |c| : (j += 1) {
        if (j == 16) break;
        for (c.slots) |x| s.push(x orelse common.NONE);
    }
    s.push(NONE_MARK);
    if (re.capturesAt(&sc, sl, in, .{ .start = @min(case.start, in.len) })) |_| {
        for (sl) |x| s.push(x orelse common.NONE);
    } else s.push(common.NONE);

    // names
    var g: usize = 1;
    while (g <= re.captureCount()) : (g += 1) {
        if (re.groupName(g)) |name| {
            if (re.groupIndex(name) != g) return error.GroupNameIndexMismatch;
            s.push(g);
        }
    }
    return s;
}

const NONE_MARK = std.math.maxInt(usize) - 1;

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    var ob = try common.build(gex.backends.pikevm, gpa, case.pattern, case.opt);
    if (ob != .ok) return;
    defer ob.ok.deinit();
    const want = apiSummary(gex.backends.pikevm, gpa, &ob.ok, case) catch |e| switch (e) {
        error.TooManyGroups => return,
        else => {
            std.debug.print("api (pikevm) on /{s}/ tmpl \"{s}\": law {s}\n", .{ case.pattern, case.template, @errorName(e) });
            return e;
        },
    };
    common.noteRun(.api, true);
    const byte_safe = common.byteEnginesSafe(gpa, case.pattern, case.input);
    inline for (common.capture_backends) |B| try against(B, gpa, case, byte_safe, &want);
}

fn against(comptime B: type, gpa: std.mem.Allocator, case: *const Case, byte_safe: bool, want: *const Summary) anyerror!void {
    if (comptime common.isByteEngine(B)) if (!byte_safe) return common.noteSkipped(.api, B);
    var b = try common.build(B, gpa, case.pattern, case.opt);
    if (b != .ok) return if (b == .skip) common.noteSkipped(.api, B) else error.ValidityDisagreement;
    defer b.ok.deinit();
    common.noteCompared(.api, B);
    const got = apiSummary(B, gpa, &b.ok, case) catch |e| {
        std.debug.print("api ({s}) on /{s}/ tmpl \"{s}\": law {s}\n", .{ @typeName(B), case.pattern, case.template, @errorName(e) });
        return e;
    };
    if (!got.eql(want)) {
        std.debug.print("api ({s}) on /{s}/ tmpl \"{s}\" n={d} over \"{s}\":\n  pikevm {any}\n  other  {any}\n", .{ @typeName(B), case.pattern, case.template, case.n, case.input, want.v[0..want.n], got.v[0..got.n] });
        return error.ApiDivergence;
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe && zig build fuzz-api -Doptimize=ReleaseSafe`
Expected: PASS / exit 0.

Run: `zig build fuzz-api -Doptimize=ReleaseSafe --fuzz=20K`
Expected: exit 0 or a report → *Open (to triage)*.

- [ ] **Step 5: Commit**

```sh
git add fuzz/check/api.zig fuzz/groups/api.zig fuzz/lib.zig fuzz/root.zig build.zig fuzz/README.md
git commit -m "test(fuzz): public search/replace/split surface + hostile templates"
```

---

### Task 20: `oom` group — every allocation failure surfaces as `OutOfMemory`

**Files:**
- Create: `fuzz/check/oom.zig`, `fuzz/groups/oom.zig`
- Modify: `fuzz/lib.zig`, `build.zig`, `fuzz/root.zig`

**Interfaces:**
- Consumes: `common.{compileVariant, pickPattern, PatBuf}`, `std.testing.checkAllAllocationFailures`.
- Produces: `run`, `fuzzOne`. Failure classes reported by `checkAllAllocationFailures`: `error.SwallowedOutOfMemoryError` (an induced failure was absorbed — e.g. mapped to `Unsupported`/`PatternTooComplex` or a silent fallback), `error.NondeterministicMemoryUsage`, leaks (printed with the failing index).

- [ ] **Step 1: Write the failing group file** `fuzz/groups/oom.zig`:

```zig
//! Fuzz group: allocation-failure injection over compile → Scratch.init → find/count →
//! replaceAllAlloc, on every backend. See check/oom.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: every allocation failure surfaces as OutOfMemory, never a leak or a swallow" {
    try std.testing.fuzz({}, lib.check.oom.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
```

Wire it (group list, root import, lib `check.oom` + test block).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile (missing module).

- [ ] **Step 3: Implement `fuzz/check/oom.zig`**

```zig
//! Allocation-failure injection. `std.testing.checkAllAllocationFailures` runs the scenario
//! once to count allocations, then once per allocation with THAT allocation failing. Each
//! induced failure must come back as `error.OutOfMemory` with nothing leaked: a backend that
//! maps OOM to another error or silently degrades is reported as a swallowed failure.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pb: common.PatBuf = .{};
    const p = common.pickPattern(smith, &pb) orelse return;
    if (p.pattern.len > 48) return; // the scenario re-runs once per allocation
    var ibuf: [32]u8 = undefined;
    const input = input_gen.pickSmall(smith, &ibuf);
    const case: Case = .{ .check = .oom, .pattern = p.pattern, .input = input, .opt = p.opt };
    try known_open.runOrGate(gpa, &case, run);
}

fn Scenario(comptime B: type) type {
    return struct {
        fn f(gpa: std.mem.Allocator, pattern: []const u8, input: []const u8, opt: u8) !void {
            var diag: gex.Diagnostic = .{};
            var re = common.compileVariant(B, gpa, pattern, &diag, opt) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return, // invalid / unsupported: not an allocation outcome
            };
            defer re.deinit();
            var sc = try re.initScratch(gpa);
            defer sc.deinit(gpa);
            _ = re.find(&sc, input);
            _ = re.count(&sc, input);
            if (comptime B.caps.captures) {
                var slots: [96]?usize = undefined;
                const ns = re.slotCount();
                if (ns > slots.len) return;
                const out = try re.replaceAllAlloc(gpa, &sc, input, "<$0>", slots[0..ns]);
                gpa.free(out);
            }
        }
    };
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    common.noteRun(.oom, true);
    inline for (common.all_backends) |B| {
        std.testing.checkAllAllocationFailures(gpa, Scenario(B).f, .{ case.pattern, case.input, case.opt }) catch |e| {
            std.debug.print("oom ({s}) on /{s}/: {s}\n", .{ @typeName(B), case.pattern, @errorName(e) });
            return e;
        };
        common.noteCompared(.oom, B);
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe && zig build fuzz-oom -Doptimize=ReleaseSafe`
Expected: PASS / exit 0, or a report on the seed replay. A `SwallowedOutOfMemoryError` is a finding (possibly a spec
question: is a silent fallback on OOM acceptable?) — record it under *Open (to triage)*; if it fires on the seed
replay, add the pattern to a temporary skip list at the top of `run` with a `// FUZZ-OPEN:` comment so the smoke
stays green, and let Task 27 convert it into a proper gate.

- [ ] **Step 5: Commit**

```sh
git add fuzz/check/oom.zig fuzz/groups/oom.zig fuzz/lib.zig fuzz/root.zig build.zig fuzz/README.md
git commit -m "test(fuzz): allocation-failure injection on every backend"
```

---

### Task 21: `comptime_parity` group — ro_data programs answer like runtime ones

**Files:**
- Create: `fuzz/check/comptime_parity.zig`, `fuzz/groups/comptime_parity.zig`
- Modify: `fuzz/lib.zig`, `build.zig`, `fuzz/root.zig`

**Interfaces:**
- Consumes: `gex.compileComptimeWith`, `common.{build, summarize}`, `input_gen.pickSmall`.
- Produces: `table: [24][]const u8`, `run`, `fuzzOne` (`case.n` = table index; `case.pattern` = `table[n]` for display).

- [ ] **Step 1: Write the failing group file** `fuzz/groups/comptime_parity.zig`:

```zig
//! Fuzz group: comptime/runtime parity — a fixed pattern table compiled at COMPTIME must
//! answer exactly like the runtime compile on fuzzed inputs. See check/comptime_parity.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: comptime-compiled programs agree with runtime-compiled ones" {
    try std.testing.fuzz({}, lib.check.comptime_parity.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
```

Wire it (group list, root import, lib `check.comptime_parity` + test block).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile (missing module).

- [ ] **Step 3: Implement `fuzz/check/comptime_parity.zig`**

```zig
//! Comptime parity. Comptime and runtime share the front end but build storage differently
//! (ro_data vs heap), and the comptime path carves buffers with plain slicing only. A fixed
//! table of patterns (fuzz seeds + conformance shapes) is compiled at comptime for three
//! backends; on fuzzed inputs each must equal the runtime compile. A finite test also runs
//! the `*Comptime` matchers in the const evaluator.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub const table = [_][]const u8{
    "abc",        "a|ab",           "(a(b)c)*",      "[a-c]{2,4}",        "\\d+\\w*\\s?", "(?:ab)+",
    "(?i:ABC)",   "^a.c$",          "a{0,6}b{2}",    "\\b\\w+\\b",        "(?i)aB(?-i)c", "[^a-c\\d]+",
    "(a|)*b",     "(?P<x>.)+",      "(?:|.)+",       "(|a)*",             "(?:a?b??)+",   "\\p{L}+",
    "(?i:stra\xC3\x9fe)", "[\xCE\xB1-\xCF\x89]+", "(?m)^a$", "a$|b",      "\\Bcat\\B",    "cat|dog|fish",
};
const backends = .{ gex.backends.auto, gex.backends.pikevm, gex.backends.backtrack };

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    const n = smith.index(table.len);
    var ibuf: [input_gen.max_input_len]u8 = undefined;
    const input = input_gen.pickSmall(smith, &ibuf);
    const case: Case = .{ .check = .comptime_parity, .pattern = table[n], .input = input, .n = n };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    if (case.n >= table.len) return error.BadCase;
    common.noteRun(.comptime_parity, true);
    switch (case.n) {
        inline 0...table.len - 1 => |i| inline for (backends) |B| try parity(B, i, gpa, case.input),
        else => unreachable,
    }
}

fn parity(comptime B: type, comptime i: usize, gpa: std.mem.Allocator, input: []const u8) anyerror!void {
    const ct = comptime gex.compileComptimeWith(B, table[i], .{});
    var rt = try common.build(B, gpa, table[i], 0);
    if (rt != .ok) return error.RuntimeRejectsComptimePattern;
    defer rt.ok.deinit();
    const want = try common.summarize(B, gpa, &rt.ok, input);
    const got = try common.summarize(B, gpa, &ct, input);
    if (!got.eql(&want)) {
        std.debug.print("comptime parity ({s}) /{s}/ over \"{s}\":\n  runtime  {any}\n  comptime {any}\n", .{ @typeName(B), table[i], input, want.v[0..want.n], got.v[0..got.n] });
        return error.ComptimeRuntimeDivergence;
    }
    common.noteCompared(.comptime_parity, B);
}

fn matchEq(a: ?gex.Match, b: ?gex.Match) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.start == b.?.start and a.?.end == b.?.end;
}

test "comptime matchers (const-evaluated) agree with runtime" {
    const gpa = std.testing.allocator;
    inline for (.{ "a|ab", "(a)(b)?", "\\bcat\\b", "(?:|.)+" }) |p| {
        const re = comptime gex.compileComptimeWith(gex.backends.auto, p, .{});
        var rt = try common.build(gex.backends.auto, gpa, p, 0);
        defer rt.ok.deinit();
        var sc = try rt.ok.initScratch(gpa);
        defer sc.deinit(gpa);
        inline for (.{ "ab", "a cat!", "c", "xab ab" }) |in| {
            const cm = comptime re.findComptime(in);
            const cc = comptime re.countComptime(in);
            const ci = comptime re.isMatchComptime(in);
            try std.testing.expect(matchEq(cm, rt.ok.find(&sc, in)));
            try std.testing.expectEqual(cc, rt.ok.count(&sc, in));
            try std.testing.expectEqual(ci, rt.ok.isMatch(&sc, in));
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes, and time it**

Run: `time zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS. Note the wall time. If this task alone added more than ~15 s of compile time to `test-fuzz`, cut
`table` to its first 12 rows (keep `(?:|.)+`, `(|a)*`, `(?:a?b??)+` — move them up) and re-time.

Run: `zig build fuzz-comptime_parity -Doptimize=ReleaseSafe --fuzz=20K`
Expected: exit 0 or a report → *Open (to triage)*.

- [ ] **Step 5: Commit**

```sh
git add fuzz/check/comptime_parity.zig fuzz/groups/comptime_parity.zig fuzz/lib.zig fuzz/root.zig build.zig fuzz/README.md
git commit -m "test(fuzz): comptime/runtime parity group + const-evaluated matcher check"
```

---

### Task 22: `complexity` group — counter-based linear-work checks on generated patterns

**Files:**
- Create: `fuzz/check/complexity.zig`, `fuzz/groups/complexity.zig`
- Modify: `fuzz/lib.zig`, `build.zig`, `fuzz/root.zig`

**Interfaces:**
- Consumes: `backtrack.Scratch.steps` (via `sc.inner.steps` on a `Compiled(backtrack)` scratch), `auto.Scratch.confirm_probes` (via `sc.inner.confirm_probes`), `gex.parse`/`gex.buildHir` (`analysis.anchored_end`).
- Produces: `run`, `fuzzOne`. `case.input` = motif; `case.n` = base repetitions; `case.seed` low byte = the completion-breaking tail byte.
- Rules: at n, 2n, 4n repetitions (≤ 4096 bytes — the backtracker's regime under `auto`), when `steps(n) ≥ 512`: `4·steps(2n) ≤ 9·steps(n) + slack` and `4·steps(4n) ≤ 9·steps(2n) + slack` (≤ 2.25× per doubling), `slack = 256 + steps(n)/4`. For an `anchored_end` pattern compiled with a non-multiline variant (`opt != 4`): `auto`'s `confirm_probes == 0` on the 4n input.

- [ ] **Step 1: Write the failing group file** `fuzz/groups/complexity.zig`:

```zig
//! Fuzz group: deterministic complexity — the backtracker's work counter must scale
//! linearly on generated patterns; auto must do zero per-occurrence confirms on
//! end-anchored programs. See check/complexity.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: matching work stays linear (counter-based, no timers)" {
    try std.testing.fuzz({}, lib.check.complexity.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
```

Wire it (group list, root import, lib `check.complexity` + test block).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile (missing module).

- [ ] **Step 3: Implement `fuzz/check/complexity.zig`**

```zig
//! Complexity, deterministically. `redos.zig` pins the ReDoS-immunity claim on hand-picked
//! catastrophic patterns; this extends it to GENERATED patterns using the same timer-free
//! observables: the bounded backtracker's `(pc, sp)` memo probe count must grow ≤ 2.25× per
//! input doubling, and `auto` must never do per-occurrence confirms on an end-anchored
//! program (its documented anti-Θ(n²) contract; `prone` programs are classified inside
//! `auto` and are not externally observable, so only `anchored_end` is checked).

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const input_gen = @import("../gen/input.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var pb: common.PatBuf = .{};
    const p = common.pickPattern(smith, &pb) orelse return;
    var mbuf: [32]u8 = undefined;
    const m = input_gen.motif(smith, &mbuf);
    const case: Case = .{
        .check = .complexity,
        .pattern = p.pattern,
        .input = m,
        .opt = p.opt,
        .n = smith.valueRangeAtMost(u8, 8, 64),
        .seed = smith.value(u8),
    };
    try known_open.runOrGate(gpa, &case, run);
}

fn repeated(gpa: std.mem.Allocator, motif: []const u8, reps: usize, tail: u8) ![]u8 {
    const out = try gpa.alloc(u8, motif.len * reps + 1);
    for (0..reps) |i| @memcpy(out[i * motif.len ..][0..motif.len], motif);
    out[out.len - 1] = tail;
    return out;
}

fn anchoredEnd(gpa: std.mem.Allocator, pattern: []const u8) bool {
    var diag: gex.Diagnostic = .{};
    const ast = gex.parse(gpa, pattern, &diag) catch return false;
    defer ast.deinit(gpa);
    const h = gex.buildHir(gpa, ast, .{}) catch return false;
    defer gex.freeHir(gpa, h);
    return h.analysis.anchored_end;
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    if (case.input.len == 0 or case.n == 0) return;
    const tail: u8 = @truncate(case.seed);
    var bb = try common.build(gex.backends.backtrack, gpa, case.pattern, case.opt);
    if (bb != .ok) return;
    defer bb.ok.deinit();
    common.noteRun(.complexity, true);

    var steps: [3]u64 = undefined;
    for ([_]usize{ 1, 2, 4 }, 0..) |mult, i| {
        const in = try repeated(gpa, case.input, case.n * mult, tail);
        defer gpa.free(in);
        if (in.len > 4096) return;
        var sc = try bb.ok.initScratch(gpa);
        defer sc.deinit(gpa);
        _ = bb.ok.find(&sc, in);
        steps[i] = sc.inner.steps;
    }
    common.noteCompared(.complexity, gex.backends.backtrack);
    if (steps[0] >= 512) {
        const slack = 256 + steps[0] / 4;
        if (4 * steps[1] > 9 * steps[0] + slack or 4 * steps[2] > 9 * steps[1] + slack) {
            std.debug.print("complexity: /{s}/ backtrack steps {d} → {d} → {d} over n/2n/4n (motif \"{s}\" ×{d}, tail 0x{X:0>2})\n", .{ case.pattern, steps[0], steps[1], steps[2], case.input, case.n, tail });
            return error.SuperLinearWork;
        }
    }

    if (case.opt != 4 and anchoredEnd(gpa, case.pattern)) {
        var ab = try common.build(gex.backends.auto, gpa, case.pattern, case.opt);
        if (ab != .ok) return;
        defer ab.ok.deinit();
        const in = try repeated(gpa, case.input, case.n * 4, tail);
        defer gpa.free(in);
        var sc = try ab.ok.initScratch(gpa);
        defer sc.deinit(gpa);
        _ = ab.ok.find(&sc, in);
        common.noteCompared(.complexity, gex.backends.auto);
        if (sc.inner.confirm_probes != 0) {
            std.debug.print("complexity: /{s}/ is end-anchored but auto did {d} per-occurrence confirms\n", .{ case.pattern, sc.inner.confirm_probes });
            return error.PrefilterConfirmsOnEndAnchored;
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe && zig build fuzz-complexity -Doptimize=ReleaseSafe`
Expected: PASS / exit 0.

Run: `zig build fuzz-complexity -Doptimize=ReleaseSafe --fuzz=20K`
Expected: exit 0 or a report → *Open (to triage)*.

- [ ] **Step 5: Commit**

```sh
git add fuzz/check/complexity.zig fuzz/groups/complexity.zig fuzz/lib.zig fuzz/root.zig build.zig fuzz/README.md
git commit -m "test(fuzz): counter-based linear-work checks on generated patterns"
```

---

### Task 23: `utf8class` group — class membership against ground truth at UTF-8 boundaries

**Files:**
- Create: `fuzz/check/utf8class.zig`, `fuzz/groups/utf8class.zig`
- Modify: `fuzz/lib.zig`, `build.zig`, `fuzz/root.zig`

**Interfaces:**
- Consumes: `ref.uni.decode`, `tree.encodeUtf8`, `input_gen.evilInput`.
- Produces: `boundaries`, `Class{ ranges: [3][2]u21, n, negated }`, `formatClass(Class, []u8) []const u8` (fixed format `[^?(\x{H}-\x{H})+]`), `parseClass([]const u8) ?Class`, `expected(Class, input) ?[2]usize` (leftmost VALID scalar whose membership matches), `run`, `fuzzOne`.

- [ ] **Step 1: Write the failing test + group file**

`fuzz/groups/utf8class.zig`:

```zig
//! Fuzz group: code-point classes with endpoints on UTF-8 length boundaries, searched over
//! code points around those boundaries and hostile bytes; every backend (byte DFAs
//! included) is checked against the class's own ground truth. See check/utf8class.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: class membership at UTF-8 boundaries matches ground truth on every backend" {
    try std.testing.fuzz({}, lib.check.utf8class.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
```

Wire it (group list, root import, lib `check.utf8class` + test block). In `fuzz/check/utf8class.zig` start with the imports and this unit test:

```zig
test "formatClass / parseClass / expected" {
    var buf: [128]u8 = undefined;
    const c: Class = .{ .ranges = .{ .{ 0x80, 0x7FF }, .{ 0x10000, 0x10FFFF }, .{ 0, 0 } }, .n = 2, .negated = false };
    const s = formatClass(c, &buf);
    try std.testing.expectEqualStrings("[\\x{80}-\\x{7FF}\\x{10000}-\\x{10FFFF}]", s);
    const back = parseClass(s).?;
    try std.testing.expectEqual(c.n, back.n);
    try std.testing.expectEqual(c.ranges[1], back.ranges[1]);
    try std.testing.expectEqual(@as(?[2]usize, .{ 2, 4 }), expected(c, "a\xFF\xC3\xA9"));
    try std.testing.expectEqual(@as(?[2]usize, null), expected(c, "a\xED\xA0\x80")); // a surrogate encoding is not a member
    const neg: Class = .{ .ranges = c.ranges, .n = 2, .negated = true };
    try std.testing.expectEqual(@as(?[2]usize, .{ 0, 1 }), expected(neg, "a\xC3\xA9"));
    try std.testing.expectEqual(@as(?[2]usize, null), expected(neg, "\xFF")); // dead-on-invalid even when negated
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile — `use of undeclared identifier 'Class'`.

- [ ] **Step 3: Implement** (above the test)

```zig
//! UTF-8 class boundaries against ground truth. Byte engines lower code-point ranges into
//! UTF-8 byte automata — the classic place for off-by-one bugs at U+7F/80, 7FF/800,
//! D7FF/E000 (the surrogate gap), FFFF/10000 and 10FFFF — and every engine must treat
//! malformed bytes (overlong, surrogate, > U+10FFFF, truncated) as matching nothing, even
//! for a NEGATED class. The expected answer comes from the ranges themselves.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const tree = @import("../gen/tree.zig");
const input_gen = @import("../gen/input.zig");
const uni = @import("../ref/uni.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub const boundaries = [_]u21{ 0, 0x7F, 0x80, 0x3FF, 0x400, 0x7FF, 0x800, 0xFFF, 0x1000, 0xD7FF, 0xE000, 0xFFFD, 0xFFFF, 0x10000, 0x3FFFF, 0x40000, 0x10FFFF };

pub const Class = struct { ranges: [3][2]u21 = undefined, n: usize = 0, negated: bool = false };

fn nearBoundary(smith: *Smith) u21 {
    const b: i64 = boundaries[smith.index(boundaries.len)];
    var c: i64 = b + @as(i64, smith.valueRangeAtMost(u8, 0, 4)) - 2;
    c = std.math.clamp(c, 0, 0x10FFFF);
    if (c >= 0xD800 and c <= 0xDFFF) c = if (c < 0xDC00) 0xD7FF else 0xE000;
    return @intCast(c);
}

pub fn formatClass(c: Class, out: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.writeByte('[') catch unreachable;
    if (c.negated) w.writeByte('^') catch unreachable;
    for (c.ranges[0..c.n]) |r| w.print("\\x{{{X}}}-\\x{{{X}}}", .{ r[0], r[1] }) catch unreachable;
    w.writeByte(']') catch unreachable;
    return w.buffered();
}

pub fn parseClass(s: []const u8) ?Class {
    var c: Class = .{};
    var i: usize = 0;
    if (i >= s.len or s[i] != '[') return null;
    i += 1;
    if (i < s.len and s[i] == '^') {
        c.negated = true;
        i += 1;
    }
    while (i < s.len and s[i] != ']') {
        if (c.n == c.ranges.len) return null;
        var pair: [2]u21 = undefined;
        for (&pair, 0..) |*v, k| {
            if (!std.mem.startsWith(u8, s[i..], "\\x{")) return null;
            i += 3;
            const close = std.mem.indexOfScalarPos(u8, s, i, '}') orelse return null;
            v.* = std.fmt.parseInt(u21, s[i..close], 16) catch return null;
            i = close + 1;
            if (k == 0) {
                if (i >= s.len or s[i] != '-') return null;
                i += 1;
            }
        }
        c.ranges[c.n] = pair;
        c.n += 1;
    }
    if (i >= s.len or c.n == 0) return null;
    return c;
}

fn member(c: Class, cp: u21) bool {
    var in = false;
    for (c.ranges[0..c.n]) |r| {
        if (cp >= r[0] and cp <= r[1]) in = true;
    }
    return in != c.negated;
}

/// Leftmost valid scalar that is a member; malformed bytes are skipped one at a time.
pub fn expected(c: Class, input: []const u8) ?[2]usize {
    var i: usize = 0;
    while (i < input.len) {
        const d = uni.decode(input, i);
        if (d.valid and member(c, d.cp)) return .{ i, i + d.len };
        i += d.len;
    }
    return null;
}

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var c: Class = .{ .negated = smith.valueRangeAtMost(u8, 0, 2) == 0 };
    c.n = smith.valueRangeAtMost(u8, 1, 3);
    for (c.ranges[0..c.n]) |*r| {
        const a = nearBoundary(smith);
        const b = nearBoundary(smith);
        r.* = .{ @min(a, b), @max(a, b) };
    }
    var pbuf: [128]u8 = undefined;
    const pattern = formatClass(c, &pbuf);
    var ibuf: [96]u8 = undefined;
    var len: usize = 0;
    if (smith.valueRangeAtMost(u8, 0, 1) == 0) {
        len = input_gen.evilInput(smith, ibuf[0..48]).len;
    }
    const scalars = smith.valueRangeAtMost(u8, 1, 6);
    var k: u8 = 0;
    while (k < scalars and len + 4 <= ibuf.len) : (k += 1) {
        var b: [4]u8 = undefined;
        const n = tree.encodeUtf8(nearBoundary(smith), &b);
        @memcpy(ibuf[len..][0..n], b[0..n]);
        len += n;
    }
    const case: Case = .{ .check = .utf8class, .pattern = pattern, .input = ibuf[0..len] };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    const c = parseClass(case.pattern) orelse return error.BadCase;
    const want = expected(c, case.input);
    common.noteRun(.utf8class, true);
    inline for (common.all_backends) |B| try one(B, gpa, case, want);
}

fn one(comptime B: type, gpa: std.mem.Allocator, case: *const Case, want: ?[2]usize) anyerror!void {
    var b = try common.build(B, gpa, case.pattern, 0);
    if (b != .ok) return if (b == .skip) common.noteSkipped(.utf8class, B) else error.ClassRejected;
    defer b.ok.deinit();
    common.noteCompared(.utf8class, B);
    var sc = try b.ok.initScratch(gpa);
    defer sc.deinit(gpa);
    const m = b.ok.find(&sc, case.input);
    const got: ?[2]usize = if (m) |x| .{ x.start, x.end } else null;
    if (!common.spanEq(want, got)) {
        std.debug.print("utf8class ({s}) {s} over {x}: ground truth {?any}, got {?any}\n", .{ @typeName(B), case.pattern, case.input, want, got });
        return error.ClassMembership;
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe && zig build fuzz-utf8class -Doptimize=ReleaseSafe`
Expected: PASS / exit 0.

Run: `zig build fuzz-utf8class -Doptimize=ReleaseSafe --fuzz=50K`
Expected: exit 0 or a report → *Open (to triage)*.

- [ ] **Step 5: Commit**

```sh
git add fuzz/check/utf8class.zig fuzz/groups/utf8class.zig fuzz/lib.zig fuzz/root.zig build.zig fuzz/README.md
git commit -m "test(fuzz): UTF-8 boundary class membership against ground truth"
```

---

### Task 24: Scanner hardening (mutations, diagnostic ranges) and the `\X` grapheme oracle

**Files:**
- Create: `fuzz/check/scanner.zig`, `fuzz/check/grapheme.zig`
- Modify: `fuzz/groups/scanner.zig`, `fuzz/groups/unicode.zig`, `fuzz/lib.zig`

**Interfaces:**
- Consumes: `pattern_gen.gen`, `gex.parseWith`, `gex.Diagnostic.{code, span, isOk, faultySlice}`, `ezi_code.unicode.segmentation.iterator`.
- Produces (`scanner`): `edit_chars`, `mutate(*Smith, base, out) []const u8`, `run`, `fuzzOne` (`case.n` = repetition limit, 0 = default). Laws: reject ⇒ `diag.code != .none`, `span.start ≤ span.end ≤ pattern.len`, `faultySlice` returns; accept ⇒ `diag.isOk()`, and (default limit) no backend returns `.invalid`.
- Produces (`grapheme`): `cluster_pool`, `run`, `fuzzOne`. Law (valid UTF-8, `backtrack` and `auto`): `findAll(\X)` spans tile the input exactly along `segmentation.iterator` clusters; `find(\X+)` is `[0, len]` for non-empty input.

- [ ] **Step 1: Add the failing tests to the existing groups**

Append to `fuzz/groups/scanner.zig` (before its `test { refAllDecls }`):

```zig
test "fuzz: mutated patterns — located diagnostics on reject, agreement on accept" {
    try std.testing.fuzz({}, @import("fuzz_lib").check.scanner.fuzzOne, .{ .corpus = &h.seed_corpus });
}
```

Append to `fuzz/groups/unicode.zig`:

```zig
test "fuzz: \\X tiles valid UTF-8 along ezi_code's grapheme clusters" {
    try std.testing.fuzz({}, @import("fuzz_lib").check.grapheme.fuzzOne, .{ .corpus = &@import("fuzz_lib").check.common.generic_corpus });
}
```

Add `pub const scanner = @import("check/scanner.zig");` and `pub const grapheme = @import("check/grapheme.zig");` to the lib `check` struct and both files to its test block.

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile (missing modules).

- [ ] **Step 3: Implement `fuzz/check/scanner.zig`**

```zig
//! Scanner hardening. Random bytes mostly die at the first character; mutating a VALID
//! generated pattern by 1–3 edits from a metacharacter-heavy set drives the parser deep
//! into error recovery instead. A rejection must carry a real code and a span inside the
//! pattern; an acceptance must leave the diagnostic clean, and (at default limits) no
//! backend may then call the pattern invalid.

const std = @import("std");
const gex = @import("ezi_gex");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const pattern_gen = @import("../gen/pattern.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub const edit_chars = "()[]{}|?*+\\^$.-:<>=!#PpxuQEkbBdDsSwWzZAX0123456789,aZ \n\t";

pub fn mutate(smith: *Smith, base: []const u8, out: []u8) []const u8 {
    @disableInstrumentation();
    var len = @min(base.len, out.len);
    @memcpy(out[0..len], base[0..len]);
    const edits = smith.valueRangeAtMost(u8, 1, 3);
    var e: u8 = 0;
    while (e < edits) : (e += 1) {
        const at = smith.index(len + 1);
        const c = edit_chars[smith.index(edit_chars.len)];
        switch (smith.valueRangeAtMost(u8, 0, 2)) {
            0 => if (len < out.len) { // insert
                std.mem.copyBackwards(u8, out[at + 1 .. len + 1], out[at..len]);
                out[at] = c;
                len += 1;
            },
            1 => if (at < len) { // delete
                std.mem.copyForwards(u8, out[at .. len - 1], out[at + 1 .. len]);
                len -= 1;
            },
            else => if (at < len) {
                out[at] = c; // replace
            },
        }
    }
    return out[0..len];
}

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var p = pattern_gen.gen(smith);
    var buf: [pattern_gen.max_pattern_len + 8]u8 = undefined;
    const m = mutate(smith, p.slice(), &buf);
    const limit: usize = if (smith.valueRangeAtMost(u8, 0, 3) == 0) smith.valueRangeAtMost(u16, 1, 2000) else 0;
    const case: Case = .{ .check = .scanner, .pattern = m, .n = limit };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    common.noteRun(.scanner, true);
    var diag: gex.Diagnostic = .{};
    const limit: u32 = if (case.n == 0) gex.default_max_repetition else @intCast(@min(case.n, std.math.maxInt(u32)));
    const ast = gex.parseWith(gpa, case.pattern, &diag, .{ .max_repetition = limit }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.InvalidPattern => {
            if (diag.code == .none) return error.RejectWithoutCode;
            if (diag.span.start > diag.span.end or diag.span.end > case.pattern.len) {
                std.debug.print("scanner: /{s}/ {s} span {d}..{d} outside pattern (len {d})\n", .{ case.pattern, @tagName(diag.code), diag.span.start, diag.span.end, case.pattern.len });
                return error.DiagnosticOutOfRange;
            }
            _ = diag.faultySlice(case.pattern);
            return;
        },
    };
    ast.deinit(gpa);
    if (!diag.isOk()) return error.AcceptWithDiagnostic;
    if (case.n != 0) return;
    inline for (common.all_backends) |B| {
        var b = try common.build(B, gpa, case.pattern, 0);
        switch (b) {
            .ok => |*re| re.deinit(),
            .skip => {},
            .invalid => {
                std.debug.print("scanner: /{s}/ parses but {s} calls it InvalidPattern\n", .{ case.pattern, @typeName(B) });
                return error.BackendRejectsParsedPattern;
            },
        }
    }
}
```

- [ ] **Step 4: Implement `fuzz/check/grapheme.zig`**

```zig
//! `\X` against an independent oracle. `\X` runs only on the backtracker (and `auto`, which
//! routes it there), so it has no differential partner inside ezi_gex — until now it was
//! fuzzed for "no crash" only. ezi_code's UAX #29 segmenter is the oracle: over valid
//! UTF-8, `findAll(\X)` must tile the input into exactly its clusters.

const std = @import("std");
const gex = @import("ezi_gex");
const ez = @import("ezi_code");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub const cluster_pool = [_][]const u8{
    "a", "e\u{301}", "\u{1F1FA}\u{1F1F8}", "\u{1F468}\u{200D}\u{1F469}", "\r\n", "\u{1100}\u{1161}\u{11A8}",
    "\n", "\u{0915}\u{094D}\u{0937}", "\u{1F44D}\u{1F3FD}", " ", "\u{0301}", "\u{AC00}", "\r",
};

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    var buf: [160]u8 = undefined;
    var len: usize = 0;
    const n = smith.valueRangeAtMost(u8, 0, 10);
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const p = cluster_pool[smith.index(cluster_pool.len)];
        if (len + p.len > buf.len) break;
        @memcpy(buf[len..][0..p.len], p);
        len += p.len;
    }
    const case: Case = .{ .check = .grapheme, .pattern = "\\X", .input = buf[0..len] };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    if (!common.isValidUtf8(case.input)) return error.BadCase;
    common.noteRun(.grapheme, true);
    inline for (.{ gex.backends.backtrack, gex.backends.auto }) |B| {
        var b = try common.build(B, gpa, "\\X", 0);
        if (b != .ok) return error.GraphemeUnsupported;
        defer b.ok.deinit();
        var sc = try b.ok.initScratch(gpa);
        defer sc.deinit(gpa);
        var it = b.ok.findAll(&sc, case.input);
        var seg = ez.unicode.segmentation.iterator(case.input);
        var pos: usize = 0;
        while (seg.next()) |cluster| {
            const m = it.next() orelse {
                std.debug.print("grapheme ({s}): \\X stopped at {d}, expected cluster \"{s}\"\n", .{ @typeName(B), pos, cluster });
                return error.GraphemeTiling;
            };
            if (m.start != pos or m.end != pos + cluster.len) {
                std.debug.print("grapheme ({s}): \\X [{d},{d}] vs cluster [{d},{d}] over {x}\n", .{ @typeName(B), m.start, m.end, pos, pos + cluster.len, case.input });
                return error.GraphemeTiling;
            }
            pos += cluster.len;
        }
        if (it.next()) |m| if (!m.isEmpty()) {
            std.debug.print("grapheme ({s}): extra \\X match [{d},{d}] after the last cluster\n", .{ @typeName(B), m.start, m.end });
            return error.GraphemeTiling;
        };
        common.noteCompared(.grapheme, B);
    }
    if (case.input.len > 0) {
        var b = try common.build(gex.backends.auto, gpa, "\\X+", 0);
        defer if (b == .ok) b.ok.deinit();
        if (b == .ok) {
            var sc = try b.ok.initScratch(gpa);
            defer sc.deinit(gpa);
            const m = b.ok.find(&sc, case.input) orelse return error.GraphemePlusNoMatch;
            if (m.start != 0 or m.end != case.input.len) return error.GraphemePlusNotWhole;
        }
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe && zig build fuzz-scanner fuzz-unicode -Doptimize=ReleaseSafe`
Expected: PASS / exit 0.

Run: `zig build fuzz-scanner -Doptimize=ReleaseSafe --fuzz=50K` and `zig build fuzz-unicode -Doptimize=ReleaseSafe --fuzz=20K`
Expected: exit 0 or reports → *Open (to triage)*.

- [ ] **Step 6: Commit**

```sh
git add fuzz/check/scanner.zig fuzz/check/grapheme.zig fuzz/groups/scanner.zig fuzz/groups/unicode.zig fuzz/lib.zig fuzz/README.md
git commit -m "test(fuzz): mutation-driven scanner hardening; \\X grapheme oracle"
```

---

### Task 25: `threads.zig` — a shared `Program` across threads matches serial results

**Files:**
- Create: `fuzz/threads.zig`
- Modify: `fuzz/root.zig`

**Interfaces:**
- Consumes: `common.{pickPattern, PatBuf, build, summarize, Summary}`, `input_gen.pickSmall`, `std.Thread`.
- Produces: one finite test (in the aggregate `fuzz` unit).

- [ ] **Step 1: Write the test** — create `fuzz/threads.zig`:

```zig
//! A compiled `Program` is immutable and shareable across threads; all per-search state
//! lives in the caller's Scratch (docs/architecture.md §9, "Implicit assumptions" #5). So
//! four threads, each with its own Scratch, searching the SAME compiled regexes must get
//! exactly the serial answers. Finite (runs in `zig build test`).

const std = @import("std");
const gex = @import("ezi_gex");
const lib = @import("fuzz_lib");
const common = lib.check.common;
const input_gen = lib.gen.input;

const n_patterns = 20;
const n_inputs = 40;
const n_threads = 4;

const Ctx = struct {
    re: *const gex.Compiled(gex.backends.auto),
    inputs: []const []const u8,
    out: []common.Summary,
    failed: bool = false,

    fn work(ctx: *Ctx) void {
        for (ctx.inputs, ctx.out) |in, *o| {
            o.* = common.summarize(gex.backends.auto, std.testing.allocator, ctx.re, in) catch {
                ctx.failed = true;
                return;
            };
        }
    }
};

test "shared Program across threads matches serial results" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(61);
    var sb: [1024]u8 = undefined;
    var in_store: [n_inputs][input_gen.max_input_len]u8 = undefined;
    var inputs: [n_inputs][]const u8 = undefined;
    for (&inputs, &in_store) |*in, *st| {
        prng.random().bytes(&sb);
        var s: std.testing.Smith = .{ .in = &sb };
        in.* = input_gen.pickSmall(&s, st);
    }
    var done: usize = 0;
    while (done < n_patterns) {
        prng.random().bytes(&sb);
        var s: std.testing.Smith = .{ .in = &sb };
        var pb: common.PatBuf = .{};
        const p = common.pickPattern(&s, &pb) orelse continue;
        var b = try common.build(gex.backends.auto, gpa, p.pattern, p.opt);
        if (b != .ok) continue;
        defer b.ok.deinit();
        done += 1;
        var serial: [n_inputs]common.Summary = undefined;
        for (inputs, &serial) |in, *o| o.* = try common.summarize(gex.backends.auto, gpa, &b.ok, in);
        var outs: [n_threads][n_inputs]common.Summary = undefined;
        var ctxs: [n_threads]Ctx = undefined;
        var threads: [n_threads]std.Thread = undefined;
        for (&ctxs, &outs, &threads) |*c, *o, *t| {
            c.* = .{ .re = &b.ok, .inputs = &inputs, .out = o };
            t.* = try std.Thread.spawn(.{}, Ctx.work, .{c});
        }
        for (threads) |t| t.join();
        for (ctxs, outs) |c, o| {
            try std.testing.expect(!c.failed);
            for (serial, o, 0..) |want, got, k| {
                if (!got.eql(&want)) {
                    std.debug.print("threads: /{s}/ over \"{s}\" differs from serial\n", .{ p.pattern, inputs[k] });
                    return error.ThreadDivergence;
                }
            }
        }
    }
}
```

Add `_ = @import("threads.zig");` to `fuzz/root.zig`'s test block.

- [ ] **Step 2: Run it**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS. (It is written against the contract, so it passes on the first run unless the contract is violated —
a failure here is a finding: record it under *Open (to triage)* and mark the test `return error.SkipZigTest` with a
`// FUZZ-OPEN:` comment until Task 27's ledger takes it over.)

- [ ] **Step 3: Commit**

```sh
git add fuzz/threads.zig fuzz/root.zig
git commit -m "test(fuzz): shared-Program multi-thread parity"
```

---

### Task 26: `chaos` group — one case through every check that can take it

**Files:**
- Create: `fuzz/check/chaos.zig`, `fuzz/groups/chaos.zig`
- Modify: `fuzz/lib.zig`, `build.zig`, `fuzz/root.zig`

**Interfaces:**
- Consumes: `reference.run`, `metamorphic.run`, `invariants.run`, `state.run`, `api.run`, `api.genTemplate`, `state.max_hay`, `common.{printOpt, inputWithWitness}`.
- Produces: `run`, `fuzzOne`. A chaos case carries everything the five sub-checks read (tree + both printings' opt/seed, input ≤ `state.max_hay`, template, n, start/anchored/span_end); `run` feeds the same case to each.

- [ ] **Step 1: Write the failing group file** `fuzz/groups/chaos.zig`:

```zig
//! Fuzz group: chaos — one tree-printed case (random option variant, witness-bearing input,
//! hostile template, random search options) through reference, metamorphic, invariants,
//! state and api in turn. See check/chaos.zig.

const std = @import("std");
const lib = @import("fuzz_lib");

test "fuzz: one case through every check that can take it" {
    try std.testing.fuzz({}, lib.check.chaos.fuzzOne, .{ .corpus = &lib.check.common.generic_corpus });
}

test {
    std.testing.refAllDecls(@This());
}
```

Wire it (group list, root import, lib `check.chaos` + test block).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile (missing module).

- [ ] **Step 3: Implement `fuzz/check/chaos.zig`**

```zig
//! Chaos: the other checks each favour their own generators; this one builds a single
//! richly-populated case — a tree printed under a random compatible option variant, an
//! input that usually contains a witness, a hostile template, random search options — and
//! pushes it through every check that can take it, so combinations no single group favours
//! (e.g. an Options-seeded `(?i)` tree under a dirty scratch with a `${name}` template) run.

const std = @import("std");
const common = @import("common.zig");
const known_open = @import("known_open.zig");
const tree = @import("../gen/tree.zig");
const print = @import("../gen/print.zig");
const reference = @import("reference.zig");
const metamorphic = @import("metamorphic.zig");
const invariants = @import("invariants.zig");
const state = @import("state.zig");
const api = @import("api.zig");
const Smith = std.testing.Smith;
const Case = common.Case;

pub fn fuzzOne(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    const gpa = std.testing.allocator;
    const t = tree.generate(smith, tree.pickOpt(smith));
    const opt = common.printOpt(smith, t.opt);
    const seed = smith.value(u64);
    var ibuf: [state.max_hay]u8 = undefined;
    const input = try common.inputWithWitness(gpa, smith, &t, &ibuf);
    const pr = print.variant(&t, opt, seed) orelse return;
    var tbuf: [48]u8 = undefined;
    const start = smith.index(input.len + 1);
    const case: Case = .{
        .check = .chaos,
        .pattern = pr.slice(),
        .input = input,
        .tree = t.bytes(),
        .opt = opt,
        .seed = seed,
        .opt2 = common.printOpt(smith, t.opt),
        .seed2 = smith.value(u64) | 1,
        .template = api.genTemplate(smith, &tbuf),
        .n = smith.valueRangeAtMost(u8, 0, 5),
        .start = start,
        .anchored = smith.valueRangeAtMost(u8, 0, 1) == 0,
        .span_end = if (smith.valueRangeAtMost(u8, 0, 3) == 0) start + smith.index(input.len - start + 1) else null,
    };
    try known_open.runOrGate(gpa, &case, run);
}

pub fn run(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    common.noteRun(.chaos, true);
    inline for (.{ reference.run, metamorphic.run, invariants.run, state.run, api.run }) |sub| try sub(gpa, case);
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe && zig build fuzz-chaos -Doptimize=ReleaseSafe`
Expected: PASS / exit 0.

Run: `zig build fuzz-chaos -Doptimize=ReleaseSafe --fuzz=10K`
Expected: exit 0 or a report → *Open (to triage)*.

- [ ] **Step 5: Commit**

```sh
git add fuzz/check/chaos.zig fuzz/groups/chaos.zig fuzz/lib.zig fuzz/root.zig build.zig fuzz/README.md
git commit -m "test(fuzz): chaos group — one case through every compatible check"
```

---

## Phase E — Keeping the fuzzer honest, and triage tooling

### Task 27: Replayable differentials, the check registry, the known-open ledger, and the gate-rate guard

**Files:**
- Modify: `fuzz/check/differential.zig` (Case-based `run*` entry points)
- Create: `fuzz/check/registry.zig`, `fuzz/findings.zig`
- Modify: `fuzz/health.zig`, `fuzz/root.zig`, `fuzz/lib.zig`

**Interfaces:**
- Produces (`differential`): `runSpan`, `runCaptures`, `runIter`, `runReplace`, `runOffset`, `runStrategy` — each `fn (gpa, *const Case) anyerror!void`; the Smith bodies now build a `Case` and call `known_open.runOrGate`, so every existing group prints `FUZZ-CASE` lines too. (`scannerRobustness`, `repetitionLimit`, `graphemeNoCrash` stay Smith-only: they assert, so the fuzzer's own crash input is their replay.)
- Produces (`registry`): `run(gpa, *const Case) anyerror!void` dispatching on `case.check`.
- Produces (`findings.zig`): `Finding{ id, line: ?[]const u8, build: ?*const fn (*tree.Builder) u16, opt, input, err, note }`, `ledger`, tests "still reproduce" and "every gate has a ledger entry".
- Produces (`health`): `measureN(comptime body, seed, n) usize`, `gateRatesOk(runs) bool`, two gate-rate tests.

- [ ] **Step 1: Write the failing tests**

Append to `fuzz/health.zig`:

```zig
const known_open = lib.check.known_open;

/// No active gate may account for more than 1 % of `runs` fuzz iterations.
pub fn gateRatesOk(runs: usize) bool {
    for (known_open.active, 0..) |g, i| {
        if (i >= common.max_gates) break;
        if (@as(usize, common.stats.gated[i]) * 100 > runs) {
            std.debug.print("health: gate {s} swallowed {d} of {d} cases (> 1%)\n", .{ g.id, common.stats.gated[i], runs });
            return false;
        }
    }
    return true;
}

test "health: no known-open gate swallows more than 1% of cases" {
    inline for (.{ d.backendsAgree, d.capturesAgree, lib.check.reference.fuzzOne, lib.check.invariants.fuzzOne, lib.check.state.fuzzOne, lib.check.api.fuzzOne }) |body| {
        _ = measure(body, 0x6a7e);
        try std.testing.expect(gateRatesOk(body_seeds));
    }
}

test "health: the gate-rate guard fires on an over-broad gate" {
    const saved = known_open.active;
    defer known_open.active = saved;
    const everything = struct {
        fn f(_: *const common.Case) bool {
            return true;
        }
    }.f;
    const fake = [_]known_open.Gate{.{ .id = "fake-over-broad", .applies = everything }};
    known_open.active = &fake;
    _ = measure(lib.check.invariants.fuzzOne, 0x6a7e);
    try std.testing.expect(!gateRatesOk(body_seeds));
}
```

Create `fuzz/findings.zig`:

```zig
//! Known-open ledger. Each entry is a minimized case that currently FAILS with `err`; the
//! test asserts it still does. When a fix lands the entry flips to "no longer reproduces":
//! move the case into src/engine/conformance.zig as a regression, then delete the entry
//! here and its gate in check/known_open.zig. Entries are either a `FUZZ-CASE` line (what
//! `zig build fuzz-min` prints) or a reference-check tree built with `tree.Builder` (for
//! findings established by reasoning rather than by the fuzzer).

const std = @import("std");
const lib = @import("fuzz_lib");
const common = lib.check.common;
const tree = lib.gen.tree;

pub const Finding = struct {
    id: []const u8,
    line: ?[]const u8 = null,
    build: ?*const fn (*tree.Builder) u16 = null,
    opt: u8 = 0,
    input: []const u8 = "",
    /// The `@errorName` the check must STILL return.
    err: []const u8,
    note: []const u8,
};

pub const ledger = [_]Finding{};

fn replay(gpa: std.mem.Allocator, f: Finding) !?anyerror {
    const saved = common.quiet;
    common.quiet = true;
    defer common.quiet = saved;
    if (f.line) |line| {
        const c = try common.Case.parse(gpa, line);
        defer c.deinitOwned(gpa);
        lib.check.registry.run(gpa, &c) catch |e| return e;
        return null;
    }
    var b = tree.Builder.init(f.opt);
    const t = b.finish(f.build.?(&b));
    const pr = lib.gen.print.canonical(&t, f.opt).?;
    const c: common.Case = .{ .check = .reference, .pattern = pr.slice(), .input = f.input, .tree = t.bytes(), .opt = f.opt };
    lib.check.reference.run(gpa, &c) catch |e| return e;
    return null;
}

test "known-open findings still reproduce" {
    for (ledger) |f| {
        const got = try replay(std.testing.allocator, f);
        if (got) |e| {
            if (std.mem.eql(u8, @errorName(e), f.err)) continue;
            std.debug.print("finding {s} now fails differently: {s} (ledger says {s})\n", .{ f.id, @errorName(e), f.err });
            return error.FindingChanged;
        }
        std.debug.print("finding {s} no longer reproduces — fixed? Move it to src/engine/conformance.zig as a regression, then delete this entry and its gate.\n", .{f.id});
        return error.FindingFixed;
    }
}

test "every known-open gate has a ledger entry" {
    for (lib.check.known_open.gates) |g| {
        for (ledger) |f| {
            if (std.mem.eql(u8, f.id, g.id)) break;
        } else {
            std.debug.print("gate {s} has no ledger entry in fuzz/findings.zig\n", .{g.id});
            return error.GateWithoutFinding;
        }
    }
}
```

Add `_ = @import("findings.zig");` to `fuzz/root.zig`'s test block and `pub const registry = @import("check/registry.zig");` to lib `check` (+ test block).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile — `lib.check.registry` missing.

- [ ] **Step 3: Give the seven existing differentials Case-based entry points**

In `fuzz/check/differential.zig` add `const known_open = @import("known_open.zig"); const Case = common.Case;` and replace the bodies:

```zig
pub fn backendsAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    var pat = ps.gen(smith);
    var ibuf: [max_input_len]u8 = undefined;
    const case: Case = .{ .check = .span, .pattern = pat.slice(), .input = genInput(smith, &ibuf) };
    try known_open.runOrGate(std.testing.allocator, &case, runSpan);
}

pub fn anchorsAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    var pat = ps.genAnchors(smith);
    var ibuf: [24]u8 = undefined;
    const n = @min(smith.slice(&ibuf), ibuf.len);
    const alpha = "ab\n";
    for (ibuf[0..n]) |*b| b.* = alpha[b.* % alpha.len];
    const case: Case = .{ .check = .anchors, .pattern = pat.slice(), .input = ibuf[0..n] };
    try known_open.runOrGate(std.testing.allocator, &case, runSpan);
}

pub fn unicodeAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    var pat = ps.genUnicode(smith);
    var ibuf: [max_input_len]u8 = undefined;
    const input: []const u8 = if (smith.boolWeighted(2, 1)) ibuf[0..ps.unicodeInput(smith, &ibuf)] else ibuf[0..smith.slice(&ibuf)];
    const case: Case = .{ .check = .unicode, .pattern = pat.slice(), .input = input };
    try known_open.runOrGate(std.testing.allocator, &case, runSpan);
}

pub fn runSpan(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    return assertBackendsAgree(gpa, case.check, case.pattern, case.input);
}

pub fn capturesAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    var pat = ps.gen(smith);
    var ibuf: [max_input_len]u8 = undefined;
    const case: Case = .{ .check = .captures, .pattern = pat.slice(), .input = genInput(smith, &ibuf) };
    try known_open.runOrGate(std.testing.allocator, &case, runCaptures);
}

pub fn runCaptures(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    const oracle = try capsWith(gex.backends.pikevm, gpa, case.pattern, case.input);
    if (oracle.tag == .skip) return;
    common.noteRun(.captures, oracle.tag != .invalid);
    const byte_safe = byteEnginesSafe(gpa, case.pattern, case.input);
    inline for (capture_backends) |B| try checkCaps(B, gpa, oracle, case.pattern, case.input, byte_safe);
}

pub fn iterationAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    var pat = ps.gen(smith);
    var ibuf: [max_input_len]u8 = undefined;
    const case: Case = .{ .check = .iter, .pattern = pat.slice(), .input = genInput(smith, &ibuf) };
    try known_open.runOrGate(std.testing.allocator, &case, runIter);
}

pub fn runIter(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    const oracle = try iterWith(gex.backends.pikevm, gpa, case.pattern, case.input);
    if (oracle.tag == .skip) return;
    common.noteRun(.iter, oracle.tag != .invalid);
    const byte_safe = byteEnginesSafe(gpa, case.pattern, case.input);
    inline for (iter_backends) |B| try checkIter(B, gpa, oracle, case.pattern, case.input, byte_safe);
}

pub fn replaceAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    var pat = ps.gen(smith);
    var ibuf: [max_input_len]u8 = undefined;
    const input = genInput(smith, &ibuf);
    var tbuf: [24]u8 = undefined;
    const case: Case = .{ .check = .replace, .pattern = pat.slice(), .input = input, .template = genTemplate(smith, &tbuf) };
    try known_open.runOrGate(std.testing.allocator, &case, runReplace);
}

pub fn runReplace(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    const oracle = try replaceWith(gex.backends.pikevm, gpa, case.pattern, case.input, case.template);
    if (oracle.tag != .ok) return;
    defer gpa.free(oracle.bytes);
    common.noteRun(.replace, true);
    const byte_safe = byteEnginesSafe(gpa, case.pattern, case.input);
    inline for (replace_backends) |B| try checkReplace(B, gpa, oracle.bytes, case.pattern, case.input, case.template, byte_safe);
}

pub fn searchOffsetAgree(_: void, smith: *Smith) anyerror!void {
    @disableInstrumentation();
    var pat = ps.gen(smith);
    var ibuf: [max_input_len]u8 = undefined;
    const input = genInput(smith, &ibuf);
    const start = smith.index(input.len + 1);
    const anchored = smith.boolWeighted(1, 1);
    const span_end: ?usize = if (smith.boolWeighted(3, 1)) start + smith.index(input.len - start + 1) else null;
    const case: Case = .{ .check = .offset, .pattern = pat.slice(), .input = input, .start = start, .anchored = anchored, .span_end = span_end };
    try known_open.runOrGate(std.testing.allocator, &case, runOffset);
}
```

and move the body of the old `searchOffsetAgree` — from `const oracle = try findAtOf(...)` through the `inline for (offset_backends)` loop — into:

```zig
pub fn runOffset(gpa: std.mem.Allocator, case: *const Case) anyerror!void {
    @disableInstrumentation();
    const pattern = case.pattern;
    const input = case.input;
    const opts = case.searchOptions();
    const start = opts.start;
    const anchored = opts.anchored;
    const span_end = opts.span_end;
    // … the old body, unchanged, from `const oracle = try findAtOf(gex.backends.pikevm, gpa, pattern, input, opts);` …
}
```

Likewise split `strategyInvariant` into a Smith body that builds `.{ .check = .strategy, .pattern = …, .input = … }` and `pub fn runStrategy(gpa, case)` holding the old body from `const base = try matchWithOpts(.{}, gpa, pattern, input);` on (with `const pattern = case.pattern; const input = case.input;` at the top).

- [ ] **Step 4: Create `fuzz/check/registry.zig`**

```zig
//! CheckId → the check's deterministic `run`, for `fuzz-min` and the findings ledger.

const std = @import("std");
const common = @import("common.zig");
const d = @import("differential.zig");

pub fn run(gpa: std.mem.Allocator, case: *const common.Case) anyerror!void {
    return switch (case.check) {
        .span, .anchors, .unicode => d.runSpan(gpa, case),
        .captures => d.runCaptures(gpa, case),
        .iter => d.runIter(gpa, case),
        .replace => d.runReplace(gpa, case),
        .offset => d.runOffset(gpa, case),
        .strategy => d.runStrategy(gpa, case),
        .scanner => @import("scanner.zig").run(gpa, case),
        .grapheme => @import("grapheme.zig").run(gpa, case),
        .reference => @import("reference.zig").run(gpa, case),
        .metamorphic => @import("metamorphic.zig").run(gpa, case),
        .invariants => @import("invariants.zig").run(gpa, case),
        .state => @import("state.zig").run(gpa, case),
        .large => @import("large.zig").run(gpa, case),
        .literals => @import("literals.zig").run(gpa, case),
        .api => @import("api.zig").run(gpa, case),
        .oom => @import("oom.zig").run(gpa, case),
        .comptime_parity => @import("comptime_parity.zig").run(gpa, case),
        .complexity => @import("complexity.zig").run(gpa, case),
        .utf8class => @import("utf8class.zig").run(gpa, case),
        .chaos => @import("chaos.zig").run(gpa, case),
    };
}

test "registry replays a differential case" {
    try run(std.testing.allocator, &.{ .check = .span, .pattern = "a|ab", .input = "xab" });
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe && zig build fuzz -Doptimize=ReleaseSafe`
Expected: PASS / exit 0 (empty ledger, no gates; the over-broad fake gate trips the guard as intended).

- [ ] **Step 6: Commit**

```sh
git add fuzz/check/differential.zig fuzz/check/registry.zig fuzz/findings.zig fuzz/health.zig fuzz/root.zig fuzz/lib.zig
git commit -m "test(fuzz): replayable differentials, check registry, known-open ledger, gate-rate guard"
```

---

### Task 28: `fuzz-min` — replay and shrink a failing case

**Files:**
- Create: `fuzz/check/minimize.zig`, `fuzz/min.zig`
- Modify: `build.zig` (`fuzz-min` step), `fuzz/lib.zig`

**Interfaces:**
- Consumes: `registry.run`, `Case.{parse, format, deinitOwned}`, `tree.{Tree, fromBytes, renumberGroups, wellFormed}`, `print.canonical`.
- Produces (`minimize`): `Runner`, `dupCase(gpa, *const Case) !Case`, `minimize(gpa, *const Case, Runner) !?Case` (`null` ⇔ does not reproduce; the result is owned).
- Produces (CLI): `zig build fuzz-min -- '<FUZZ-CASE line>'` → prints the minimized `FUZZ-CASE` line, a Zig `Case` literal, and (tree cases) the canonical pattern; exit 1 with `does not reproduce` when the case passes; exit 2 on a malformed line.

- [ ] **Step 1: Write the failing tests** — create `fuzz/check/minimize.zig` with imports + tests:

```zig
const std = @import("std");
const common = @import("common.zig");
const tree = @import("../gen/tree.zig");
const print = @import("../gen/print.zig");
const Case = common.Case;
const testing = std.testing;

test "minimize reports a case that does not reproduce" {
    const pass = struct {
        fn f(_: std.mem.Allocator, _: *const Case) anyerror!void {}
    }.f;
    try testing.expect((try minimize(testing.allocator, &.{ .check = .span, .pattern = "ab", .input = "x" }, pass)) == null);
}

test "minimize shrinks pattern and input to the essential bytes" {
    const fake = struct {
        fn f(_: std.mem.Allocator, c: *const Case) anyerror!void {
            if (std.mem.indexOfScalar(u8, c.pattern, 'b') != null and std.mem.indexOf(u8, c.input, "xy") != null) return error.Boom;
        }
    }.f;
    const m = (try minimize(testing.allocator, &.{ .check = .span, .pattern = "aabbb", .input = "qqxyzz" }, fake)).?;
    defer m.deinitOwned(testing.allocator);
    try testing.expectEqualStrings("b", m.pattern);
    try testing.expectEqualStrings("xy", m.input);
}

test "minimize shrinks a tree node by node" {
    const fake = struct {
        fn f(_: std.mem.Allocator, c: *const Case) anyerror!void {
            const t = tree.Tree.fromBytes(c.tree) orelse return;
            const pr = print.canonical(&t, t.opt) orelse return;
            if (std.mem.indexOfScalar(u8, pr.slice(), 'z') != null) return error.Boom;
        }
    }.f;
    var b = tree.Builder.init(0);
    const root = b.cat(&.{ b.lit('a'), b.star(b.group(b.alt(&.{ b.lit('z'), b.lit('y') }))), b.lit('q') });
    const t = b.finish(root);
    const m = (try minimize(testing.allocator, &.{ .check = .reference, .tree = t.bytes() }, fake)).?;
    defer m.deinitOwned(testing.allocator);
    const mt = tree.Tree.fromBytes(m.tree).?;
    try testing.expectEqualStrings("z", print.canonical(&mt, mt.opt).?.slice());
}
```

Add `pub const minimize = @import("check/minimize.zig");` to lib `check` (+ test block).

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: FAIL to compile — `use of undeclared identifier 'minimize'`.

- [ ] **Step 3: Implement `minimize.zig`** (above the tests)

```zig
//! Delta debugging for a failing `Case`: re-run the exact check and keep every
//! simplification that still fails with the SAME error. Tree cases shrink node by node
//! (checks re-derive the pattern from the tree); string cases shrink pattern bytes; inputs
//! and templates shrink bytes in both. Bounded: at most 64 passes.

pub const Runner = *const fn (std.mem.Allocator, *const Case) anyerror!void;

fn failure(gpa: std.mem.Allocator, c: *const Case, runner: Runner) ?anyerror {
    runner(gpa, c) catch |e| return e;
    return null;
}

fn stillFails(gpa: std.mem.Allocator, c: *const Case, runner: Runner, err0: anyerror) bool {
    const e = failure(gpa, c, runner) orelse return false;
    return e == err0;
}

/// An owned copy of `c` — release with `deinitOwned`.
pub fn dupCase(gpa: std.mem.Allocator, c: *const Case) !Case {
    var out = c.*;
    out.pattern = try gpa.dupe(u8, c.pattern);
    errdefer gpa.free(out.pattern);
    out.input = try gpa.dupe(u8, c.input);
    errdefer gpa.free(out.input);
    out.template = try gpa.dupe(u8, c.template);
    errdefer gpa.free(out.template);
    out.tree = try gpa.dupe(u8, c.tree);
    return out;
}

/// `null` when `start` does not fail ("does not reproduce"); otherwise an owned, minimal case.
pub fn minimize(gpa: std.mem.Allocator, start: *const Case, runner: Runner) !?Case {
    const saved = common.quiet;
    common.quiet = true;
    defer common.quiet = saved;
    const err0 = failure(gpa, start, runner) orelse return null;
    var cur = try dupCase(gpa, start);
    errdefer cur.deinitOwned(gpa);
    var pass: usize = 0;
    while (pass < 64) : (pass += 1) {
        var changed = false;
        if (cur.tree.len > 0) {
            if (try shrinkTree(gpa, &cur, runner, err0)) changed = true;
        } else if (try shrinkField(gpa, &cur, "pattern", runner, err0)) changed = true;
        if (try shrinkField(gpa, &cur, "input", runner, err0)) changed = true;
        if (try shrinkField(gpa, &cur, "template", runner, err0)) changed = true;
        if (!changed) break;
    }
    return cur;
}

fn shrinkField(gpa: std.mem.Allocator, cur: *Case, comptime field: []const u8, runner: Runner, err0: anyerror) !bool {
    var any = false;
    var chunk: usize = @max(@field(cur, field).len / 2, 1);
    while (@field(cur, field).len > 0) {
        var i: usize = 0;
        var progressed = false;
        while (i < @field(cur, field).len) {
            const old = @field(cur, field);
            const n = @min(chunk, old.len - i);
            const cand = try gpa.alloc(u8, old.len - n);
            @memcpy(cand[0..i], old[0..i]);
            @memcpy(cand[i..], old[i + n ..]);
            var trial = cur.*;
            @field(trial, field) = cand;
            if (stillFails(gpa, &trial, runner, err0)) {
                gpa.free(old);
                @field(cur, field) = cand;
                progressed = true;
                any = true;
            } else {
                gpa.free(cand);
                i += n;
            }
        }
        if (!progressed) {
            if (chunk == 1) break;
            chunk /= 2;
        }
    }
    return any;
}

const n_edits = 8;

/// Edit number `k` applied to node `i`; false when it does not apply.
fn edit(t: *tree.Tree, i: u16, k: u8) bool {
    const n = t.nodes[i];
    switch (k) {
        0 => { // node → empty
            if (n.kind == .empty) return false;
            t.nodes[i] = .{ .kind = .empty, .flags = n.flags };
        },
        1 => switch (n.kind) { // node → its only child
            .repeat, .group, .flags => t.nodes[i] = t.nodes[n.first],
            .concat, .alt => {
                if (n.len != 1) return false;
                t.nodes[i] = t.nodes[t.kids[n.first]];
            },
            else => return false,
        },
        2 => { // repeat → exactly once
            if (n.kind != .repeat or (n.b == 1 and n.c == 1)) return false;
            t.nodes[i].b = 1;
            t.nodes[i].c = 1;
        },
        3 => { // bounded repeat → its minimum
            if (n.kind != .repeat or n.c == tree.unbounded or n.c == n.b) return false;
            t.nodes[i].c = n.b;
        },
        4 => { // drop the last kid
            if ((n.kind != .concat and n.kind != .alt) or n.len <= 1) return false;
            t.nodes[i].len -= 1;
        },
        5 => { // drop the first kid
            if ((n.kind != .concat and n.kind != .alt) or n.len <= 1) return false;
            t.nodes[i].first += 1;
            t.nodes[i].len -= 1;
        },
        6 => { // drop the last class item
            if (n.kind != .class or n.len <= 1) return false;
            t.nodes[i].len -= 1;
        },
        7 => switch (n.kind) { // un-negate a class / simplify a literal
            .class => {
                if (n.a == 0) return false;
                t.nodes[i].a = 0;
            },
            .lit => {
                if (n.cp == 'a') return false;
                t.nodes[i].cp = 'a';
            },
            else => return false,
        },
        else => return false,
    }
    return true;
}

fn shrinkTree(gpa: std.mem.Allocator, cur: *Case, runner: Runner, err0: anyerror) !bool {
    var t = tree.Tree.fromBytes(cur.tree) orelse return false;
    var any = false;
    var i: u16 = 1; // node 0 is the shared empty leaf
    while (i < t.n_nodes) : (i += 1) {
        var k: u8 = 0;
        while (k < n_edits) : (k += 1) {
            var cand = t;
            if (!edit(&cand, i, k)) continue;
            cand.renumberGroups();
            if (!cand.wellFormed()) continue;
            const bytes = try gpa.dupe(u8, cand.bytes());
            var trial = cur.*;
            trial.tree = bytes;
            if (stillFails(gpa, &trial, runner, err0)) {
                gpa.free(cur.tree);
                cur.tree = bytes;
                t = cand;
                any = true;
            } else gpa.free(bytes);
        }
    }
    return any;
}
```

- [ ] **Step 4: Create the CLI `fuzz/min.zig`**

```zig
//! `zig build fuzz-min -- '<FUZZ-CASE line>'` — replay a failing case exactly and shrink it.
//! Prints the minimized FUZZ-CASE line, a Zig `Case` literal ready for fuzz/findings.zig or
//! src/engine/conformance.zig, and (tree cases) the canonical pattern. Exit 1: the case
//! does not reproduce. Exit 2: not a FUZZ-CASE line. Tip: `-- "$(cat case.txt)"`.

const std = @import("std");
const lib = @import("fuzz_lib");
const common = lib.check.common;

fn zigString(bytes: []const u8) void {
    std.debug.print("\"", .{});
    for (bytes) |c| {
        if (c >= 0x20 and c < 0x7F and c != '"' and c != '\\') std.debug.print("{c}", .{c}) else std.debug.print("\\x{X:0>2}", .{c});
    }
    std.debug.print("\"", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.skip();
    const line = it.next() orelse {
        std.debug.print("usage: zig build fuzz-min -- '<FUZZ-CASE line>'\n", .{});
        std.process.exit(2);
    };
    const case = common.Case.parse(gpa, line) catch {
        std.debug.print("fuzz-min: not a complete FUZZ-CASE line\n", .{});
        std.process.exit(2);
    };
    defer case.deinitOwned(gpa);

    const m = (try lib.check.minimize.minimize(gpa, &case, lib.check.registry.run)) orelse {
        std.debug.print("fuzz-min: does not reproduce (check {s})\n", .{@tagName(case.check)});
        std.process.exit(1);
    };
    defer m.deinitOwned(gpa);

    // Replay once, loudly, so the failure message is shown for the minimized case.
    lib.check.registry.run(gpa, &m) catch |e| std.debug.print("minimized case fails with {s}\n", .{@errorName(e)});

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try m.format(&aw.writer);
    std.debug.print("\n{s}\n\n.{{ .check = .{s}, .opt = {d}, .pattern = ", .{ aw.written(), @tagName(m.check), m.opt });
    zigString(m.pattern);
    std.debug.print(", .input = ", .{});
    zigString(m.input);
    std.debug.print(", .template = ", .{});
    zigString(m.template);
    std.debug.print(", .start = {d}, .anchored = {}, .span_end = {?d}, .seed = {d}, .n = {d} }}\n", .{ m.start, m.anchored, m.span_end, m.seed, m.n });
    if (lib.gen.tree.Tree.fromBytes(m.tree)) |t| {
        if (lib.gen.print.canonical(&t, t.opt)) |p| std.debug.print("canonical tree pattern: /{s}/ (opt {d})\n", .{ p.slice(), t.opt });
    }
}
```

In `build.zig`, after the `for (fuzz_groups)` loop, add:

```zig
    // `zig build fuzz-min -- '<FUZZ-CASE line>'`: replay a failing fuzz case and shrink it.
    const fuzz_min_exe = b.addExecutable(.{
        .name = "fuzz-min",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz/min.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{fuzz_lib},
        }),
    });
    const run_fuzz_min = b.addRunArtifact(fuzz_min_exe);
    run_fuzz_min.addPassthruArgs();
    b.step("fuzz-min", "Replay and shrink a FUZZ-CASE line: zig build fuzz-min -- '<line>'").dependOn(&run_fuzz_min.step);
```

- [ ] **Step 5: Run to verify it passes**

Run: `zig build test-fuzz -Doptimize=ReleaseSafe`
Expected: PASS (three minimize tests).

Run: `zig build fuzz-min -Doptimize=ReleaseSafe -- 'FUZZ-CASE check=span opt=0 start=0 anchored=0 span_end=null seed=0 n=0 opt2=0 seed2=0 pat=617c6162 in=786162 tmpl= tree='; echo "exit=$?"`
Expected: `fuzz-min: does not reproduce (check span)` and `exit=1` (it is a passing case).

Run: `zig build fuzz-min -Doptimize=ReleaseSafe -- 'garbage'; echo "exit=$?"`
Expected: `fuzz-min: not a complete FUZZ-CASE line` and `exit=2`.

- [ ] **Step 6: Commit**

```sh
git add fuzz/check/minimize.zig fuzz/min.zig fuzz/lib.zig build.zig
git commit -m "test(fuzz): fuzz-min — replay and delta-debug a FUZZ-CASE line"
```

---

### Task 29: Health floors for every new check, the test-time budget, and the README

**Files:**
- Modify: `fuzz/health.zig`, `fuzz/README.md` (rewrite; keep the *Open (to triage)* section at the end)

**Interfaces:**
- Produces (`health`): `measureN(comptime body, seed, n) usize` (`measure` becomes `measureN(body, seed, body_seeds)`); floor tests for `reference`, `metamorphic`, `invariants`, `state`, `api`, `utf8class`, `literals`, `large` (+ `large.over_4096`).

- [ ] **Step 1: Add `measureN` and the floor tests** (floors start at the values below; Step 2 sets them from measurement)

In `fuzz/health.zig` rename `measure`'s body into `measureN(comptime body: anytype, seed: u64, n: usize) usize` (loop `for (0..n)`), and make `pub fn measure(comptime body: anytype, seed: u64) usize { return measureN(body, seed, body_seeds); }`. Then append:

```zig
test "health: the new checks compare what they claim" {
    _ = measure(lib.check.reference.fuzzOne, 0x7e1);
    inline for (.{ "pikevm", "backtrack", "auto" }) |b| try expectFloor(.reference, b, 0.90);
    _ = measure(lib.check.metamorphic.fuzzOne, 0x7e2);
    inline for (.{ "pikevm", "backtrack", "auto", "bytepike", "dfa", "edfa" }) |b| try expectFloor(.metamorphic, b, 0.20);
    _ = measure(lib.check.invariants.fuzzOne, 0x7e3);
    inline for (.{ "pikevm", "backtrack", "auto", "bytepike", "dfa", "edfa" }) |b| try expectFloor(.invariants, b, 0.20);
    _ = measure(lib.check.state.fuzzOne, 0x7e4);
    inline for (.{ "pikevm", "backtrack", "auto", "bytepike", "dfa", "edfa" }) |b| try expectFloor(.state, b, 0.20);
    _ = measure(lib.check.api.fuzzOne, 0x7e5);
    inline for (.{ "backtrack", "auto", "bytepike" }) |b| try expectFloor(.api, b, 0.20);
    _ = measure(lib.check.utf8class.fuzzOne, 0x7e6);
    inline for (.{ "pikevm", "backtrack", "auto", "bytepike", "dfa", "edfa" }) |b| try expectFloor(.utf8class, b, 0.80);
}

test "health: literal sets reach the literal backend; large inputs cross 4096" {
    _ = measureN(lib.check.literal_sets.fuzzOne, 0x7e7, 60);
    try expectFloor(.literals, "literal", 0.30);
    try expectFloor(.literals, "auto", 0.90);
    lib.check.large.over_4096 = 0;
    _ = measureN(lib.check.large.fuzzOne, 0x7e8, 40);
    if (lib.check.large.over_4096 * 4 < 40) {
        std.debug.print("health: only {d}/40 large inputs exceeded 4096 bytes\n", .{lib.check.large.over_4096});
        return error.LargeNeverLarge;
    }
    inline for (.{ "auto", "dfa", "edfa", "bytepike" }) |b| try expectFloor(.large, b, 0.20);
}
```

- [ ] **Step 2: Measure and set every floor**

Same procedure as Task 3 Step 6: set all new floors to `1.0`, run `zig build test-fuzz -Doptimize=ReleaseSafe 2>&1 | grep -E "^health"`,
then set each to measured × 0.8 rounded down to 0.05. A measured value under 0.05 for a backend expected to engage is a
vacuity finding — explain it (print the skip reason) before choosing a floor, and say so in the commit message.

- [ ] **Step 3: Check the test-time budget**

Run: `rm -rf .zig-cache/o && time zig build test -Doptimize=ReleaseSafe`
Expected: at most the Task 1 baseline + 30 s. If over: (1) halve `body_seeds`/`gen_seeds`; (2) cut
`comptime_parity.table` to 12 rows; (3) as a last resort drop `_ = @import("groups/comptime_parity.zig");` from
`fuzz/root.zig` (its `fuzz-comptime_parity` step still runs it) and note that in the README. Re-measure after each.

- [ ] **Step 4: Rewrite `fuzz/README.md`**

Replace everything above the `## Open (to triage)` section with:

````markdown
# ezi_gex fuzzing

A fuzz suite that trusts nothing: not ezi_gex's own oracle, not fresh state, not well-formed
input, not the allocator, not the small-input regime — and not itself. Built on Zig's
`std.testing.fuzz` + `Smith`; drives only the published `ezi_gex` module (plus `ezi_code`
point lookups for the independent reference).

## Running

```sh
zig build test-fuzz -Doptimize=ReleaseSafe          # finite: fuzz_lib unit tests + every group's seed replay + health + ledger + threads
zig build fuzz -Doptimize=ReleaseSafe               # finite smoke of all 19 group binaries, in parallel
zig build fuzz -Doptimize=ReleaseSafe --fuzz=1M     # REAL fuzzing: every group in parallel, 1M iterations each
zig build fuzz-<group> -Doptimize=ReleaseSafe --fuzz=2M
sh fuzz/campaign.sh                                  # long campaign with per-group budgets (see the script)
```

> ⚠️ Bare `--fuzz` (no `=N`) runs forever. Always pass `=N`.

## Layout

| Path | What it is |
|------|------------|
| `lib.zig` | the `fuzz_lib` module every fuzz binary imports |
| `gen/` | generators: `pattern` (string-level), `tree` + `print` + `witness` (semantic tree, equivalent printings, matching strings), `input` (evil UTF-8, long edge-biased inputs, fold-swap), `literals`, `props` |
| `ref/` | the independent reference matcher: `uni` (strict UTF-8, per-code-point predicates, fold orbits), `nfa` (Rust construction), `pike` (naive Pike VM), `selfcheck` |
| `check/` | one file per check (`run` + `fuzzOne`), `common` (Case, stats, helpers), `known_open` (gates), `registry`, `minimize` |
| `groups/` | 19 thin fuzz targets, one binary each |
| `health.zig` · `findings.zig` · `threads.zig` · `min.zig` | vacuity guards · known-open ledger · multi-thread parity · `fuzz-min` CLI |

## Groups

| Group | What must hold |
|-------|----------------|
| `scanner` | parse never crashes; `{m,n}` ceiling; mutated patterns: located diagnostics on reject, backend agreement on accept |
| `diff` · `anchors` · `unicode` | every backend's span/isMatch == the Pike VM's (general / anchor-heavy / Unicode patterns); `\X` tiles input along ezi_code's grapheme clusters |
| `captures` · `iter` · `search` | capture slots, findAll/count + `$`-replace, findAt offsets/anchoring/span_end and strategy invariance vs the Pike VM |
| `reference` | Pike VM / backtrack / auto == the **independent** reference on span, every slot, and findAll |
| `metamorphic` | two equivalent printings of one tree behave identically on every backend; fold-swap relation |
| `invariants` | oracle-free laws on every backend (isMatchAt, unanchored = first anchored, findAll resume, slot containment, replace/split reconstruction) |
| `state` | one long-lived heap AND buffer scratch over refilled/truncated/moved buffers and abandoned iterators == fresh-scratch Pike VM |
| `large` | inputs to 12 KiB across auto's 4096 cut and SIMD block edges, witnesses planted |
| `literals` | literal sets through literal/Teddy/memmem/prefix sets and the strategy tier |
| `api` | split/splitN, replace/replaceN/replaceAllWith, capturesAll/capturesAt, names, hostile templates |
| `oom` | every allocation failure → `OutOfMemory`, no leaks, no swallowing |
| `comptime_parity` | comptime-compiled == runtime-compiled; `*Comptime` matchers |
| `complexity` | backtrack work linear on generated patterns; zero confirms on end-anchored `auto` programs |
| `utf8class` | class membership at UTF-8 boundaries vs ground truth, on every backend |
| `chaos` | one case through reference, metamorphic, invariants, state, api |

## Semantics the suite treats as spec

Leftmost-first; RE2/Rust empty-width loops (0.6.0); `$`≡`\z`≡`\Z` without `m`; `(?m)` on `\n`
only; `.` excludes only `\n` unless `s`; `\d`=Nd, `\w`=Alphabetic∪M∪Nd∪Pc∪Join_Control,
`\s`=White_Space (`unicode=false`: ASCII sets; `\b` stays Unicode); dead-on-invalid input;
`(?i)` simple folding (`case_fold=.none` ignores it); `Script_Extensions` falls back to `Script`.
A divergence the reference finds is either an ezi_gex bug or a spec question; a spec question is
resolved in favour of ezi_gex's documented behaviour, recorded here, and the reference aligned.

## The reference matcher

`ref/` is a second, deliberately naive regex engine that never imports `ezi_gex` and never parses
a pattern string: it interprets the generator's semantic tree directly, with its own Thompson
construction (Rust `regex-automata`'s — the semantics ezi_gex claims), its own Pike simulation,
its own strict UTF-8 decoder, and Unicode predicates from `ezi_code` **point** lookups (not the
range tables ezi_gex's HIR is built from). So a bug in ezi_gex's shared scanner → AST → HIR → nfa
front end — the class every in-process differential is blind to — shows up as a disagreement.
`ref/selfcheck.zig` pins the reference to ezi_gex's human-verified conformance rows.

## Health: the suite must not pass by doing nothing

`health.zig` fails when a generator's valid-pattern rate or size collapses, when any backend is
*compared* on too few cases (a backend that declines everything would otherwise make its
differential silently vacuous), when large inputs stop crossing 4096 bytes, or when a known-open
gate swallows more than 1 % of cases. Floors are measured values × 0.8; lowering one needs a
stated reason in the commit.

## Triage

1. A failing check prints `check <id> failed: <error>` and one `FUZZ-CASE …` line.
2. `zig build fuzz-min -Doptimize=ReleaseSafe -- '<line>'` replays it exactly and shrinks it
   (tree cases node by node), printing the minimal line and a Zig `Case` literal.
3. Classify: harness/printer/reference bug → fix `fuzz/`; spec question → record above, align the
   reference; ezi_gex bug → add a `fuzz/findings.zig` ledger entry (and, if it recurs, a
   `check/known_open.zig` gate). The ledger test fails when the bug is fixed — then move the case
   to `src/engine/conformance.zig` and delete the entry and gate.

The fix history lives in the [CHANGELOG](../CHANGELOG.md).
````

- [ ] **Step 5: Run everything**

Run: `zig build test -Doptimize=ReleaseSafe && zig build fuzz -Doptimize=ReleaseSafe`
Expected: PASS / exit 0.

- [ ] **Step 6: Commit**

```sh
git add fuzz/health.zig fuzz/README.md fuzz/root.zig fuzz/check/comptime_parity.zig
git commit -m "test(fuzz): health floors for every check; README for the cynical suite"
```

---

## Phase F — Shakedown, campaign, findings report

### Task 30: Shakedown — flush harness false positives; confirm the pre-identified findings

**Files:**
- Modify: `fuzz/findings.zig`, `fuzz/check/known_open.zig`, `fuzz/README.md`, and any `fuzz/` file with a harness bug
- Create: `fuzz/campaign.sh`

**Interfaces:**
- Produces: a clean 200K-iteration shakedown per group (gated findings excepted); ledger entries for every confirmed ezi_gex bug; `fuzz/campaign.sh`.

- [ ] **Step 1: Confirm the findings identified while writing this plan**

Each is reproduced deterministically before anything else:

1. **`findAll` over-skips after an empty match at a malformed lead byte** (`engine/backend.zig` `advanceCodePoint` uses `codePointLenLossy` — the lead byte's *optimistic* length): `a?` over `"\xE6a"` yields only `[0,0]`, skipping the valid `a` at 1.
   Run: `zig build fuzz-min -Doptimize=ReleaseSafe -- 'FUZZ-CASE check=invariants opt=0 start=0 anchored=0 span_end=null seed=0 n=0 opt2=0 seed2=0 pat=613f in=e661 tmpl= tree='`
   Expected: reproduces (`FindAllStoppedEarly` or `FindAllResume`). Add the printed line to `ledger` as id `findall-overskip-invalid-lead`, `err` = the printed error name.
2. **`\b` treats a malformed byte differently on each side** (`engine/nfa.zig` `cpBefore` falls back to the raw byte as a code point — `0xC3` reads as `Ã`, a word character — while `wordAfter` decodes it as U+FFFD, a non-word character): `\b` over `"\xC3"` matches at `[1,1]`. Add to `ledger`:

```zig
    .{
        .id = "wordboundary-invalid-byte-asymmetry",
        .build = struct {
            fn f(b: *tree.Builder) u16 {
                return b.assert(.word_boundary);
            }
        }.f,
        .input = "\xC3",
        .err = "ReferenceSpan",
        .note = "cpBefore() maps a malformed byte to its raw value (0xC3 = 'Ã', a word char); wordAfter() maps it to U+FFFD (non-word). Spec question: word-ness of a malformed byte.",
    },
```

   Run: `zig build test-fuzz -Doptimize=ReleaseSafe` — Expected: PASS (the ledger asserts both still reproduce).
3. **Silently skipped conformance cases**: `src/engine/conformance.zig` `wide_cases` rows `\p{Greek}+` (line 154) and `\p{Han}+` (line 155) use names the scanner rejects (`scanner.zig:1872-1876` pins `Greek` as rejected); `findOutcome` maps the compile error to `.skip`, so those rows test nothing. Record under *Open (to triage)* in `fuzz/README.md` with the grep evidence (`grep -n 'p{Greek}\|p{Han}' src/engine/conformance.zig`). No ledger entry (it is a test-suite gap in `src/`, not a matcher divergence).
4. **Stale design doc**: `DESIGN.md` §2.1 says empty-width loops follow JS; `conformance.zig` (`nullable_alt_repetition_cases`) and the CHANGELOG pin RE2/Rust since 0.6.0. Record under *Open (to triage)*.
5. Already fixed in this suite (Task 3), reported for completeness: replay-mode `eos` made seed replay test near-empty patterns; `genUnicode` spent ~25% of its budget on rejected property names.

- [ ] **Step 2: Shakedown run**

```sh
for g in scanner diff anchors unicode captures iter search reference metamorphic invariants state api utf8class complexity chaos; do
  zig build fuzz-$g -Doptimize=ReleaseSafe --fuzz=200K 2>&1 | tee -a /tmp/fuzz-shakedown-$g.log | grep -E "FUZZ-CASE|failed:" | head -3
done
for g in large literals oom comptime_parity; do
  zig build fuzz-$g -Doptimize=ReleaseSafe --fuzz=20K 2>&1 | tee -a /tmp/fuzz-shakedown-$g.log | grep -E "FUZZ-CASE|failed:" | head -3
done
```

(Use the session scratchpad directory instead of `/tmp` when running under Claude Code.)

- [ ] **Step 3: Triage loop — repeat until every group runs its budget clean**

For each reported `FUZZ-CASE` line:
1. `zig build fuzz-min -Doptimize=ReleaseSafe -- '<line>'` → minimal case.
2. Decide the layer by reading the minimal case:
   - the printed pattern is not equivalent to the tree / the witness or generator is wrong → **harness bug**: fix under `fuzz/gen` or `fuzz/check`, commit `fix(fuzz): …`;
   - the reference disagrees with a documented ezi_gex rule → **reference bug** (fix `fuzz/ref`) or **spec question** (add the rule to README *Semantics*, align the reference, commit `docs(fuzz): …`);
   - otherwise → **ezi_gex finding**: add the minimal line to `fuzz/findings.zig` `ledger` (id, err, one-line note naming the suspected layer); if the same shape keeps firing, add a narrow gate to `check/known_open.zig` `gates` whose `applies` matches the minimized shape (pattern + input property), with the SAME id. Commit `test(fuzz): ledger <id>`.
3. Re-run that group's shakedown.

Every harness/reference fix must come with a unit test in the file it fixes that fails before the fix.

- [ ] **Step 4: Create `fuzz/campaign.sh`** (per-group budgets, all groups in parallel, logs kept)

```sh
#!/bin/sh
# Long fuzz campaign: every group in parallel with its own iteration budget (the groups
# differ ~100x in cost per iteration). Logs land in fuzz/.campaign/<group>.log; every
# reported case is a `FUZZ-CASE …` line — grep them and feed each to `zig build fuzz-min`.
# Budgets target roughly two hours on an 8–10 core machine; scale with FUZZ_SCALE=0.5 / 2.
set -u
cd "$(dirname "$0")/.."
mkdir -p fuzz/.campaign
scale=${FUZZ_SCALE:-1}
budgets="scanner:40000000 diff:6000000 anchors:8000000 unicode:6000000 captures:6000000 iter:5000000 search:5000000
reference:3000000 metamorphic:2000000 invariants:2000000 state:2000000 api:2000000 utf8class:8000000
complexity:1000000 chaos:1000000 large:150000 literals:300000 oom:200000 comptime_parity:3000000"
zig build -Doptimize=ReleaseSafe fuzz >/dev/null 2>&1 || { echo "finite smoke failed — fix before a campaign"; exit 1; }
for pair in $budgets; do
  g=${pair%%:*}
  n=$(awk -v n="${pair##*:}" -v s="$scale" 'BEGIN { printf "%d", n * s }')
  ( zig build "fuzz-$g" -Doptimize=ReleaseSafe --fuzz="$n" > "fuzz/.campaign/$g.log" 2>&1; echo "$g exit=$?" >> fuzz/.campaign/status ) &
done
wait
echo "campaign done:"; cat fuzz/.campaign/status
grep -h "FUZZ-CASE" fuzz/.campaign/*.log | sort -u > fuzz/.campaign/cases.txt
echo "$(wc -l < fuzz/.campaign/cases.txt) distinct cases in fuzz/.campaign/cases.txt"
```

Add `fuzz/.campaign/` to `.gitignore`. Calibrate the budgets once: run each group with `--fuzz=20K` under `time`,
and set its budget to `iterations/second × 7200 × 0.8` (rounded). Record the measured rates as a comment block at the top
of the script.

- [ ] **Step 5: Commit**

```sh
git add fuzz/ .gitignore
git commit -m "test(fuzz): shakedown fixes, ledger entries, campaign script"
```

---

### Task 31: The campaign and the findings report

**Files:**
- Modify: `fuzz/findings.zig`, `fuzz/check/known_open.zig`, `fuzz/README.md`
- Create: `docs/superpowers/reports/2026-MM-DD-fuzz-campaign.md` (dated the day the campaign ends)

- [ ] **Step 1: Run the campaign**

Run: `sh fuzz/campaign.sh` (as a background job — ~2 h)
Expected: `campaign done:` with a status line per group and a `cases.txt` of distinct reported cases.

- [ ] **Step 2: Triage every case** exactly as Task 30 Step 3 (fuzz-min → classify → fix harness / record spec rule / ledger + gate). A group that stopped early on a now-gated finding is re-run for its remaining budget.

- [ ] **Step 3: Write the findings report**

`docs/superpowers/reports/2026-MM-DD-fuzz-campaign.md`:

```markdown
# Fuzz campaign — <date>

**Suite:** fuzz/ at <commit>. **Budget:** <total iterations> across 19 groups, <wall time>.

## Findings (ezi_gex)

| id | check | minimal repro (pattern · input · options) | backends | suspected layer | class | ledger / gate |
|----|-------|--------------------------------------------|----------|-----------------|-------|---------------|
| … one row per ledger entry … |

## Spec questions resolved during triage
- … rule — where recorded …

## Test-suite and documentation gaps
- conformance `wide_cases` rows that silently skip (…)
- DESIGN.md §2.1 stale empty-loop text
- …

## Harness fixes made during the campaign
- …

## Coverage notes
- per-group iterations; health floors as measured; anything the suite still cannot reach
  (e.g. `auto`'s `prone` classification is internal, so only `anchored_end` programs are
  complexity-checked against `confirm_probes`).
```

- [ ] **Step 4: Verify and commit**

Run: `zig build test -Doptimize=ReleaseSafe && zig build fuzz -Doptimize=ReleaseSafe`
Expected: PASS / exit 0 (every ledger entry still reproduces; gates within 1 %).

```sh
git add fuzz/ docs/superpowers/reports/
git commit -m "docs(fuzz): campaign findings report"
```

- [ ] **Step 5: Hand off** — present the report's findings table to the owner and ask which to fix; each fix is a separate follow-up (engine change + a revert-failing `conformance.zig` regression + removing its ledger entry and gate).
