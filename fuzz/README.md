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
for parity), *not* here. As of v0.6.0 ezi follows **RE2/Rust leftmost-first**
semantics uniformly — including the empty-width-loop rule (`(?:|.)+` → `""`,
`(?:a?b??)+` → `"a"`) — so a Rust differential no longer needs to carve out an
empty-loop subset; the two coincide across the full ASCII space.

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
| 5 | **`(?m)` line anchor** non-trailing/under-rep/anchor-mixed/`$^`/in-alternation | `(?m:$\n)`, `(?m:\n$)*`, `(?m:$)\A`, `(?m:$^)`, `(?m:$)\|.` | `complex_line_anchor` (+ `has_line and has_text_*` gate) |
| 6 | `\b`/`\B` with a **lazy repetition** | `a*?\b`, `[^a]+?\B *` → over-matched | `word_boundary_with_lazy_repetition` |

Class 6 was the one the **external Rust differential** caught that the internal
differential had missed (`[^a]+?\B *`). Class 2 stays declined to the Pike VM
(`nullable_alternation_in_repetition`), but **v0.6.0 changed what that means**: ezi no
longer follows JS empty-loop semantics — the Pike VM is now uniformly RE2/Rust leftmost-first
(`(?:|.)+`→`""`, the `(\|a)*`→`""` tiebreaker), so the decline is a routing detail, not a
semantic divergence. (A 2M `--fuzz` run for this work confirmed the byte DFA still cannot
reproduce that priority for a complex nullable alternation —
`(b*)(?:b{0}(?:\n*)|.{2}(?:(){0}))+` — so the decline must stay.) The capture, iteration,
Unicode, and strategy-invariance targets (5–8) found **0** divergences in 150k-trial
campaigns each — the capture engines, iterator, Unicode handling, and results-invariance
contract are solid.

The campaign is a permanent target (#4, `genAnchors`); it is **fuzzing-only** (a
no-op under plain `zig build test`, so CI stays green) and active under `--fuzz`, so
it keeps watch for regressions and new classes. Re-run the catalogue with the
deterministic search described under *Triaging* below.

A later 1.5M-run `--fuzz` campaign surfaced one more class-5 sub-shape the first
catalogue missed: `(?m:$^)` (a `line_end` immediately **followed by** a `line_start`)
over `""` — zero-width, yet the eager DFA can't carry both line contexts at one
offset, while the natural `^$` order is fine. Fixed by widening `complex_line_anchor`
to flag a `line_start` with a `line_end` before it on the match path (pinned by
`(?m:$^)` / `(?m:$$^)` conformance regressions, with `(?m)^\w+$` as the `^…$` control).

