# ezi_gex fuzzing

Coverage-guided fuzz targets built on Zig's `std.testing.fuzz` + `Smith`
(structure-aware input generation, Zig ≥ `0.17.0-dev.864`). The harness drives
the **published `ezi_gex` module** exactly as a downstream user would — it never
reaches into internals — so what it exercises is the real public surface.

## Layout

The suite is split into **groups** — one test binary each — so they fuzz in
**parallel** (one OS process per core) instead of one binary round-robining every
target on a single core. The differential bodies are shared.

| File | What it is |
|------|------------|
| `groups/harness.zig`       | The shared differential bodies + helpers every group calls — the Pike-VM-oracle comparison over the full backend set, the capture/iteration/replace/search-offset differentials, the byte-engine ASCII-`\b` gate, and the seed corpora. |
| `groups/pattern_smith.zig` | Three `Smith`-driven pattern generators — `gen` (general: literals, classes, groups incl. **named** `(?<n>…)`/`(?P<n>…)`, **inline flags** `(?ims-x:…)`, `\x{}`/`\u{}` escapes), `genAnchors` (anchor/zero-width-heavy), `genUnicode` (`\p{}`/`\P{}`/scripts/multi-byte/folding) — so the fuzzer spends its budget on the parser/HIR/backends, not lexer error-recovery. Only emits scanner-supported syntax. |
| `groups/{scanner,diff,anchors,unicode,captures,iter,search}.zig` | The seven groups — thin `test` blocks that hand a `harness` body to `std.testing.fuzz`. Each compiles to its own binary. |
| `root.zig`                 | Aggregator: pulls every group into ONE binary so `zig build test` / `test-fuzz` runs the whole suite finitely (seed-corpus replay) as a regression unit. |

## Running

Finite by default — the suite doubles as an ordinary regression unit:

```sh
zig build test-fuzz                 # finite: replays every group's seed corpus + an empty input
zig build fuzz                      # finite smoke of every group (in parallel)
zig build test                      # the `fuzz` unit runs as part of the aggregate
```

To actually fuzz, add `--fuzz=N` (N iterations **per group**). `zig build fuzz`
depends on all seven groups and the **build scheduler runs them concurrently** —
exactly as `zig build test` runs the unit binaries at once — so this fuzzes every
group in parallel:

```sh
zig build fuzz --fuzz=1M             # all 7 groups in parallel, 1M iters each (7M total)
zig build fuzz-diff --fuzz=2M        # just the cross-backend span differential
zig build fuzz-iter --fuzz=2M        # just findAll/count + replace
```

> ⚠️ **Bare `--fuzz` (no `=N`) soaks forever** by design — always pass `=N`.

Each iteration is intentionally cheap — generated patterns are capped at
`pattern_smith.max_pattern_len` bytes with `{m,n}` bounds ≤ `max_rep_bound`, and
haystacks at `max_input_len` — so the fuzzer makes **steady forward progress**
rather than stalling on one pathological case.

## What the groups cover

Every matching differential uses the **Pike VM as the oracle** (linear-time,
capture-complete, every feature bar `\X`); any other backend that *accepts* a
generated pattern must agree byte-for-byte, and one that *declines* (Unsupported /
a resource ceiling) is skipped, never compared. This differences the whole
capability matrix — crucially the **DFA family (`dfa`/`edfa`) and `bytepike`**,
which the original three-backend differential never touched.

- **`scanner`** — `parseWith` never crashes on arbitrary bytes (clean AST or a
  located `error.InvalidPattern`, never UB/panic/leak), and the `{m,n}` ceiling's
  accept/reject + exact diagnostic code is correct for a random `(min,max?,limit)`.
- **`diff`** — span / `find` / **`isMatch`** across pikevm vs backtrack, auto,
  bytepike, dfa, edfa, onepass, literal. Pins the `isMatch == (find != null)`
  invariant per backend (the check that caught the dfa `^?\z` bug below).
- **`anchors`** — anchor + zero-width patterns (`^ $ \A \z \b \B (?m:…)`, empty
  branches, nullable quantifiers) over newline-rich inputs, across all backends.
- **`unicode`** — `\p{}`/`\P{}`/scripts/multi-byte literals/`(?i)` folding over
  BOTH valid UTF-8 and raw (often invalid) bytes; plus a `\X` grapheme no-crash
  target on the backtracker (its only backend).
- **`captures`** — full capture-slot arrays (every group) across pikevm /
  backtrack / auto / onepass / bytepike.
- **`iter`** — the non-overlapping `findAll` *sequence* agrees across backends and
  `count` equals it; and `$`-template **`replaceAll`** output is byte-identical
  across the capture backends.
