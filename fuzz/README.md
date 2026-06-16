# ezi_gex fuzzing

Coverage-guided fuzz targets built on Zig's `std.testing.fuzz` + `Smith`
(structure-aware input generation, Zig ≥ `0.17.0-dev.864`). The harness drives
the **published `ezi_gex` module** exactly as a downstream user would — it never
reaches into internals — so what it exercises is the real public surface.

## Files

| File | What it is |
|------|------------|
| `root.zig`          | The fuzz unit: eight `std.testing.fuzz` targets + seed corpora. |
| `pattern_smith.zig` | Three `Smith`-driven pattern generators — `gen` (general ASCII), `genAnchors` (anchor/zero-width-heavy), `genUnicode` (`\p{}`/scripts/multi-byte/folding) — so the fuzzer spends its budget on the parser/HIR/backends, not lexer error-recovery. |

## Running

These tests are **finite by default** and double as ordinary unit tests:

```sh
zig build test-fuzz                 # finite: replays the seed corpus + an empty input
zig build fuzz                      # alias for the same finite smoke run
zig build test                      # the `fuzz` unit runs as part of the aggregate
```

To actually fuzz, add `--fuzz` — **always bound it with `=N`:**

```sh
zig build fuzz --fuzz=200000        # ~200k iterations, then stop
zig build fuzz --fuzz=2M            # K / M / G suffixes accepted
zig build test-fuzz --fuzz=1M       # same, naming the unit explicitly
```

> ⚠️ **Bare `zig build test --fuzz` (no `=N`) runs forever**, across *every* test
> binary, until you Ctrl-C it. That is a soak run by design — not a hang. For a
> bounded session always use `--fuzz=<N>` and target `fuzz` / `test-fuzz` so you
> only instrument this one binary.

Each iteration is intentionally cheap — generated patterns are capped at
`pattern_smith.max_pattern_len` bytes with `{m,n}` bounds ≤ `max_rep_bound`, and
haystacks at `max_input_len` — so the fuzzer makes **steady forward progress**
rather than stalling on one pathological case. A typical bounded run reports
rising coverage and unique-run counts; if it ever appears stuck, it is almost
certainly a bare (unbounded) `--fuzz` doing exactly what was asked.

## What the targets cover

1. **`fuzz: parseWith never crashes on arbitrary bytes`** — arbitrary fuzzer
   bytes as a pattern, with a fuzzer-chosen `max_repetition`, through `parseWith`.
   The only sanctioned outcomes are a clean AST or `error.InvalidPattern` with a
   located diagnostic — never a panic, UB, or a leak (the testing allocator
   checks the last).
2. **`fuzz: pikevm / backtrack / auto agree on structured patterns`** — the
   differential target. A `PatternSmith` pattern is matched against a generated
   haystack on the Pike VM, the bounded backtracker, and the `auto` dispatcher;
   all three must agree on validity and, when valid, on a **byte-identical**
   leftmost-first span. The Pike VM is the reference. (This is the target that
   surfaced the `\b`-in-alternation `auto` bug fixed in 0.5.0.)
3. **`fuzz: repetition limit accept/reject is exact`** — the new `{m,n}` ceiling.
   For a random `(min, max?, limit)` triple it builds `a{…}` and checks the
   scanner's accept/reject decision (and the exact diagnostic code) against the
   documented rule: an over-limit bound → `quantifier_exceeds_limit` (checked
   first), else `min > max` → `quantifier_out_of_order`, else accept.
4. **`fuzz: anchors/zero-width agree …`** — the focused supports-gate differential
   (`genAnchors`: `^ $ \A \z \b \B (?m:…)`, empty branches, nullable quantifiers)
   over newline-rich inputs. The target that catalogued the DFA-gate family below.
5. **`fuzz: capture slots agree …`** — full capture-slot arrays (every group, not
   just the whole-match span) across pikevm / backtrack / auto / onepass.
6. **`fuzz: findAll sequence + count agree …`** — the non-overlapping match
   *sequence* agrees across backends, and `count` equals it (empty-match advance).
7. **`fuzz: Unicode patterns agree …`** (+ `\X` no-crash) — `genUnicode` patterns
   (`\p{}` / scripts / multi-byte literals / `(?i)` folding) over BOTH valid
   multi-byte UTF-8 and raw (often invalid) bytes; `\X` graphemes are fuzzed for
   no-crash on the backtracker (their only backend).
8. **`fuzz: strategy-tier flags never change the match`** — flipping any
   `Options.strategy` field (`byte_engine` / `prefilter` / `simd`) must never alter
   the span. Pins the results-invariance contract.