The **general** differential (target #2) then caught a deeper, pre-existing core bug
unrelated to the DFA gate: an **unbounded** outer repetition over a **nullable
unbounded** body (`b(){5,}|(?:[cc]*?){3,}.`) made the *Pike VM itself* over-consume —
`(?:c*?)+.` matched `"cc"`, leftmost-first (Rust/RE2) says `"c"`. Here the Pike VM was
wrong (it matched neither Rust's `"c"` nor V8's `"ccc"`), so declining to it would have
enshrined a wrong answer; instead the nesting is collapsed in HIR
(`astNullableRepBody` + `widenBodyRepToUnbounded`: `(S*)* ≡ S*`), fixing all backends at
once. Spans **and** capture slots were cross-checked against Rust `regex` before landing.
(Empty-*alternation* nullable bodies — `(?:|a)+` — follow the same RE2 empty-width-loop rule
since v0.6.0: `(?:|.)+`→`""`; they stay routed to the Pike VM via
`nullable_alternation_in_repetition`, which is now leftmost-first correct. Bounded-lazy
*single-rep* inners are a later finding fixed by the same collapse — see below.)

A follow-up 2M-run campaign then found one more class-5 sub-shape: a `(?m)` line anchor
**inside an alternation branch** (`(?m:b{0,2}$)|(\n+|).?` over `"\n\n"`) — the branch
matches empty leftmost-first at offset 0, but the DFA's line model can't priority-order
that zero-width branch against the consuming sibling, so it took the longer branch
(`[0,2)`). The line analogue of class 1 (`\b`-in-alternation); folded into
`complex_line_anchor` (flag a `line_start`/`line_end` reached through an alternation),
pinned by a conformance regression with `(?m)^\w+` / `(?m)\w+$` controls.

A further 3M-run campaign found a new `\b` class: **two adjacent consuming repetitions +
a trailing `\b`** (`\n+(\n.*){0,2}\b` over `"\n\nab"`). The leading `\n+` overlaps the
`(\n.*){0,2}` body, so the boundary can hold at an early (greedy-`\n+`-first, `{0,2}`)
end and a later (`{0,4}`) one; leftmost-first takes the early end, the longest-match byte
DFA the late one. A new flag `word_boundary_with_adjacent_repetition` declines it; a
single rep tight against the boundary (`\b\w+\b`, `\w*\b`, `.*\b`) is unambiguous and
stays DFA-routed (verified). Pinned by a conformance regression.

A 5M-run campaign (iteration target #6) then found the empty-width-loop bug recurring for
a **bounded** lazy inner: `(?i:[cca-c1]??){3,}` (and minimal `(?:a??){3,}`) — the Pike VM
over-consumed (`"aaa"`) where Rust gives `""`. The byte DFA was already correct here, so
this was a Pike VM bug, not a routing one. Since `(S??){3,} ≡ S*?` (repeating a nullable
optional = a star), it folds into the **same HIR collapse** — broadened from "unbounded
inner" to "any nullable inner" (`astNullableRepBody`, widening the body to unbounded),
which fixes every backend at once. Spans and captures re-checked against Rust.

### Fixed in v0.6.0: empty-width loop over a nullable *concat* body

A 5M-run campaign surfaced the empty-width-loop bug's last form: an unbounded outer over a
nullable **concat** body with a lazy part — `(?:a?b??)+`, `(?:a??b??)+`. The Pike VM (and
backtracker, onepass) over-consumed (`(?:a?b??)+` on `"ab"` → `"ab"`); Rust/RE2 give the
leftmost-first `"a"`. The HIR collapse could not reach it — a concat body is not a single
repetition to widen. **Fixed in v0.6.0 by the general empty-width-loop guard**: a loop-back
that closes an empty iteration routes to the loop exit at the empty path's priority. It lives
in every epsilon closure — the pikevm/backtrack/onepass `.jmp` handlers, and `byte.zig`'s
do-while loop shape for the byte DFAs (`dfa`/`edfa`/`bytepike`). Triage during this work also
showed the byte DFAs over-consumed the **capturing** form (`(a?b??)+`, the `save` forced the
buggy loop shape) — also fixed. Now **every backend agrees** (`empty_loop_concat_cases` pins
pikevm + backtrack + auto; the byte engines are pinned via their eligible-subset tests).

### Fixed in v0.6.0: `\b`/`\B` after a length-varying alternation

A ~10M-cumulative anchor campaign surfaced the eager-DFA class: a `\b`/`\B` *following* an
alternation with **overlapping, length-varying** branches (`(b+|.+)\B` over `"baaa"`).
Leftmost-first tries `b+` first → `"b"`; the **eager** byte DFA took the longer `.+` branch
→ `"baa"`. The `pikevm`/`backtrack`/lazy-`dfa` were correct. **Fixed in v0.6.0** by declining
the shape from the eager arm only (`hir.Analysis.word_boundary_after_varying_alternation`,
gated in `edfa.supports`): `auto` then serves it on the leftmost-first-correct path and the
lazy `dfa` stays eligible. Disjoint-first alternations (`(?:b+|a+)\B`, `\b(foo|bar)\b`) are
unambiguous and stay on the eager DFA fast path. Pinned by `word_boundary_after_alt_cases`.

### Fixed in v0.6.0: `\b`/`\B` inside a repetition

A later anchor campaign found a sibling eager-DFA `\b` shape: a boundary **lexically inside a
repetition** (`(b.{0,2}\B)+` over `"bbbab…"`). The repeated body makes the boundary's end ambiguous
across iterations; leftmost-first is `"bbb"`, the eager DFA took `"bbbab"`. The
`pikevm`/`backtrack`/lazy-`dfa` were correct. **Fixed in v0.6.0** by declining a boundary under a
repetition from the eager arm (`hir.Analysis.word_boundary_in_repetition`, gated in
`edfa.supports`). A top-level boundary (`\b\w+\b`, `\bthe\b`) is not inside a repetition and stays
on the eager DFA. Pinned by `word_boundary_in_rep_cases`.

## Triaging a finding

A failing differential prints the offending pattern and input and saves the raw
fuzzer input under `.zig-cache/f/crash`. The live fuzzer's per-call-site decision
log does **not** replay cleanly through `Smith{ .in = … }` (the linear byte
reader consumes differently), so the fastest way to a minimal repro is a small
deterministic random search + greedy char-deletion minimizer against the three
backends — the Pike VM being the oracle. Pin the minimized case as a conformance
regression before fixing.