- **`search`** — `findAt(.{ .start, .anchored, .span_end })` agrees across backends
  (offset/anchored/bounded resume), with oracle self-invariants (anchored ⇒ starts
  at `start`; unanchored ⇒ at/after; never ends past `span_end`); and the
  strategy-tier (`byte_engine`/`prefilter`/`simd`) is results-invariant.

**Byte-engine ASCII-`\b` gate.** `bytepike`/`dfa`/`edfa` evaluate `\b`/`\B` as
**ASCII** word boundaries (exact on ASCII input; `auto` routes non-ASCII `\b` to
the code-point engines). So for a `\b`-bearing pattern over a **non-ASCII**
haystack the differential skips the byte engines — comparing them there would be
comparing two valid-but-different contracts. Mirrors `conformance.byteEngineCanRunCase`.

## A note on cross-engine (external-oracle) differential

The targets above diff ezi's own backends, which **share** the scanner → AST → HIR
→ nfa front end; a bug *there* makes all of them agree on the wrong answer. Diffing
against an **independent** engine (Rust `regex`, RE2-lineage) catches that
shared-front-end class — and did once: `word_boundary_with_lazy_repetition`
(`[^a]+?\B *`) was found that way, not by the in-process targets.

That is a **cross-language comparison activity, not a library concern**, so it lives
in the sibling **`regex-bench`** project (which already builds ezi against Rust/Go
for parity), *not* here. As of v0.6.0 ezi follows **RE2/Rust leftmost-first**
semantics uniformly — including the empty-width-loop rule (`(?:|.)+` → `""`,
`(?:a?b??)+` → `"a"`) — so a Rust differential no longer needs to carve out an
empty-loop subset; the two coincide across the full ASCII space.

## Findings so far

> **The fix history lives in the [CHANGELOG](../CHANGELOG.md), not here.** This file documents the
> *suite*; the per-fix log belongs in the changelog. What follows is only the durable shape of what
> the differential keeps finding.

The differential has surfaced (and pinned) a family of cross-backend divergences — overwhelmingly in
the **byte-DFA span path** and the **`auto` dispatcher**, never in the shared NFA core. Two recurring
shapes dominate: a leftmost-**longest** byte DFA losing the leftmost-**first** priority the Pike VM
keeps (declined per-shape via an `hir.Analysis` flag in `dfa`/`edfa.supports`), and empty-width-loop
priority over nullable bodies. Every fix is permanent — pinned by a `conformance.zig` regression with
controls that keep the benchmarked fast paths eligible — and the smoke run (`zig build test`) stays
green throughout (it replays only simple seeds).

Two lessons worth keeping:

- **`pikevm == backtrack` has never broken — so far.** Every bug found lived in a byte engine or the
  `auto` dispatcher, downstream of the shared scanner→AST→HIR→nfa front end. A `pikevm`-vs-`backtrack`
  divergence would mean a front-end bug — none has appeared across the campaigns run. That is
  reassuring about that core, not a guarantee: both share the front end, so a bug *there* makes them
  agree on the wrong answer (the external Rust oracle, not this suite, is what catches that class —
  see the cross-engine note above).
- **Minimize before theorizing.** More than one finding was first filed under the wrong root cause
  (e.g. "`\b` combined with `(?m)`") and the greedy minimizer proved the real cause was elsewhere — an
  unconfirmed capture seed; a nullable-alternation empty-loop with no `\b`/`(?m)` in the minimized
  pattern at all. Drop a repro into the deterministic search below *first*.

## Triaging a finding

A failing differential prints the offending pattern and input (the harness also
dumps `pat.hex`/`in.hex`/`tmpl.hex`, so an input with invalid-UTF-8 or unprintable
bytes is reconstructable) and Zig saves the raw fuzzer input under
`.zig-cache/f/crash`. The live fuzzer's input does **not** replay cleanly through
`Smith{ .in = … }` (the linear byte reader consumes differently), so the fastest
path to a minimal repro is a small **deterministic** harness in `conformance.zig`:
a fixed-seed `std.Random` loop over random byte inputs against the failing pattern,
comparing the suspect backend to the Pike-VM oracle — then a greedy byte-deletion
minimizer on the first hit (this turned the `^?\z` and `\b`-over-`0xBA` findings
into 2-byte repros in seconds). Pin the minimized case as a `conformance.zig`
regression before fixing — and decide first whether it is a real divergence or a
**documented contract** (e.g. the ASCII-`\b` byte engines above), in which case the
fix is a harness gate, not an engine change.