## A note on cross-engine (external-oracle) differential

The targets above diff ezi's own backends, which **share** the scanner → AST → HIR
→ nfa front end; a bug *there* makes all of them agree on the wrong answer. Diffing
against an **independent** engine (Rust `regex`, RE2-lineage) catches that
shared-front-end class — and did once: `word_boundary_with_lazy_repetition`
(`[^a]+?\B *`) was found that way, not by the in-process targets.

That is a **cross-language comparison activity, not a library concern**, so it lives
in the sibling **`regex-bench`** project (which already builds ezi against Rust/Go
for parity), *not* here. Caveat for anyone running it: ezi follows *JS* empty-loop
semantics and Rust *RE2*'s, so a meaningful differential must restrict its generator
to the subset where the two provably coincide (quantifiers only on consuming leaves,
no empty alternation branches, ASCII inputs) — otherwise the known semantic
differences read as false "disagreements".

## Findings so far

The differential targets surfaced a family of `auto`/byte-DFA bugs where the
leftmost-**longest** span DFA disagreed with the leftmost-**first** Pike VM (the
oracle). A focused 400k-trial supports-gate campaign (`genAnchors` + deterministic
search + greedy minimizer) catalogued **31 distinct minimized divergences and zero
`pikevm != backtrack`** — i.e. the shared NFA core is solid; every bug was in the
byte-DFA span path / `auto` routing, in the `dfa`/`edfa` `supports` gate for anchors
and zero-width constructs. The default smoke run (`zig build test`) stayed green
throughout — it replays only simple seeds.

**All classes are fixed (v0.5.0)** — each by declining the shape to the Pike VM via
an `hir.Analysis` flag gated in `dfa`/`edfa.supports` (correct + linear there);
re-runs of both the campaign and the external Rust oracle now find **0** divergences.
Each is pinned by a conformance regression with controls proving the benchmarked DFA
fast paths stay eligible.

| # | Class | Repro (`auto` was wrong) | `hir.Analysis` flag |
|---|-------|--------------------------|---------------------|
| 1 | `\b`/`\B` **inside** an alternation | `\b\|.` on `"b"` → `{0,1}`, want `{0,0}` | `word_boundary_in_alternation` |
| 2 | repetition over a **nullable alternation** | `(?:\|.)+` on `"c"` → `{0,0}`, want `{0,1}` | `nullable_alternation_in_repetition` |
| 3 | **non-trailing** `$`/`\z` (incl. nullable middle, trailing text_start) | `$b$`, `\z.?\z`, `$^\z` wrongly matched | `interior_text_end` |
| 4 | `\b`/`\B` **adjacent to** a nullable alternation | `\B(?:\|.*)` on `"ab"` → `{1,2}`, want `{1,1}` | `word_boundary_with_nullable_alternation` |
| 5 | **`(?m)` line anchor** non-trailing/under-rep/anchor-mixed | `(?m:$\n)`, `(?m:\n$)*`, `(?m:$)\A` | `complex_line_anchor` (+ `has_line and has_text_*` gate) |
| 6 | `\b`/`\B` with a **lazy repetition** | `a*?\b`, `[^a]+?\B *` → over-matched | `word_boundary_with_lazy_repetition` |

Class 6 was the one the **external Rust oracle** caught that the internal differential
had missed (`[^a]+?\B *`). Class 2's direction came from a cross-engine study:
ezi_gex follows **JS** empty-loop semantics (the `(\|a)*`→`"aaa"` tiebreaker;
RE2/Rust/Go/Python/Perl return `""`), so the consuming branch must win — which the
Pike VM/backtracker already do. The capture, iteration, Unicode, and
strategy-invariance targets (5–8) found **0** divergences in 150k-trial campaigns
each — the capture engines, iterator, Unicode handling, and results-invariance
contract are solid.

The campaign is a permanent target (#4, `genAnchors`); it is **fuzzing-only** (a
no-op under plain `zig build test`, so CI stays green) and active under `--fuzz`, so
it keeps watch for regressions and new classes. Re-run the catalogue with the
deterministic search described under *Triaging* below.

## Triaging a finding

A failing differential prints the offending pattern and input and saves the raw
fuzzer input under `.zig-cache/f/crash`. The live fuzzer's per-call-site decision
log does **not** replay cleanly through `Smith{ .in = … }` (the linear byte
reader consumes differently), so the fastest way to a minimal repro is a small
deterministic random search + greedy char-deletion minimizer against the three
backends — the Pike VM being the oracle. Pin the minimized case as a conformance
regression before fixing.
