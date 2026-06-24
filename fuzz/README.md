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

### Fixed: eager/lazy DFA `isMatch` disagreed with its own `find` (`^?\z`)

The hardened **`isMatch == (find != null)`** invariant (added with the full-backend
differential) immediately caught an eager/lazy-DFA bug the old harness could not see:
`^?\z` over `""` (or `"ab"`, `(?:^)?\z`, `^?$`) — `find` correctly matched the empty span
at the end anchor, but `isMatch` returned **`false`**. Root cause: an *optional* line-start
`^?` leaves the program `has_text_end` but **not** `end_anchored`; `dfa.isMatchImpl` only
routed `end_anchored` text-end programs through the reverse automaton and otherwise fell to
`runUnanchored`, which can never accept a text-end program (no mid-input `match` state).
**Fixed** by routing *every* `has_text_end` program through the reverse automaton in
`isMatchImpl`, mirroring `searchImpl` exactly (all arms O(input)). Pinned by
`regression: dfa isMatch agrees with find for optional-^ end anchors (^?\z family)`.

### Clarified (not a bug): ASCII-`\b` byte engines vs Unicode-`\b` on non-ASCII

The replace/iter differential flagged `bytepike` diverging from the Pike VM on a `\b`
pattern over a non-ASCII byte (`…|\b.|…` over `{0xBA,'l'}`): the byte engine sees a word
boundary at the non-word *byte* `0xBA` and matches `\b.`, while the code-point engines decode
`0xBA` → U+FFFD and take the empty branch. This is the **documented ASCII-`\b` contract**, not
an engine bug — `auto` routes a non-ASCII `\b` to the code-point engines, so a *pinned* byte
engine is only contracted on ASCII input. The harness now gates the byte engines on such cases
(`byteEnginesSafe`); pinned by `regression: non-ASCII \b — code-point engines agree; byte
engines may differ (by design)`.

### Pending — found, not yet fixed (`\b`/`\B` combined with `(?m)` line anchors)

The hardened suite's full-backend sweep surfaced two **open** divergences in the `\b`/`\B` +
`(?m)`/line-anchor family (where `auto`'s "route a boundary mixed with `$`/`(?m)` to the Pike VM"
rule is evidently incomplete). **Not yet fixed** — recorded here for a later round; both are
deterministic, minimal-ish, and print a hex repro.

1. **`auto` capture over-matches `(?m)^\b` on `""`.** `/(?m)^\b/` over the empty string: the Pike
   VM reports **no match** (at offset 0 there is no word character adjacent, so `\b` fails), but
   `auto` reports a match. A capture (and `find`) divergence.
   - `pat.hex=283f6d295e5c62` (`(?m)^\b`), `in.hex=` (empty input).
2. **`bytepike` span differs on an anchor-soup pattern over newline-rich input.** A pattern dense
   in `\b`/`\B`/`$`/`\z`/`(?m)` quantified zero-width assertions —
   `($+\A{0}(?:\b$+\B{0})+|\B{0,2}\A+|\b+)*(?:\z{0,2}\b*b+|$?|.?\z{0,2}(?m:$?b*(?m:^{0}\z|$*\B+){0,2}|b+(?:)|)*)+||`
   — yields a different span on `bytepike` than on the Pike VM.
   - `pat.hex=28242b5c417b307d283f3a5c62242b5c427b307d292b7c5c427b302c327d5c412b7c5c622b292a283f3a5c7a7b302c327d5c622a622b7c243f7c2e3f5c7a7b302c327d283f6d3a243f622a283f6d3a5e7b307d5c7a7c242a5c422b297b302c327d7c622b283f3a297c292a292b7c7c`
   - `in.hex=6261610a6161616162620a61620a0a0a62610a62610a` (`"baa\naaaabb\nab\n\n\nba\nba\n"`).

Likely the same root area — the eligibility gate for routing a `\b`/`\B` that co-occurs with a
`(?m)` line anchor (and quantified zero-width anchors) onto the Pike-VM / code-point path rather
than a byte engine. To reproduce, drop each into a `conformance.zig` deterministic search +
greedy minimizer (see *Triaging* below) comparing the named backend to the Pike-VM oracle.

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
