# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

`0.7.0-dev` on `main`.

### Performance

- **Unbounded leading multi-prefix alternations now jump-and-confirm with a reach budget instead of
  a full DFA pass.** A top-level alternation whose branches each begin with a literal but are
  separated by an *unbounded* gap — `Holmes(?:\s*.+\s*){0,10}Watson|Watson(?:\s*.+\s*){0,10}Holmes`
  (rebar `holmes-coword-watson`) — extracts a sound leading prefix set (`{Holmes, Watson}`) and is
  not bounded-confirmable, so the lazy-DFA arm skipped to the *first* prefix occurrence and then ran
  **one native pass over the whole input** — O(input × states) over the two-branch `.+` program. The
  single-`prefix` arm already had the right shape (jump literal-to-literal via the multi-literal
  prefilter, confirm anchored at each with a `dfa.confirmReach` budget that abandons to the native
  find on overrun); this gives the **multi-prefix** arm the same loop, sound because every match
  begins at a prefix occurrence (`off == 0`, so `cand == hit` stays leftmost-first). On an Apple M4
  `holmes-coword-watson` goes **65 → 813 MB/s (21× → 1.7× vs `rust/regex`)**, rebar Sherlock geomean
  **1.69 → 1.56**. `\b` programs and non-leading sets (`off_max > 0`, where `hit − d` is not
  monotonic) keep the single-skip + native pass. Pinned by a `conformance.zig` regression
  (Pike-VM-oracle leftmost-first across both branch orders, a leftmost-across-order case, greedy
  span, no-match) and the rebar/regex-bench count cross-checks.
- **Gate the SIMD movemask behind a cheap any-hit reduce on targets without a native movemask
  (aarch64 NEON).** The single-literal `memmem`, the multi-literal `teddy`, and the leading-class
  `classscan` scanners all locate candidate lanes by `@bitCast`-ing an N-lane `@Vector(N, bool)`
  to an N-bit integer. On x86-64 that is one `pmovmskb`; **aarch64 NEON has no movemask**, so LLVM
  emulates it with a multi-instruction shift-narrow-reduce that was paid on *every* 16-byte chunk —
  including the overwhelming majority that contain no hit. New `simd.cheap_movemask` (true only on
  x86-64) gates each scan: on NEON it first asks the cheap question "did **any** lane match?" via
  `@reduce(.Or, …)` (one `umaxv`) and pays the emulated movemask only on a chunk that actually hit;
  on x86 the comptime branch drops the test entirely. Speed-only — every surviving candidate is
  still fully verified, so no result changes (pinned by each module's exhaustive differential and a
  new empty-chunk regression). On an Apple M4 this restores the literal- and class-scan throughput
  the engine is designed for: rebar Sherlock geomean **4.30 → 1.69** vs `rust/regex`; on
  `regex-bench` (median) **`\d+`/`\p{N}+` on `sherlock` ~5× faster** (4.7 → 23 GB/s), single-literal
  scans (`Sherlock`, `Holmes`, `\w+\s+Holmes`) **~6-13× faster**, overall geomean **1.31 → 1.10**.
  The residual gaps are the documented [`limitations.md`](docs/limitations.md) trade-offs (a
  hand-tuned-SIMD literal-throughput gap, an unbounded literal gap, …) and the non-ASCII
  Unicode-class decode path.

## [0.6.1] - 2026-06-27

A correctness patch. The hardened, parallel fuzz suite (`fuzz/`) and its full-backend differential
surfaced a family of cross-backend divergences — almost all in the byte-DFA span path and the `auto`
dispatcher, none in the shared NFA core — each now fixed and pinned by a `conformance.zig` regression
whose controls keep the benchmarked fast paths eligible. The comptime build path shares the same
`hir.analyze` flags and backend `supports` gates, so it inherits every fix (pinned by comptime parity
regressions); none of these divergences was reachable through the comptime path in the first place
(no lazy DFA at comptime; `auto` routes the priority-sensitive shapes to the Pike VM there).

### Fixed

- **`edfa` lost leftmost-first for a `(?m)$` line-end after a nullable alternation
  (`(?m:(?:|\n)$)`).** A `(?m)$` `line_end` immediately preceded by a nullable alternation is a
  leftmost-first priority inversion the eager longest-match DFA can't hold: the alternation prefers
  its empty branch (shorter), but a `(?m)$` *also* holds after a consuming branch's `\n` (which lands
  on the next line end), so the DFA took the longer branch — `(?m:(?:|\n)$)` over `"aaa\n\n"` is the
  empty `{3,3}` yet `edfa`/`auto` returned `{3,4}`. The existing `complex_line_anchor` gate didn't
  cover it (the `line_end` is trailing and outside the alternation; the nullable alternation sits
  *before* it). Fixed with a dedicated gate, `hir.Analysis.line_end_after_nullable_alternation`,
  declined by `edfa.supports` — the line analogue of `word_boundary_with_nullable_alternation`; the
  lazy `dfa` already declines every `line_end` and the code-point engines are correct, so `auto`
  routes the shape to the Pike VM. A *greedy* optional/repetition before `$` (`\n?$`, `.*$`,
  `[\n ]*$`) is unaffected — greedy prefers the long match too, matching the DFA. This shape also
  reached the **comptime** path (`edfa` runs at comptime); the shared `hir.analyze`/`supports` fix
  corrects it there too. Surfaced by the fuzz anchors differential; pinned by a `conformance.zig`
  regression (runtime + comptime, with greedy/mandatory accept controls).
- **Lazy `dfa` bypassed its leftmost-first decline gates behind a leading `(?m)^`
  (`(?m:^)b*(?m:a||b*)+`).** `dfa.supports` checks a family of priority-correctness flags
  (nullable-alternation-in-repetition, `\b`-in-alternation, …) that the leftmost-**longest** byte
  DFA cannot encode — but only on its fall-through path. The `(?m)^` line-anchored fast path (a
  single leading `line_start`) and the trailing-anchored `$` path `return` earlier and never
  reached them, so a priority-sensitive body slipped through: `(?m:^)b*(?m:a||b*)+` over `"ab\n"`
  is `"a"` (`{0,1}`, leftmost-first) but the lazy DFA took the line arm and returned `{0,2}` for
  the nullable alternation in the `+`. Fixed by hoisting the priority-correctness flags above every
  anchor-shape early-return in `dfa.supports`; `auto` then routes the shape to the Pike VM
  (correct + linear). Over-declining only forgoes the fast path — the `log_line`-style
  `(?m:^)\w+[^"]*` shape it exists for has no such flag and stays eligible. Surfaced by the fuzz
  anchors differential; pinned by a `conformance.zig` regression (with a `(?m:^)\w+` accept
  control).
- **`edfa` lost leftmost-first priority for a `\b`/`\B` reached *through a consumer* after a
  varying alternation (`(?:ba()|b+)*.\B`).** The `word_boundary_after_varying_alternation` gate's
  "boundary follows" detector (`boundaryFollowsInConcat`) stopped at the first mandatory consumer
  between the alternation and the boundary, on the assumption that the consumer pins the
  alternation's end and removes the ambiguity. The fuzz differential disproved that: a fixed-length
  `.` only *shifts* where the boundary lands, so the overlapping-first ambiguity survives —
  `(?:ba()|b+)*.\B` over `"bbabb"` has a leftmost-first second span of `{3,4}`, but `edfa` returned
  `{0,4}`. Fixed by having the detector see through **any** mandatory consumer (fixed or varying);
  the gate is reached only behind a rare overlapping-first alternation and forgoes only the eager
  arm, so over-declining costs no correctness. This was previously logged as a known open
  divergence; it is now closed. Surfaced by the fuzz anchors differential; pinned by a
  `conformance.zig` regression (with a disjoint-first `(?:a+|c+)*.\B` accept control).
- **`edfa` lost leftmost-first priority for a `\b`/`\B` after a repetition over a varying
  alternation (`(?:.|b\n)*\b`).** When a word boundary immediately follows a repetition whose body is
  a length-varying, overlapping-first alternation, the body can end at several offsets and the
  boundary holds at more than one; leftmost-first takes the earliest (branch-priority) end, but the
  eager longest-match DFA took the latest — `(?:.|b\n)*\b` over `"b\na"` is `"b"` (`{0,1}`) yet `edfa`
  returned `{0,3}`. This is the same eager-DFA loss the `word_boundary_after_varying_alternation` gate
  already covers when the boundary follows the alternation *directly*; the alternation under a `*`/`+`
  slipped past because the detector (`alternationThroughWrap`) saw through a capture but not a
  repetition. Fixed by having it see through a repetition too, so `edfa.supports` declines and `auto`
  routes to the lazy `dfa`/Pike VM (both leftmost-first correct). Over-declining only forgoes the
  eager arm, never correctness. Surfaced by the fuzz anchors differential; pinned by a
  `conformance.zig` regression (with a disjoint-first `(?:a+|b+)*\b` accept control).
- **`auto`'s rare interior-anchor prefilter missed matches over non-ASCII / invalid-UTF-8 input
  (`[^]]+\}`, `\s*\|+`).** The lazy-DFA arm's rare single-byte-anchor fast path (`runByteDfa`'s
  `confirmReach` loop) reverse-walked the match start over `inner_lead`, a byte-level alphabet that is
  only *exact on ASCII* (bytes ≥ 0x80 are a conservative superset), then confirmed **anchored** at
  that single position. Over non-ASCII input the walk over-reaches past the true start to a byte the
  leading class cannot actually consume, the anchored confirm fails, and the loop gave up — `[^]]+\}`
  over `"\x80a}"` is `{1,3}` and `\s*\|+` over `"\x80|"` is `{1,2}`, but `auto` returned **no match**
  (every backend run *directly* was correct; only `auto`'s pre-backend fast path missed). The sibling
  `bounded_confirm` arm was already `input_ascii`-gated for this reason; the rare-anchor arm wasn't.
  Fixed by adding the `input_ascii` gate — non-ASCII falls to one skip + an **unanchored** native find
  (leftmost-correct regardless of over-reach). Surfaced by the fuzz iter/diff differentials over
  invalid UTF-8; pinned by a `conformance.zig` regression (with an all-ASCII control that keeps the
  fast anchored-confirm path).
- **`auto` line-anchored capture path reported a false match (`(?m)^\b` over `""`).** For a
  `(?m)^…` pattern with no eager-DFA span arm (one bearing `\b`, say), `auto`'s capture search
  (`lineAnchoredCaptures`) seeded the capture-fill helper with an **unconfirmed** `{pos,pos}`
  candidate at each line start; for a **group-less** pattern that helper trusts the seed as the
  match and never runs the engine, so a trailing assertion that *fails* at the line start (the `\b`
  in `(?m)^\b` over `""`/`"\n\n"`) was never checked — `captures`/`find` reported a match where
  `isMatch`/`search` (which do confirm) correctly found none. Fixed by confirming the match at each
  candidate line start with an anchored capturing run (`confirmCapturesAnchored`). Surfaced by the
  fuzz full-backend capture differential; pinned by a `conformance.zig` regression (with positive
  controls — `(?m)^\bx`, `(?m)^\b\w` — that exercise the same path and must still match).
- **`bytepike` mismatched the Pike VM on a repetition over a nullable alternation.** The byte
  Thompson NFA executes the **same byte program** as the byte DFAs, so it shares their structural
  limit (`hir.Analysis.nullable_alternation_in_repetition`): the split-based loop shapes in
  `byte.zig` cannot encode the leftmost-first **empty-width-loop** priority when the preferred
  (earlier) branch matches empty and a later branch consumes — `(?:z*b*$?|.{2})+` over `"baa"` is
  `"b"` (leftmost-first), but `bytepike` returned `"baa"`. `dfa`/`edfa` already decline this class
  in `supports`; `bytepike` was missing the gate. Fixed by declining it in
  `bytepike.buildAlloc`/`buildComptime` (`byteLoweringSupports`) — `auto` and the code-point engines
  (`pikevm`/`backtrack`/`onepass`, via `nfa.zig`'s empty-loop `.jmp` guard) are leftmost-first
  correct and `auto` routes there. A nullable *concat* body (`(?:a?b??)+`) is a different shape that
  the do-while loop handles correctly and is **not** declined. Surfaced by the fuzz span
  differential; pinned by a `conformance.zig` regression (with the `(?:a?b??)+` accept control).
- **Spurious zero-width match mid-code-point over valid UTF-8 (`backtrack`, `dfa`, `edfa`,
  `bytepike`).** Each backend's unanchored scan advanced start positions **byte-by-byte**, so over
  a valid multi-byte code point it attempted a match at an *interior* byte and a zero-width pattern
  could match there — e.g. `\B{4}` over U+AAE9 (`ea ab a9`) matched `(2,2)`, and `\b`/`()`/`\z{0,2}`
  over multibyte input started mid-code-point — where the Pike VM correctly only considers
  code-point boundaries (offsets 0 and 3, both word boundaries here, so no match). Fixed by
  advancing every unanchored scan to the next **code-point boundary**
  (`+= nfa.decodeAt(input, s).len`, as `pikevm`/`onepass` already do; `bytepike` seeds its thread-set
  start only at code-point offsets). ASCII and invalid lead bytes still advance one byte, so
  byte-level scanning of invalid UTF-8 is unchanged. Surfaced as `pikevm`≠`backtrack`/`auto`
  `find`/`findAll`/`captures`/`replace` divergences by the hardened fuzz suite; pinned by two
  `conformance.zig` regressions (the bare backtracker case and the byte-engine multibyte sweep).
- **Byte DFA `isMatch` disagreed with its own `find` on two anchored-program shapes.** In both,
  `find` matched the empty span at the anchor but `isMatch` returned `false`. Surfaced by the new
  fuzz `isMatch == (find != null)` invariant; each pinned by a `conformance.zig` regression.
  - **Lazy DFA, a non-`end_anchored` trailing assertion** — a `text_end` (`$`/`\z`) program
    reached via an *optional* line-start `^?` is `has_text_end` but not `end_anchored` (e.g.
    `^?\z`, `(?:^)?\z`, `^?$`). `dfa.isMatchImpl` only routed `end_anchored` programs through the
    reverse automaton and otherwise fell to `runUnanchored`, which can never accept a text-end
    program (no mid-input `match` state). Fixed by routing **every** `has_text_end` program through
    the reverse automaton, mirroring `searchImpl`.
  - **Eager DFA, an interior `text_start`** — `a*^$`, `a*\A$`, `b*^\z`, `(?:a*)^$` over `""`.
    `edfa.isMatch` used the one-pass `utrans` scan for a `prone` program, but that table can't
    carry an interior `text_start` (`\A`/`^` after a consuming prefix — it seeds mid-input
    positions with `text_start=false`). Fixed by gating the one-pass path on `!has_text_start`, so
    such programs use the anchored restart (which evaluates `text_start` per start), mirroring
    `searchImpl`.

### Internal

- **Hardened, parallel fuzz suite** (`fuzz/`). Split into independent per-group binaries that the
  build scheduler runs concurrently (`zig build fuzz --fuzz=N` → every group in parallel, N
  iterations each; plus `zig build fuzz-<group>`). Coverage is broadened to the **full backend
  matrix** — the differential now diffs the Pike VM oracle against `backtrack`, `auto`, `bytepike`,
  **`dfa`, `edfa`**, `onepass`, and `literal` (the DFA family was previously unfuzzed) — with new
  `isMatch == (find != null)`, `findAt` offset/anchored/`span_end`, and `$`-template `replaceAll`
  differentials, an ASCII-`\b` byte-engine gate mirroring `conformance.byteEngineCanRunCase`, and
  richer generators (named groups, inline flags, `\x{}`/`\u{}` escapes, broad-byte inputs). This
  is what surfaced the fixes above.
- **Fuzz generator no longer aborts the `unicode` group.** `pattern_smith.genUnicode`'s depth-0 cap
  still admitted the recursing `(?i:…)` alternative, whose `depth - 1` underflowed a `u8` and panicked
  the group mid-run (a false crash in the harness, not an engine finding). Capped the depth-0 unit
  choice at the non-recursing leaves.

## [0.6.0] - 2026-06-21

A throughput + correctness release. The **prefilter fast path** grew three sound, leftmost-first
start-skips — a **required interior/suffix-literal** `memmem` + structured reverse walk, a
**fixed-offset rare-byte** confirm for bounded patterns, and a **case-insensitive alternation**
ASCII-folding Teddy — taking the rebar Sherlock geometric mean from **2.67 → 1.50** vs `rust/regex`
(several patterns now *faster* than Rust). Correctness: the empty-width-loop work closes the two
remaining **deferred** entries from `docs/limitations.md` (an empty loop over a nullable concat
body, and a `\b`/`\B` after a length-varying alternation) — there are now **no known cross-backend
correctness gaps** — and adopts **uniform RE2/Rust leftmost-first** empty-loop semantics across
every backend. Also: leading-class start-skip for capitalized-word scans and a lazy-DFA
jump-and-confirm for prone leading-literal / rare interior-anchor patterns. **No API changes** from
`0.5.x`; results-invariant for real-world patterns.

### Changed

- **Empty-loop semantics are now uniformly RE2/Rust leftmost-first** (BREAKING for a narrow
  shape). A repetition iteration that matches the empty string terminates the loop on **every**
  backend. Through 0.5.1 ezi deliberately diverged to JS/V8 for a nullable **alternation** body
  (the consuming branch won): `(?:|.)+` on `"c"` returned `"c"`, `(|a)*` on `"aaa"` returned
  `"aaa"`. Those now return `""` (the empty-first branch wins the empty iteration and the loop
  exits), matching RE2/Rust/Go/Python/Perl. A **consuming-first** branch is unchanged: `(a|)+`
  on `"aa"` is still `"aa"`. The former "Empty-alternation loops follow JS, not RE2" deliberate
  limitation is **removed** from the docs. The `nullable_alternation_in_repetition` routing
  (these patterns are served on the Pike VM, not the byte DFA) is **kept** — the priority-ordered
  byte DFA can't reliably reproduce this empty-loop priority (a fuzz repro:
  `(b*)(?:b{0}(?:\n*)|.{2}(?:(){0}))+`) — but it is now a pure routing detail: the Pike VM gives
  the RE2/Rust span, so the result no longer depends on the route.

### Fixed

- **Empty-width-loop over a nullable *concat* body — fixed on every backend** (was a deferred
  limitation through 0.5.1). An unbounded outer repetition over a nullable concatenation with a
  lazy part — `(?:a?b??)+` on `"ab"`, `(?:a??b??)+` on `"ab"` — over-consumed (`"ab"` / `"a"`)
  where leftmost-first (Rust/RE2) gives `"a"` / `""`. The HIR collapse could not reach it (a
  concat body is not a single repetition to widen). Fixed by the **general empty-width-loop
  guard**: a loop-back that closes an empty iteration routes to the loop exit at the empty path's
  priority instead of looping. It lives in every epsilon closure — the `pikevm`, `backtrack`, and
  `onepass` `.jmp` handlers, plus a do-while (test-at-bottom) loop shape for nullable `x*` bodies
  in `byte.zig` that the byte DFAs (`dfa`/`edfa`) and `bytepike` determinize empty-loop-correctly
  (the non-nullable `a*`/`\w*` hot path keeps its leaner jmp shape). Spans and captures
  cross-checked against Rust `regex`; pinned by `empty_loop_concat_cases` across pikevm +
  backtrack + auto.
- **Byte DFAs over-consumed the *capturing* nullable-concat-lazy form.** Surfaced while fixing the
  above: `(a?b??)+` on `"ab"` returned `"ab"` on `dfa`/`edfa`/`bytepike` (a capture forces the
  buggy `x*` loop shape, where the non-capturing form happened to determinize correctly). The
  `auto` engine inherited it for capturing patterns. Fixed by the same do-while loop shape.
- **`\b`/`\B` after a length-varying alternation — fixed** (was a deferred limitation through
  0.5.1; the eager-DFA case where `auto` was affected). `(b+|.+)\B` on `"baaa"` returned `"baa"`
  on the eager byte DFA / `auto`; leftmost-first is `"b"` (the `b+` branch matches `"b"`, `\B`
  holds, the longer `.+` branch is never tried). New
  `hir.Analysis.word_boundary_after_varying_alternation` declines the shape from the **eager** arm
  only (gated in `edfa.supports`); `auto` serves it on the leftmost-first-correct path and the
  lazy `dfa` (decode-hybrid boundary) stays eligible. Disjoint-first alternations (`(?:b+|a+)\B`,
  `\b(foo|bar)\b`, `\bthe\b`) are unambiguous and stay on the eager DFA fast path. Pinned by
  `word_boundary_after_alt_cases`.
- **`\b`/`\B` inside a repetition — fixed** (found by the differential anchor fuzz during this
  work). `(b.{0,2}\B)+` on `"bbbab…"` returned `"bbbab"` on the eager byte DFA / `auto`;
  leftmost-first is `"bbb"` (the repeated body makes the boundary's end ambiguous and the eager DFA
  took the longer one). New `hir.Analysis.word_boundary_in_repetition` declines a boundary that
  sits lexically inside a repetition from the **eager** arm only; `pikevm`/`backtrack`/lazy `dfa`
  were already correct. Top-level boundaries (`\b\w+\b`, `\bthe\b`) are not inside a repetition and
  stay on the eager DFA. Pinned by `word_boundary_in_rep_cases`.

### Performance

- **Case-insensitive alternation Teddy prefilter.** A top-level case-insensitive alternation
  (`(?i:Sherlock|Holmes|Watson)`, `(?i:Sher[a-z]+|Hol[a-z]+)`) previously got **no prefilter at
  all**: case folding turns each branch's leading letters into classes (`S`→`[Ss]`, with `ſ` under
  simple folding), so the fixed-leading-literal `prefix_set` declined and every match fell to a
  case-expanded DFA scanning every byte. The Teddy SIMD prefilter now matches **ASCII-case-
  insensitively** — its nibble masks carry both cases of each letter and verify folds case
  (`teddy.compileFoldAlloc`) — so `auto` synthesises **one needle per branch** of a casei
  alternation (`caseiAlternationSet`) instead of the case-variant set's `2^k` cartesian product,
  keeping an alternation of casei branches inside the `MAX_PREFIX_BRANCHES` budget. Non-ASCII fold
  members of the leading window (`s`→`ſ`, `k`→KELVIN) fan out into extra needles so the set stays a
  sound necessary prefix; the automaton confirm at each hit enforces full Unicode-correct matching
  (Teddy is purely a candidate generator). On `sherlock` (rebar): **`(?i:Sherlock|Holmes|Watson)`
  ~14× → ~1× *faster* than Rust**, **`(?i:Sher[a-z]+|Hol[a-z]+)` ~15× → ~6.4×** (the residual is the
  *unbounded* branch, which still takes the single-skip + native-find arm rather than a per-
  occurrence confirm); overall Sherlock geomean **1.64 → 1.50** vs Rust ~1.16. Leftmost-first
  preserved; O(input). White-box tested (needle sets, fold flag) and differential-tested vs the
  Pike VM oracle over mixed-case prose including a long-s `ſ`.
- **Required-literal prefilter — whole-literal `memmem` skip + structured reverse walk.** A pattern
  with no leading literal but a selective literal in its **interior or suffix** (`\w+\s+Holmes`,
  `[a-zA-Z]+ing`, `[\w.+-]+@gmail\.com`) now drives a prefilter off that literal. New HIR analysis
  `Analysis.required_literal_skip` carries the longest required literal on the mandatory spine, the
  alphabet that may precede it, and — when the atoms before it are **disjoint class-repetitions**
  (`\w+\s+`) — those pre-atoms. `auto` then (a) leaps to the whole literal with SIMD `memmem`
  (selective even when the first byte is common — the `i` of `ing`), and (b) walks the pre-atoms
  **backward to the exact match start** per hit and runs **one anchored confirm there**, so the
  automaton runs only at real candidate starts instead of scanning the gaps. Wins on `sherlock`
  (rebar): **`\w+\s+Holmes` ~13.5×→1.18×** vs the prior build (now ~Rust parity), **`\w+\s+Holmes\s+\w+`
  ~28×→1.27×**, **`[a-zA-Z]+ing` →1.0×**, **`\s[a-zA-Z]{0,12}ing\s` ~10×→1.0×**. The reverse walk is
  ASCII-exact (a Unicode class's high bytes are conservative), so it engages on ASCII-dominant input
  with a per-occurrence pure-window check and a sound flat-reverse-scan fallback for the rare
  non-ASCII window. Leftmost-first preserved (the automaton confirms every candidate); O(input)
  (single `memmem` + bounded reverse walk, no per-occurrence rescan). Differential-tested vs the
  Pike VM oracle over ASCII and accented prose.
- **Fixed-offset rare-byte confirm for bounded fixed-length patterns.** A bounded pattern whose
  match length is fixed and whose only selective feature is a **rare required byte at a fixed offset**
  (`[a-q][^u-z]{13}x` — the `x` 14 code points in) now `memchr`s that byte, walks back the fixed
  number of **code points** (`cpBack`, UTF-8 aware — correct on non-ASCII without an ASCII gate), and
  confirms anchored at the pinned start, one confirm per occurrence, instead of scanning the dense
  leading `[a-q]` class. `repeated-class-negation` on `sherlock` goes from the suite's worst cliff
  (~183× slower) to **~1.4× *faster* than Rust** (`regex`). Gated to a single ≤-`byteFreq`-threshold
  byte in a bounded match; leftmost-first + O(input).
- **Lazy-DFA arm: leading-literal & rare interior-anchor *jump-and-confirm*.** When a prone
  pattern (an unbounded non-accepting run before the first accept) lands on the lazy DFA, `auto`
  used to take one prefilter skip and then a full O(input) native pass. It now **leaps
  literal-to-literal (or rare-anchor-to-rare-anchor) with SIMD `memmem`/`memchr` and confirms
  anchored at each occurrence**, touching far fewer bytes when the prefilter is selective. The win
  shows where the native pass is expensive (a Unicode class to walk) and the prefilter is sparse:
  **`the\s+\p{L}+` ~2.4× faster** on `sherlock` (`regex-bench`, 732µs → ~305µs, now within ~1.2× of
  Rust) and **`[\w.+-]+@…` (email) ~2.1× faster** on `logs` (125µs → ~59µs, now *faster than* Rust
  `regex`). Kept **provably linear** by a `reach` budget: a prone confirm can scan far, so once
  cumulative confirm work overruns ~2×input the loop hands the rest to the native find — no Θ(n²)
  on an adversarial begin-but-don't-complete input (`Scratch.lazy_confirm_bytes`, asserted to grow
  linearly by a revert-failing `redos.zig` guard). The interior-anchor jump is gated on a **rare**
  anchor (byte-frequency heuristic): a common one (`.` in `ipv4`) keeps the single-skip path, so it
  is never slower. New `dfa.confirmReach` (anchored match + furthest offset scanned) backs the
  budget. Results identical to the Pike VM oracle (pinned by `jump_confirm_cases` in
  `conformance.zig`, runtime + the full differential).
- **Leading-class SIMD scan (`classscan`) — shufti per-high-nibble classifier.** The `class_lead`
  prefilter `auto` uses for a class-led pattern (`\p{N}+`, `\d+`, `\d{4}-…`) replaces its
  single-bucket nibble classifier with a **shufti**-style one that gives each distinct UTF-8 high
  nibble its own bucket bit. For a set with **≤ 8 distinct high nibbles** (the common case — `\p{N}`
  has 5, `\d` has 1) the nibble pre-test is now **exact**, eliminating the false-positive confirms
  that dominated a sparse class scan over non-ASCII text. The old single-bucket scheme saturated
  the low-nibble table for a broad lead set like `\p{N}` (lead bytes `30-39 c2 d9 db df e0-e3 ea ef
  f0`), so every Cyrillic lead byte (`0xD0`/`0xD1`) survived to the scalar confirm — half the bytes
  of 2-byte Cyrillic text. **~1.7× faster** `\p{N}+` on `subtitles-ru` (`regex-bench`, 515µs →
  308µs) and ~1.2× on `subtitles-zh`, no regression on the ASCII `\p{N}+`/`\d+` fast paths (still
  exact, ~18 GiB/s on `sherlock`). Correctness is unchanged regardless (every survivor is confirmed
  against the exact bitset); pinned by white-box precision tests in `classscan.zig` and the
  end-to-end `class_lead_nonascii_cases` conformance differential.
- **Leading-class start-skip for capitalized-word scans (`\p{Lu}…`).** A class whose first-byte
  set has a **sparse ASCII lead but a broad Unicode tail** (`\p{Lu}`: `A–Z` plus uppercase across
  dozens of scripts) used to be denied the `class_lead` SIMD skip — its high lead bytes blanket
  non-Latin text — so a capitalized-word scan crawled byte-by-byte. `auto` now scans a **sound
  over-approximation**, `{the class's ASCII members} ∪ {all high bytes}` (`asciiLeadDerived`): every
  match start is one of those, so it never skips a real start. On Latin-script text (where high
  bytes are rare) it skips the lowercase gaps to the next capital — **`\p{Lu}\p{Ll}+` ~1.7× faster**
  on `sherlock` (`regex-bench`, ezi 1123µs → ~660µs, now *faster than* Rust `regex`). The derived
  set engages **only when the input is ASCII-dominant** (high bytes < ⅛ of the input,
  `inputAsciiDominant`); on Cyrillic/CJK text — where every byte is high and the scan can't help —
  the arm falls through to the native find on the **identical code path as before**, so there is no
  regression (`\p{Lu}\p{Ll}+` on `subtitles-ru` unchanged). Results-invariant (pinned by
  `class_lead_derived_cases` in `conformance.zig` against the Pike VM oracle; the gate boundary and
  the over-approximation are locked by `asciiLeadDerived` unit tests in `auto.zig`).
- **Case-insensitive phrase search (`(?i)…`) — rarest-window Teddy prefilter.** For a bounded
  case-variant phrase the `auto` dispatcher now seeds its Teddy prefilter from the **rarest**
  2–3-position window instead of always the leading one (`(?i)sherlock holmes` probes the rare
  `[cC][kK] ` window rather than the common leading `[sS][hH][eE]`, ~2× fewer candidates to
  confirm) — **~1.13× faster** on the `ci_phrase` benchmark (`regex-bench`), no regression on the
  other case-variant cases (`ci_the` ~1.06×). The window sits at a byte-offset **range** from the
  match start (`Filter.prefix_set_off_min/off_max`) so a variable-length fold variant of a
  preceding position (`s`→2-byte `ſ`) is handled soundly; every hit is still fully confirmed, so
  the choice never changes which matches are found (pinned by the conformance differential plus an
  explicit `ſ`-shifted functional test). New `memmem.byteFreq` exposes the byte-frequency model.

### Internal

- Added `hir.Analysis.word_boundary_after_varying_alternation` (with first-set overlap analysis:
  `firstSet`/`firstSetsOverlap`/`alternationBranchesOverlapFirst`).
- `hir.Analysis.nullable_alternation_in_repetition` is retained as a routing gate (see *Changed*);
  its doc no longer frames it as a JS-vs-RE2 semantic divergence.

## [0.5.1] - 2026-06-17

Patch release: leftmost-first correctness fixes for degenerate anchor / empty-width-loop /
`\b` patterns surfaced by the coverage-guided fuzz suite, plus a new `docs/limitations.md`.
Results-invariant for real-world patterns; the benchmarked `\b`/`$`/`(?m)` fast paths stay
DFA-eligible (regex-bench parity unchanged).

### Fixed

- **Empty-width-loop over-consumption.** An **unbounded** outer repetition
  (`*`/`+`/`{m,}`) wrapped around a body that lowers to a **nullable** repetition
  (`S*`/`S*?`, and bounded `S?`/`S??`/`S{0,k}`, optionally captured) over-consumed on
  the Pike VM — `(?:c*?)+.` matched `"cc"`, `(?:c*?){3,}.` matched `"cc"`, and
  `(?:a??){3,}` matched `"aaa"`, where leftmost-first (Rust `regex` / RE2) gives
  `"c"` / `""`. Repeating a nullable repetition any number of times matches the same
  language as one unbounded repetition (`(S*)* ≡ S*`, `(S??){3,} ≡ S*?`), so the
  redundant outer loop is now collapsed in HIR (`astNullableRepBody` +
  `widenBodyRepToUnbounded`), keeping the body's own greediness and consume
  capability (`(?:a*?)+b` → `"aaab"` is intact). The fix is in the shared front end,
  so every backend agrees. Found by the differential fuzzer (`b(){5,}|(?:[cc]*?){3,}.`,
  then `(?i:[cca-c1]??){3,}`); spans **and** capture slots cross-checked against Rust
  `regex`; pinned by conformance regressions with non-nullable/greedy/bounded-outer
  controls. (Empty-alternation nullable bodies — `(?:|a)+` — keep ezi's JS-style
  empty-loop semantics, unchanged.)
- **`(?m)` line-anchor leftmost-first divergences (two more sub-shapes).** Both
  matched on the Pike VM but diverged on the eager byte DFA (`auto`), now declined
  to the Pike VM by a widened `hir.Analysis.complex_line_anchor`; the benchmarked
  leading-`(?m)^` / trailing-`(?m)$` fast paths are unaffected.
  - A `line_end` immediately followed by a `line_start` (`(?m:$^)`, `(?m:$$^)`) over
    an empty/zero-width position — the two line contexts can't be carried at one
    offset by the DFA's anchored-restart + `\n`-lookahead model (the natural `^…$`
    order is fine). Found by a 1.5M-run supports-gate fuzz campaign.
  - A line anchor **inside an alternation branch** (`(?m:$)|.`, `(?m:b{0,2}$)|…`) —
    the branch matches empty leftmost-first at offset 0, but the DFA can't
    priority-order that zero-width branch against a consuming sibling and took the
    longer branch (the line analogue of `\b`-in-alternation). Found by a 2M-run
    campaign. Both pinned by conformance regressions.
- **`\b` with two adjacent repetitions leftmost-first divergence.** A `\b`/`\B`
  preceded by two **adjacent consuming repetitions** whose split is ambiguous
  (`\n+(\n.*){0,2}\b` — leading `\n+` overlapping a `(\n.*){0,2}` body) let the
  boundary hold at an early (greedy-first, shorter) end *and* a later one: the Pike
  VM takes the early end leftmost-first (`{0,2}`), the leftmost-longest byte DFA took
  the late one (`{0,4}`). New `hir.Analysis.word_boundary_with_adjacent_repetition`
  declines it to the Pike VM; a single rep tight against the boundary (`\b\w+\b`,
  `\w*\b`, `.*\b`) is unambiguous and stays on the DFA fast path. Found by a 3M-run
  differential fuzz campaign; pinned by a conformance regression.

### Docs

- Added [`docs/limitations.md`](docs/limitations.md): the deliberate semantic choices
  (JS-style empty-loop ties for empty alternations, `\X` on the backtracker only,
  the bounded `{m,n}` ceiling) and **two deferred** edge cases on pathological patterns,
  each pinned by a conformance test:
  - An empty-width loop over a nullable *concat* body (`(?:a?b??)+`) over-consumes on the
    `pikevm`/`backtrack` backends; the default `auto` is correct
    (`empty_loop_concat_auto_cases`).
  - A `\b`/`\B` after a length-varying alternation (`(b+|.+)\B`) loses leftmost-first
    priority on the eager byte DFA, and so on `auto`; `pikevm`/`backtrack`/lazy-`dfa` are
    correct (`word_boundary_after_alt_ref_cases`).

## [0.5.0] - 2026-06-17

### Added

- **Replace family + iterator/lookup API round-out.** The public surface gains the methods that
  bring it to parity with Rust `regex` / Python `re` / Go `regexp`, on both `Compiled` and the
  agnostic `Engine`. All `@stable-since v0.5.0`, results-pinned by the conformance suite:
  - **`replace`** — rewrite only the **first** match (`re.sub(count=1)` / Rust `replace`).
  - **`replaceN`** — rewrite the first **`n`** matches (`n == 0` copies verbatim).
  - **`replaceAllAlloc`** — replace-all returning an owned `[]u8` (no caller-built `Writer`) — the
    most-requested replace ergonomic.
  - **`replaceAllWith`** — replace-all where a **callback** `fn(ctx, Captures, *Writer)` computes
    each replacement, the escape hatch for replacements the `$`-template DSL can't express.
  - **`capturesAt`** — `captures` with `SearchOptions` (resume at `.start` / `.anchored`), the
    capture-filling peer of `findAt`/`isMatchAt` (closes that asymmetry).
  - **`splitN`** — split into at most `n` pieces (the remainder after `n − 1` separators is the
    final piece) — the `splitn`/`maxsplit` form.
  - **`groupIndex(name)` / `groupName(index)`** — map capture-group names ↔ indices straight from
    the compiled metadata, no match required (Rust `capture_names`, Python `groupindex`).
- **`\b`-wrapped pure-literal O(1) boundary confirm** (`auto`, `Filter.lit_wb_confirm`). When the
  whole pattern is a literal wrapped in leading/trailing word-boundary assertions (`\bthe\b`,
  `the\b`, `\bfoo`, `\Bx\B`), a `memmem` prefix hit already confirms the literal, so the match is
  exactly `[hit, hit+len]` iff two **O(1)** word-boundary checks hold — no anchored automaton walk
  per occurrence. The eager arm uses an ASCII boundary check (`asciiWbAt`, the eager `\b` arm runs
  only on ASCII input); the lazy arm uses a Unicode-correct one (`litWbHoldsU` → `nfa.assertionHolds`,
  decoding the adjacent code points), so `\bthe\b` over prose containing accents (`é`) is fast too.
  New decls (`@stable-since v0.5.0`): `auto.WbAssert`, `Filter.lit_wb_confirm`/`lit_wb_lead`/`lit_wb_trail`.
- **Fixed-offset interior-anchor confirm** (`auto`, `Filter.inner_fixed_off`; `hir.InnerAnchor.lead_fixed_cps`).
  When the leading run before an interior anchor is *fixed-length* (`\d{4}-…` → 4) and the input is
  all-ASCII, the anchor sits a fixed number of bytes into every match, so the prefilter jumps
  anchor-to-anchor (`memchr`) and **bounded-confirms at the pinned start `q - off`** — one confirm per
  occurrence — instead of a reverse-scan + native find that crawls a dash-dense, unselective haystack
  (nginx `- -` placeholders). Non-ASCII input or a variable leading run keeps the sound reverse-scan
  path. New decls (`@stable-since v0.5.0`): `hir.InnerAnchor.lead_fixed_cps`, `Filter.inner_fixed_off`.
- **Line-anchored capture/span dispatch** (`auto`, `Filter.line_anchored`). A `(?m)^…` pattern with no
  eager DFA (too big — `log_line`) now **attempts the match anchored at each line start** (`memchr` the
  next `\n` to skip between lines) for both `count`/`search` (`lineAnchoredSpan`) and `captures`
  (`lineAnchoredCaptures`), instead of a lazy-DFA span pass *plus* a separate capture-fill pass per
  line. One pass per line. New decl (`@stable-since v0.5.0`): `Filter.line_anchored`.
- **Configurable bounded-repetition ceiling** (`Options.max_repetition`, default `100_000`). A finite
  `{m,n}` / `{m}` / `{m,}` bound past the ceiling is now rejected **at scan time** with the new
  `error.InvalidPattern` code `quantifier_exceeds_limit` (a located `@compileError` on the comptime
  path) — a DoS guard so an absurd `a{900000000}` can't blow up the automaton, *before* any
  lowering. The hard u32 overflow (`quantifier_too_large`) still applies above whatever you set.
  Lower it to harden against adversarial input; raise it for genuinely huge counts. New decls
  (`@stable-since v0.5.0`): `Options.max_repetition`, `scanner.Limits`, `scanner.default_max_repetition`
  (= 100_000), `scanWith`, `parseWith`, `parseComptimeWith`, `compileWith`, and the
  `ErrorCode.quantifier_exceeds_limit` diagnostic. The plain `scan`/`parse`/`parseComptime`/`compile`
  are unchanged — each is exactly its `*With` peer at the default limit.
- **Coverage-guided fuzzing harness** (`fuzz/`, `zig build fuzz`). A new, independently-cacheable
  `fuzz` test unit built on Zig's `std.testing.fuzz` + `Smith` (structure-aware input generation),
  driving the published `ezi_gex` surface exactly as a downstream user would. **Eight targets** over
  three `Smith` generators (`gen` / `genAnchors` / `genUnicode`): scanner-never-crashes (arbitrary
  bytes + fuzzer-chosen `max_repetition`); cross-backend **span** agreement (pikevm / backtrack /
  auto); exact `{m,n}`-limit accept/reject; the **anchor/zero-width** supports-gate differential;
  full **capture-slot** agreement (incl. `onepass`); **`findAll` sequence + `count`** consistency;
  **Unicode** (`\p{}`/scripts/multi-byte/folding) over valid *and* invalid UTF-8 (+ a `\X` no-crash
  target); and **`strategy`-tier results-invariance**. The bodies double as finite corpus-replay
  smoke tests under a plain `zig build test`, so CI stays green; `zig build fuzz --fuzz=N` runs a
  bounded coverage-guided session (see `fuzz/README.md`). (A complementary *cross-engine* differential
  against Rust `regex` — which catches shared-front-end bugs the in-process targets structurally
  cannot, and did find `word_boundary_with_lazy_repetition` — is a comparison activity that lives in
  the sibling `regex-bench` project, not in this library.)

### Fixed

- **`auto` lost leftmost-first priority for a `\b`/`\B` alternated with a consuming branch** — found
  by the new differential fuzzer. `\b|.` on `"b"` returned `{0,1}` (`"b"`) instead of the correct
  empty match `{0,0}`: the `\b` branch matches empty at offset 0 and, leftmost-first, must win, but
  `auto` routed the pattern to a byte DFA whose leftmost-**longest** merge can't encode branch
  priority across an assertion. Fixed by declining a `\b`/`\B`-inside-an-alternation to the Pike VM
  (correct + still O(input)), via the new `hir.Analysis.word_boundary_in_alternation` flag gated in
  `dfa.supports`/`edfa.supports`. Conservative (any `\b` under an `|` is declined, even when both
  branches consume) — it only forgoes the DFA fast path, never correctness; no benchmarked pattern
  uses `\b`-in-alternation, so there is no measured regression. Pinned by a conformance regression
  (`word-boundary-in-alternation keeps leftmost-first on auto`).
- **`auto` lost the empty-loop match for a repetition over a nullable alternation** — also found by
  the fuzzer. `(?:|.)+` on `"c"` returned `""` `{0,0}` instead of `"c"` `{0,1}`. ezi_gex's
  leftmost-first (JS-style) semantics — what the Pike VM and backtracker give, verified against
  JS/V8 and the `(|a)*`→`"aaa"` tiebreaker — take the consuming branch when the preferred empty
  branch makes no progress in the loop; the byte DFA's leftmost-**longest** merge took the empty
  exit. (RE2/Rust/Go/Python/Perl return `""` here; ezi_gex follows JS consistently.) Fixed by
  declining the shape to the Pike VM via `hir.Analysis.nullable_alternation_in_repetition` (any
  nullable alternation under a repetition), gated in `dfa.supports`/`edfa.supports`. Pinned by a
  conformance regression (`nullable-alternation-in-repetition agrees across backends`).
- **`auto` byte-DFA `supports`-gate hardening for anchors + zero-width** — a focused fuzz campaign
  (`fuzz/` target #4, `pattern_smith.genAnchors`, 400k trials + minimization) catalogued 31 distinct
  `auto`-vs-Pike-VM span divergences, all in the leftmost-longest byte DFA's `supports` gate, and
  **zero `pikevm != backtrack`** (the NFA core was sound). All are fixed by declining the offending
  shape to the Pike VM (a re-run of the campaign now finds 0). Three further `hir.Analysis` flags,
  gated in `dfa.supports`/`edfa.supports`, each pinned by a conformance regression whose controls
  prove the benchmarked DFA fast paths (`\d+$`, `^abc$`, `\bthe\b`, `(?m)^\w+`, `(?m)foo$`) stay
  DFA-eligible:
  - **`interior_text_end`** — a non-trailing `$`/`\z` (`$b$`, `\z.?\z`, `$^\z`): unsatisfiable past
    the anchor, but the reverse-from-end path keyed off a *trailing* anchor and wrongly matched.
  - **`word_boundary_with_nullable_alternation`** — a `\b`/`\B` *adjacent to* a nullable alternation
    (`\B(?:|.*)`), the sibling-of analogue of `word_boundary_in_alternation`.
  - **`complex_line_anchor`** (+ a `has_line and (has_text_end or has_text_start)` gate) — a `(?m)`
    line anchor that is non-trailing (`(?m:$\n)`), under a repetition (`(?m:\n$)*`), or mixed with a
    `text_start`/`text_end` (`(?m:$)\A`, `$^\z`). The eager-DFA `\n`-lookahead model only covers a
    clean leading `(?m)^` / trailing `(?m)$`.
  - **`word_boundary_with_lazy_repetition`** — a `\b`/`\B` with a *lazy* repetition (`a*?\b`,
    `[^a]+?\B *`): the lazy "prefer fewer" picks the short match where the boundary holds, but the
    longest-match DFA picks the long one. Caught by the **external Rust oracle** (the internal
    differential had missed it); greedy `\w*\b`/`a*\b` are unaffected and stay DFA-eligible.
  Verified results-invariant by the regex-bench parity suite: **all 32 match counts unchanged and no
  search regression** (geomean vs Rust still 1.12×) — no benchmarked pattern is newly declined.

### Changed

- **Replace runs at search speed when the template needs no captures.** `replaceAll`/`replace`/
  `replaceN` previously ran the capturing engine (`searchCaptures` → the Pike VM / one-pass table)
  on **every** match — even replacing with a constant or `$0`, where no group is referenced. The
  template is now analysed **once** (`templateRefsGroup`): if it references no group ≥ 1 and no named
  group, the loop uses the span-only `search` (the fast DFA path) and expands `$0`/`$$`/literals from
  the match span alone. Capture-referencing templates (`$2/$1`, `${name}`) are unchanged. Paired with
  a **group-less short-circuit** in `auto.fillCapturesAnchored` (a pattern with no capture groups
  fills group 0 straight from the DFA span — no engine), so `captures`/`capturesAll`/`replaceAllWith`
  on `\d+`/`\w+`-style patterns also skip the Pike VM pass. Results-invariant (the conformance
  differential and a revert-failing replace test pin span and bytes).
- **Eager-DFA / byte-lowering build is no longer quadratic in a Unicode class's size** — the
  `\p{…}`/`\w` compile-time cliff is gone. Two independent `O(class²)` hot spots were the cause, both
  now linear:
  - **Determinization single-seed closure cache** (`edfa`, `Det.ss_cache` / `RDet.rss_cache`). A
    Unicode class lowers to an `x+` loop over a fan-out **split tree** (hundreds of UTF-8 sequences),
    so *every* char-completing transition re-closed the loop-back split — re-walking the whole tree
    and re-interning the same large loop-header state, hundreds of times. Since a closure is a
    deterministic function of its seed list, the one-seed case (the loop-back pc, continuation pcs —
    the overwhelming majority of edges) is now memoized on `(seed pc, context)`: an exact key (no
    hash), with the two context bits (`at_line_start`, `at_word_left`) folded in so it is valid for
    `\b`/`\B` and `(?m)` programs too. The reverse determinizer gets the same cache. Determinization
    of `\p{L}+` dropped **~56 ms → ~1 ms**; `\w+` ~50 ms → ~1 ms; `\b\w+\b` ~45 ms → ~1 ms.
  - **Byte-lowering suffix-cache is now an O(1) hash index** (`byte`, `Builder.tail_hash`). The UTF-8
    suffix-sharing cache (`internTail`) scanned the class's growing byte-range DAG linearly per tail
    node — `O(class²)` per class, the dominant cost once determinization was fixed (and the whole cost
    for a pattern that declines the eager DFA, e.g. `email`). It is now an open-addressing hash keyed
    on `(lo, hi, next)`, so a class lowers in `O(class)`. `[\w.+-]+@[\w-]+\.[\w.-]+` (three big
    classes) build **~6 ms → <1 ms**. Both changes are pure build-time optimizations — the emitted
    automaton, determinized tables and every match are byte-identical (pinned by `conformance.zig`).
- **`auto` cascades a *prone* pattern with a start-skip prefilter from the eager to the lazy DFA**
  (`edfa.Options.decline_if_prone`). A prone pattern (one that can consume an unbounded non-accepting
  run before it can accept — `the\s+\p{L}+`, `\w+@\w+`) needs the eager DFA's frozen **reverse** table
  for its O(input) two-pass `find`. But when `auto` also has a leading-literal / alternation /
  interior-anchor prefilter, the find is *prefilter-driven* (skip to the candidate, one bounded native
  find), so that reverse table is built but barely used — pure compile-time waste (the reverse build
  of `the\s+\p{L}+` was ~8 ms). `auto` now tells `edfa` to decline such a pattern right after the
  cheap proneness check (before the `utrans` + reverse phases), and falls back to the lazy DFA: same
  prefilter, same spans, near-zero build. `the\s+\p{L}+` compile **~10 ms → ~0.6 ms**. Non-prone
  patterns (`\p{L}+`, `\w+`) and prefilter-less prone patterns keep the eager DFA unchanged.
  New decl (`@stable-since v0.5.0`): `edfa.Options.decline_if_prone`. Results-invariant.
- **Eager-DFA determinization budget** (`auto`, `EAGER_BYTE_INST_MAX = 8000`). `auto` now only
  *attempts* the eager DFA when the byte NFA is small enough that the full subset construction is
  cheap; a big Unicode-class join (`\w+@\w+`, `[\w.+-]+@…`) goes straight to the lazy DFA. Eager
  determinization cost scales with (DFA states × byte_insts) and explodes for these — and the email
  pattern's overflowed `edfa.max_states` and **declined anyway** after burning ~0.9 s, only to use
  the lazy DFA regardless. The lazy DFA computes the same states on demand, amortized over the input.
  Results-invariant — it only changes which span engine runs. The comptime CTRE-lane keeps its
  separate, tighter `tinyForComptimeEdfa` gate. New decl (`@stable-since v0.5.0`): `auto.EAGER_BYTE_INST_MAX`.
- **Per-module test units — `zig build test` is now flag-selectable and caches per module.** The
  engine was a single Zig module, so every `test {}` block compiled into one giant test binary;
  editing any file recompiled and re-ran the whole engine. `build.zig` now splits the library into
  named modules along an acyclic DAG (`utils` → `core` → `engine_base` → each backend → `regex` /
  `conformance` / `redos` → the `ezi_gex` facade), giving **15 independently-cacheable test
  binaries**. Editing one file re-runs only the unit(s) whose inputs changed; the rest stay cached
  (e.g. touching `literal.zig` re-runs 6 of 15 units, the other 9 stay cached). New ergonomics:
  `zig build test-<unit>` runs a single unit (`test-core`, `test-auto`, `test-pikevm`, …), and
  `-Dinclude-test=<unit>` (repeat the flag for several) gates the aggregate `zig build test`. The
  same 409 tests run, each exactly once; no source behavior change — the demo binary is byte-identical.
  Modeled on `ezi_code`'s build.

### Performance

Measured on `regex-bench` (Apple M4, ReleaseFast; non-overlapping `count` over the corpus):

- **`\bthe\b` over prose** ~490 MiB/s → **~3.7 GiB/s (≈8×)** — the per-occurrence anchored DFA
  confirm replaced by the O(1) boundary check (`lit_wb_confirm`), and the `memmem` finder hoisted out
  of the per-occurrence loop (it was rebuilt on every "the" substring).
- **`\d{4}-\d{2}-\d{2}` over logs** ~610 MiB/s → **~9.8 GiB/s (≈16×)** — the dash-to-dash fixed-offset
  bounded confirm replaces a linear native-DFA find over a dash-dense haystack.
- **`(?m)^…` log-line span** ~230 MiB/s → **~1.1 GiB/s (≈4.7×)** — line-anchored dispatch drops the
  lazy DFA's reverse pass and re-scan.
- **email compile time** ~0.88 s → **~6 ms (≈140×)** — the eager-determinization budget skips the
  doomed attempt; runtime is unchanged (it already used the lazy DFA).

All four are **results-invariant** — the cross-backend conformance suite pins every new path's spans
and capture slots to the Pike VM (runtime and comptime), incl. non-ASCII `\b`, fixed-offset
alignment, and line-skip cases.

**Compile time — the `\p{…}`/`\w` cliff is gone** (the determinization + byte-lowering linearization
and the prone-prefilter cascade above; `auto` compile, median, Apple M4 ReleaseFast). Search
throughput is **unchanged** — the same automaton runs, only the build got cheaper:

| pattern | before | after | speedup |
|---|--:|--:|--:|
| `\p{L}+` | 31.9 ms | ~1.0 ms | ≈32× |
| `\w+` | 45.2 ms | ~0.83 ms | ≈54× |
| `\b\w+\b` | 47.6 ms | ~1.25 ms | ≈38× |
| `\p{Lu}\p{Ll}+` | 10.1 ms | ~0.59 ms | ≈17× |
| `the\s+\p{L}+` | 107.4 ms | ~0.57 ms | ≈188× |
| `[\w.+-]+@[\w-]+\.[\w.-]+` (email) | 6.4 ms | ~0.82 ms | ≈7.8× |
| `\p{N}+` | 956 µs | ~130 µs | ≈7× |

These are **results-invariant** too — pinned by the cross-backend conformance differential (the
`the\s+\p{L}+` cascade and the reverse single-seed cache are in the `edfa` vs Pike VM corpus, and a
direct `decline_if_prone` / cascade-routing test guards the new dispatch).

### Docs

- Refreshed the empirical footprint numbers in `README.md` and `docs/architecture.md` against the
  current byte substrate (ezi_code `v0.4.1` pin, Zig 0.17.0-dev, macOS arm64). Re-measured: demo
  binary sizes (ReleaseSmall **794,968 B**, ReleaseSafe 1,362,504 B, ReleaseFast 1,226,408 B, Debug
  3,682,968 B — all ~1–3 % larger than the previously documented values); the `ezi_code` Unicode
  tables linked into the demo (**≈ 385 KB**); per-distinct-class baked ranges (`\w` 802, `\p{L}` 684,
  `\d` 72, `\s` 10); and the `abc` eager DFA (5 states / **100 B**). Corrected the "~1 MB trio"
  wording — that figure is the *prone* `\w+@\w+`, not a non-prone `\w+` (which only ever keeps its
  ~141 KB forward table). Instruction counts, range-block sizes and the reverse-DFA minimization
  ratio were re-checked and already current.

## [0.4.0] - 2026-06-15

### Added

- **Teddy SIMD multi-literal prefilter** (`backends.literal`, on by default) — a vectorised
  scanner for literal *alternations* (`cat|dog|fish`, `foo|far|fizz`), the case the single-needle
  `memmem`/`indexOfAny` scan handles least well (many branches, or branches sharing a first byte).
  Teddy fingerprints the first `n ∈ 1..3` bytes of every literal and tests all of them across a
  16-byte input chunk at once via a **dynamic in-vector byte shuffle**, producing candidate
  positions that are then verified against the actual literals in priority order. **Leftmost-first
  and results-invariant** — it locates exactly the match the scalar scan would (the verify step is
  shared), so it only ever changes speed, never which text matches.
  - **`engine/simd.zig`** (new) — the **only** file in the engine that emits target-specific inline
    asm, quarantining the one operation that cannot be written portably: the dynamic shuffle.
    `shuffle16` lowers to **`pshufb`** (x86-64 SSSE3) / **`tbl`** (aarch64 NEON); `shuffle32` to
    **`vpshufb`** (x86-64 AVX2, the per-128-bit-lane "fat" variant). Gated on the **CPU feature
    set** (not the arch name — SSSE3 is x86-64-v2, the baseline lacks it) and routed to a portable
    **scalar fallback** at comptime (`@inComptime()`) and on every unsupported target, so the
    engine stays correct everywhere. New pub decls (`@stable-since v0.4.0`): `simd.shuffle16`,
    `simd.shuffle32`, `simd.SimdMode`, `simd.has_pshufb`/`has_vpshufb`/`has_tbl`/
    `has_native_shuffle16`/`has_native_shuffle32`.
  - **`engine/teddy.zig`** (new) — the algorithm: an ≤8-bucket **slim-128** matcher (`Teddy`) and a
    16-bucket **fat-256** matcher (`FatTeddy`, AVX2 only — it spends the 256-bit register on
    bucket count, not throughput, halving collisions for large sets). The multi-byte fingerprint
    carry is a comptime `@shuffle` (overlapping windows with a within-chunk lower-lane shift), so
    only the fingerprint lookup is arch-specific; the rest — nibble split, carry, candidate mask,
    verify — is portable `@Vector`. Pub decls (`@stable-since v0.4.0`): `teddy.Teddy`,
    `teddy.FatTeddy`, `teddy.compileAlloc`/`compileFatAlloc`/`free`/`freeFat`/`supports`.
  - **Integration & policy.** The `literal` backend builds a Teddy arm for an unanchored
    alternation when the target has a native shuffle and the set benefits (declines a lone needle —
    Boyer–Moore–Horspool wins — an empty branch, and the comptime path; **fat** only with AVX2 and
    more needles than slim's buckets). A new front-door knob **`Options.strategy.simd`**
    (`enum { auto, off }`) governs it — a **permission, not a command**: `.auto` (default) uses
    Teddy where supported and falls back to scalar otherwise; `.off` forces the portable scan
    everywhere. There is deliberately **no "force on"** — a target without a native shuffle resolves
    to scalar regardless, so no setting can produce a broken binary. New decls (`@stable-since
    v0.4.0`): `regex.Options.Strategy.simd`, `auto.Options.simd`, `literal.Options.simd`.
  - **Unicode/flags** need **zero** handling in Teddy: the HIR resolves all folding/flags before any
    backend, and a case-insensitive *letter* becomes a `class`/alternation (never a literal run), so
    Teddy only ever receives exact, post-fold, case-sensitive literal runs — byte-scanning sound for
    UTF-8 (a needle's bytes occur only at code-point boundaries). It inherits `literal.zig`'s exact
    semantics.
  - **Validated by execution on all three SIMD targets**, not just assembly: arm64 **NEON `tbl`**
    natively; x86-64 **SSSE3 `pshufb`** and **AVX2 `vpshufb`** under Rosetta 2 (`-Dtarget=x86_64-macos
    -Dcpu=x86_64_v2`/`_v3`). Differential tests pin every Teddy result (slim and fat) to a reference
    scan at every offset (chunk boundaries, tail, priority ties, shared first bytes, >8/>16 needles,
    multi-byte UTF-8); the cross-backend conformance suite pins the integrated literal arm to the
    Pike VM; and a revert-failing `simd = .auto` vs `.off` results-invariance test guards the flag.

- **Portable two-byte SIMD `memmem` for single literals** (`engine/memmem.zig`, new; on by default)
  — the single-needle counterpart to Teddy. A pattern that reduces to **one** literal run
  (`Sherlock`, `Sherlock Holmes`, `héllo`) previously skipped candidate-to-candidate with a
  **one-byte** memchr on the needle's first byte + verify; a common lead byte (`'S'`, `'t'`) leaves
  a candidate at nearly every occurrence, so most of the work was wasted verification. `memmem`
  replaces that with the classic **two-byte filter**: probe the two needle offsets whose bytes are
  rarest in typical text (a comptime `freq` table — **speed-only**, never affecting which matches are
  found), AND their two SIMD equality masks, and verify only where *both* coincide. Candidate density
  drops to ≈ `(f_lo/256)·(f_hi/256)`.
  - **Portable — no arch asm.** Unlike Teddy's dynamic shuffle, the only SIMD ops are a broadcast
    compare (`vec == @splat(b)`) and a movemask (`@bitCast` of the bool vector); LLVM lowers them to
    SSE2 `pcmpeqb`/NEON on every target, with **no feature gate** (`simd.zig` stays the *only*
    arch-specific file). Vector width widens to 256-bit on AVX2, else 128-bit. **Sound**: a real
    occurrence has both probe bytes, so it never false-negates; false positives cost only a verify.
    Comptime routes to a scalar fallback (`Finder.find` handles `@inComptime()` — no `@Vector` in
    const-eval). New pub decls (`@stable-since v0.4.0`): `memmem.Finder`, `memmem.W`, `memmem.MIN_LEN`.
  - **Integration.** The `literal` backend builds a `memmem.Finder` for a single ≥2-byte needle under
    `Options.simd != .off` (new `literal.Program.mem`; allocation-free — it aliases `needles`), and the
    single-literal unanchored scan uses it instead of the one-byte memchr. A 1-byte needle stays on the
    SIMD `memchr` path; an alternation uses Teddy. Governed by the **same** `Options.strategy.simd`
    permission as Teddy (`.off` keeps the scalar `firstMatchPos`). Results-invariant.
  - **The `auto` NFA-arm prefix prefilter rides the same filter.** `auto.memmemFrom` — the
    leading-literal start-skip used by **all three** span arms (Pike VM, lazy DFA, eager DFA) — now
    routes a ≥2-byte prefix run through `memmem.Finder` instead of a single-rarest-byte memchr, so
    every prefix-literal NFA/DFA pattern (`\bthe\b`, `the\s+\p{L}+`, `https?://…`) got the two-byte
    upgrade for free.
  - **Validated:** `memmem.zig` differential tests pin the `Finder` to a reference scan at **every**
    start offset (chunk/scalar-tail seam, boundaries, overlap, repeated bytes, UTF-8, needles longer
    than a vector, no-match); a revert-failing `simd = .auto` vs `.off` results-invariance test over
    single literals in `literal.zig`; cross-backend conformance unchanged.
  - **Benchmark** (`zig/regex-bench`, Apple M4): `Sherlock` **233.67 → 13.54 µs (17×, 40.9 GiB/s —
    now faster than Rust)**, `Sherlock Holmes` **227.33 → 13.54 µs (16.8×, 41.6 GiB/s > Rust)**, `the`
    **504.75 → 62.88 µs (8×, 7.56 GiB/s > Rust)**; via the prefix upgrade, `\bthe\b` on logs
    **144.96 → 23.75 µs (6×)** and `the\s+\p{L}+` **837 → 670 µs**. Overall geomean Rust lead
    **3.54× → 2.55×**; ezi_gex fastest in **9/32** cells (was 4).

- **Whole-run literal prefilter (SIMD `memmem` start-skip) in `auto`.** The analysis prefilter's
  leading-literal start-skip previously used only the **first byte** of `prefix_literal` (a SIMD
  `memchr`); it now skips on the **whole leading literal run**, so a structured pattern leaps
  literal-to-literal instead of byte-to-byte — `\bthe\b` jumps "the"→"the" past every interior "the"
  (in "other", "there") rather than stopping at every 't'. The skip (`auto.memmemFrom`,
  `@stable-since v0.4.0`) now routes a ≥2-byte run through the **two-byte** `memmem.Finder` (see the
  `memmem` entry above) — AND the SIMD equality masks of the run's **two** rarest bytes, verify only
  where both coincide. (The first cut used a one-byte memchr on the single rarest byte; the two-byte
  filter is strictly more selective. It is deliberately **not** `std.mem.indexOfPos`, whose multi-byte
  path falls back to a *non-SIMD* linear scan for needles ≤ 4 bytes — exactly the common
  "the"/"http"/"foo" sizes.) The run drives the skip across **all three arms** (Pike VM, lazy DFA,
  eager DFA), and in the eager DFA's per-occurrence confirm loop it confirms once per literal-run
  occurrence instead of once per first-byte occurrence (strictly fewer `Scratch.confirm_probes`).
  Sound and results-invariant: the run is a *necessary* prefix of every match (truncated at
  `MAX_PREFIX_LEN` = 16 bytes, still sound), so no match is ever skipped — pinned by the cross-backend
  conformance/differential suites and a revert-failing white-box test (`filterFromAnalysis` must
  distil the *whole* run, not the first byte). The ReDoS guard is unaffected: a counted repeat like
  `a{4}b` keeps a 1-byte prefix run (`prefixLiteral` recurses through the `min≥1` repetition to its
  single-char child), so `memmemFrom` degrades to a `memchr` there. New decls `@stable-since v0.4.0`:
  `auto.memmemFrom`, `auto.Filter.{prefix, prefix_len}`.

- **`\b`/`\B` word boundaries on the byte DFAs** (`backends.edfa` + `backends.dfa`) — previously a
  `\b`/`\B` pattern always routed to the code-point Pike VM (the worst outlier in the cross-engine
  benchmark, ~10× behind). Word boundaries now ride the DFA, distributed across the two byte DFAs:
  - **Byte substrate** (`byte.zig`): `\b`/`\B` now **lower** to a byte `assertion` (so
    `byteLowerable` no longer excludes them — only `\X` does). `assertionHolds` evaluates them as
    **ASCII** word boundaries (new pub `isAsciiWordByte`), and `byteClasses` isolates the ASCII word
    set `[0-9A-Za-z_]` into its own equivalence classes (mirroring how `\n` is isolated for `(?m)`).
    The `bytepike` reference VM executes them directly.
  - **Eager DFA** (`backends.edfa`) — **ASCII** word boundaries baked into the frozen table, via the
    same machinery as `(?m)` line anchors lifted to word-ness: anchored restart where the start state
    is chosen by the preceding byte's word-ness (`startNW`) and acceptance uses a one-byte
    word-lookahead (`accept_before_word`/`accept_before_nonword`). Zero match-time decode; comptime +
    runtime. The determinizer splits states on word-context **only** when a boundary is parked (no
    state inflation otherwise), and `computeProne` treats the word-lookahead as an accepting exit so
    `\b\w+\b` stays non-prone (fast anchored restart). Declined to the Pike VM: `\b` combined with
    `$` or `(?m)`, a *prone* `\b` (`\b.*x`), and a chained `\b\b`.
  - **Lazy DFA** (`backends.dfa`) — full **Unicode** word boundaries via a **decode-hybrid**:
    consumption stays the cached byte-DFA walk, but a state holding a pending boundary
    (`Scratch.state_has_wb`) is resolved at match time by **decoding the adjacent code points**
    (`nfa.assertionHolds`, the Pike VM's own routine — Unicode-correct by construction), so only
    sparse boundary positions pay a decode. The resolution is memoized to a single bit
    (`Scratch.wb_cache`, two states per raw boundary-state) → O(1) per position.
  - **`auto`** builds **both** arms for a `\b` program and routes by a cached whole-input ASCII check
    (`Scratch.wb_*`, keyed on the input slice so a `count`/`findAll` scans once): ASCII input → the
    fast eager DFA, **non-ASCII input → the lazy DFA** (Unicode boundaries) instead of the Pike VM,
    anything declined → the Pike VM. `auto` stays **correct for every input** — comptime `\b` keeps to
    the Pike VM. Results-invariant: a wide differential corpus pins every byte-engine `\b` span to the
    Pike VM (the lazy DFA on **non-ASCII** too — e.g. `\bcafé\b` over `"cafés"`, where an ASCII-only
    boundary would mismatch), runtime and comptime, alongside exhaustive per-backend `\b`/`\B` tests
    and revert-failing regressions. **Benchmark** (`zig/regex-bench`, Apple M4): `\b\w+\b` **37 → 244
    MiB/s (~6.6×)** — now ≈ plain `\w+` (the boundary is free) and 1.63× of Rust `regex` (was ~11×);
    `\bthe\b` **89 MiB/s → 2.49 GiB/s (~28×)**. New decls `@stable-since v0.4.0`:
    `byte.isAsciiWordByte`; `edfa.Program.{accept_before_word, accept_before_nonword, startNW,
    has_word_boundary}`; `dfa.Program.has_word_boundary`; `dfa.Scratch.{state_has_wb, wb_cache}`.

- **One-pass NFA capture fast path** (new `backends.onepass`). A linear-time, single-thread
  capture engine for **provably one-pass** patterns — the common structured shapes
  `(\d{4})-(\d{2})-(\d{2})`, `(\w+)@(\w+)`, `(\d+):(\d+)`, `(\w)+`, `(a|b)*` — where at every
  step exactly one transition can fire and the capture writes to it are unique. It determinizes
  the shared NFA into a **frozen one-pass table** (comptime *and* runtime, like `edfa`; `Scratch`
  is empty/stateless) and fills the whole `slots` array with one deterministic thread: no thread
  set, no per-thread slot copies, no per-step epsilon closure. `auto` builds it for any
  capture-bearing one-pass pattern and uses it for the **anchored capture fill** after a DFA arm
  locates the span (replacing the Pike VM there). Measured on `(\w+)` capture extraction over the
  256 KiB corpus: **ASCII 64 → 206 MiB/s (~3.2×)**, Multilingual ~1.6×, Pathological ~2.7× vs the
  Pike-VM capture fill. **Sound by construction:** the one-pass decision is conservative — any
  ambiguity (two firable transitions on one symbol, a capture mask reached two ways, or a
  matching state that could consume into a non-matching one, i.e. an abandonable match) declines
  the pattern (`error.Unsupported`, a `@compileError` at comptime), and `auto` keeps it on the
  Pike VM — so the result never changes, only the capture cost. Assertion-bearing (`^ $ \A \z
  \b \B`, `(?m)`), `\X`, and >31-group patterns are declined by design. Pinned by a wide
  **differential test against the Pike VM** (byte-identical slots on every accepted pattern) plus
  a revert-failing regression and the cross-backend conformance suite. All decls `@stable-since
  v0.4.0`.

- **`(?m)` line anchors (`line_start`/`line_end`) on the eager DFA** (`backends.edfa`). `(?m)^`
  and `(?m)$` previously routed to the code-point Pike VM (`(?m)^\w+` ≈ 187 MiB/s); a **non-prone**
  line pattern (`(?m)^\w+`, `(?m)^foo`, `(?m)foo$`, `(?m)^abc$`, `(?m)^$`) now runs on the eager DFA
  via **anchored restart with line context** — `\n` is forced into its own byte equivalence class,
  the start state is chosen per position (`start0` at offset 0, `startL` just after a `\n`, else
  `startN`), and `line_end` is matched with a one-byte `\n`-lookahead (`accept_before_nl`).
  `(?m)^\w+` is now ~496 MiB/s (~2.6×). It is **O(input)** and quadratic-immune: a *prone* line
  pattern (an unbounded/long run before the anchor — `(?m)\w+$`, `(?m).*^x`) is declined at build
  and runs on the linear Pike VM (the reverse-DFA fix can't carry line context). Exhaustively tested
  — exact spans vs the Pike VM oracle across line-start placement off-by-ones, empty-line / zero-width
  placement, empty-match advancement, offset-0↔text-start aliasing, and `\r` (no `.crlf` mode → `\r`
  is content). New `Program` fields `accept_before_nl`/`startL`/`has_line_anchor` are `@stable-since v0.4.0`.

- **Hopcroft/Moore minimization of the eager DFA** (`backends.edfa`). The frozen transition
  tables are now partition-refined to the minimal DFA at build time (comptime + runtime),
  **results-invariant** (the minimal DFA accepts exactly the same language — pinned by the
  cross-backend differential/conformance suites). The representation is kept **dense** (the hot
  loop stays a single `trans[state*nc + class]` load — the eager DFA's headline throughput), so
  only the state *count* drops. The win is largest on the bigger auxiliary tables: a prone
  `\w+@\w+`'s reverse DFA shrinks ~3251 → ~1047 states (~3×); forward class loops like `\w+` are
  already near-minimal (~322), so they barely change. The forward DFA folds `utrans` into the
  equivalence signature exactly when it is consulted (prone programs); the reverse DFA is
  minimized independently. A **sparse** transition encoding was deliberately *not* adopted — it
  would trade the dense single-load hot loop for smaller tables, regressing throughput. Internal
  transform only — no public API change. Revert-failing regression: a redundant pattern
  (`abc|dbc`) is verified to minimize 7 → 5 states, and built programs are checked to be already
  minimal (re-refinement finds no mergeable states).

- **`text_end` (`$`/`\z`) on the lazy DFA** (`backends.dfa`). The lazy DFA previously declined
  any `$`/`\z` and left such patterns to the code-point engines; it now matches an
  **anchored-end** `$` (every match ends at input end — `\w+$`, `[ab]*c$`, `\w+@\w+$`,
  `foo$|bar$`, `^abc$`) in **O(input)** via a reverse-DFA-from-end pass, the same
  quadratic-immune strategy the eager DFA uses. This closes the one capability gap between the
  eager and lazy DFAs, so a trailing-`$` pattern too large for the eager DFA's fixed bounds now
  falls back to the lazy DFA (still on the fast span arm) instead of the NFA. A **mixed** `$` (a
  `text_end` in only some alternation branches, `a$|b`) stays declined — its end is not pinned,
  so it would be Θ(n²) — and runs on the linear Pike VM, as does `\X` (`\b`/`\B` and `(?m)` line
  anchors are now handled on the byte DFAs — see their entries above). Results-invariant (lazy-DFA
  spans stay byte-identical to the Pike VM, pinned by a new
  trailing-`$` differential corpus) and quadratic-immune (a new reverse-from-end linearity
  regression at 256 KiB). New `Program` fields `has_text_end`/`end_anchored`/`reaches_end`,
  `Scratch.state_match_eoi`, and the `revFindEnd` path are `@stable-since v0.4.0`.

- **Case-insensitive / small-class prefilter → Teddy multi-prefix start-skip** (`backends.auto`).
  A pattern that lowers to a short run of small classes — `(?i)the` → `[Tt][Hh][Ee]`, `(?i)что`,
  `[Tt]he` — has no fixed leading literal and no top-level alternation, so it previously got **no**
  prefilter and scanned the whole haystack on the DFA. `auto` now synthesises a bounded
  **case-variant prefix set** (the cartesian product of the leading positions' choices, capped at
  `MAX_PREFIX_BRANCHES` needles / `MAX_PREFIX_LEN` bytes — `(?i)the` → the 8 needles `{THE…the}`)
  and drives the existing multi-prefix start-skip with it. The set feeds a new **Teddy** arm
  (`Program.prefix_teddy`, built from any `prefix_set` ≥ 2 needles on a native-shuffle target — so a
  top-level alternation like `near`'s `Holmes…|Watson…` gets Teddy too), with the scalar
  `multiPrefixFrom` as the comptime / non-native fallback. Every needle is a sound necessary prefix,
  so it is **results-invariant**; the per-occurrence bounded confirm keeps it O(input). Bench:
  `(?i)the` ~4.6×, `(?i)sherlock holmes` ~17×, `(?i)что` ~15×, `near` ~1.6×.

- **Leading-class first-byte SIMD scan** (`engine/classscan.zig`, new; `backends.auto`). A class-led
  pattern with no fixed leading literal (`\d+`, `\p{N}+`, `\d{4}-…`) previously had an all-permissive
  filter and crawled the inter-match gaps one byte at a time on the DFA. `auto` now SIMD-scans to the
  next byte that could begin a match — a member of the leading class's first-byte set
  (`Analysis.leading_class_first`) — via a portable one-bucket nibble classifier (`ClassFinder`,
  built on `simd.shuffle16`, scalar fallback + comptime path). Gated on **selectivity**
  (`classLeadSelective`: no whitespace, few ASCII lowercase, ≤ 16 high lead bytes) so a near-universal
  letter class (`\p{L}+`, `[A-Za-z]+`) — which would land on almost every byte — is declined. Sound
  (every match begins with a member) and results-invariant. Bench (sparse-match corpora): `\d+`/`\p{N}+`
  on `sherlock` ~33–37× (now **faster than Rust**), `\d+` on `logs` ~1.9×.

- **`(?m)^` line anchors on the lazy DFA** (`backends.dfa`). The lazy DFA previously declined every
  `(?m)` line anchor, so a `(?m)^…` pattern too large or too **prone** for the eager DFA (whose line
  support is anchored-restart, declined when a `[^…]`/`\S` run could make it Θ(n²) — e.g. `log_line`)
  fell to the code-point Pike VM. It now runs a single **leading `(?m)^`** in **O(input)**, no
  anchored restart: the forward scan re-seeds the pattern start **only at line starts** (offset 0 or
  just after a `\n` — `ustep`/`startL`, gated on the `\n` byte class), and the reverse-DFA `find`
  accepts a start only where the position is a line start (`revFind`, gated on `atLineStart`). So a
  newline-crossing complement class (`[^"]*` spanning lines) is handled in one pass, quadratic-immune.
  `supports` admits exactly the single-leading-`^` shape (no `$`/`\A`/`\b`/`line_end`, no interior or
  repeated `^`); everything else stays on the code-point engines. Results-invariant (a new line-anchor
  differential corpus pins lazy-DFA spans to the Pike VM, runtime + comptime). New `Program` fields
  `has_line_start`/`nl_class`, `Scratch.startL`/`r_accept_line`, `@stable-since v0.4.0`.

### Changed / Fixed

- **Eager DFA: build the unanchored `utrans` table only for prone patterns (two-phase build).** A
  non-prone pattern runs entirely on anchored restart (`trans`), so it never consults `utrans` —
  yet the determinizer used to compute it anyway. Now phase 1 determinizes `trans` only, proneness
  is decided, and phase 2 re-determinizes with `utrans` **only when prone**. This (a) shrinks and
  speeds the build for the common non-prone case (`\w+`, `[a-z]+`), and (b) puts medium counted
  reps on the right arm: `a{8}b`..`a{64}b` now fit the (fast, dense) eager DFA instead of
  overflowing on unused `utrans` states and falling to the lazy DFA. Results-invariant.
- **Bounded-large-prefix anchored-restart hardening.** `computeProne` now flags not only a
  non-accepting *cycle* (unbounded run, Θ(n²)) but also a **long bounded** non-accepting prefix
  (longest non-accepting path > `RESTART_SCAN_LIMIT` = 64, e.g. `a{4000}b`), routing it off the
  per-occurrence confirm loop to the O(input) reverse find. This bounds the eager-DFA prefilter's
  confirm window to ≤64 bytes regardless of pattern. (A measurement confirmed `a{4000}b` itself is
  already **O(input)** — it overflows the eager DFA and runs on the lazy DFA, ~25 ms flat as the
  input grows 4 KiB→64 KiB; the 25 ms is the inherent Θ(k²) determinization of a k=4000 counted rep,
  a pattern-size cost, not an input ReDoS.) New deterministic `redos` guards: the `a{64}b`↔`a{65}b`
  proneness boundary and at-scale `a{N}b` linearity.

### Docs

- Hardened the backend module docs to state each backend's **capabilities, declines, and
  invariants** explicitly — what runs where and why — so opting directly into a specific
  backend is unambiguous (`auto` remains correct by construction for every pattern).

## [0.3.1] - 2026-06-14

A patch release: a real **Θ(n²) ReDoS in the default engine** (found by a new ReDoS bench)
and the test/bench machinery that catches it. Additive and results-invariant — no public
signature or match-result changes.

### Fixed

- **Quadratic (Θ(n²)) ReDoS in the default `auto` engine — the headline linear-time claim
  was violated for a broad class of common patterns.** `auto`'s prefilter applied a
  leading-literal `memchr` start-skip that **confirmed anchored at every occurrence** of the
  prefix byte. On a *begin-but-don't-complete* input where the prefix byte is dense — e.g.
  `a+b` (or `(a+)+$`, `(x+x+)+y`) on `aaaa…a!` — that is O(n) confirms each re-walking the
  O(n) run, i.e. **Θ(n²)**: ~1.1 s at 64 KiB, ~17 s at 256 KiB. The eager DFA's *own* find is
  O(n); the prefilter was pre-empting it. (It went unnoticed because a *rare* discriminating
  byte — `@` in `\w+@\w+`, `!` in `\d+!` — lets the prefilter fast-reject before the loop runs;
  `a+b` has no rare byte, so it fell straight through.) **Fix:** for programs whose anchored
  confirm can scan an unbounded run (`prone` — a non-accepting cycle — or `end_anchored` — a
  trailing `$`), `runEdfa` now skips to the first candidate once and hands off to the eager
  DFA's O(n) native find (reverse two-pass / reverse-from-end) instead of confirming per
  occurrence; the per-occurrence memchr-jump is kept only for the fast-confirm case (`foo\d+`),
  its intended speedup. The lazy-DFA and NFA prefilter arms (`runByteDfa`/`runNfa`) had the
  same hazard and now likewise take a single leading skip + their O(n)/O(n·m) native find.
  `a+b` on 64 KiB: **1.1 s → 186 µs**, and now scales linearly. Results-invariant
  (`conformance.zig` pins every backend's spans/captures unchanged).
- **Corrected a false claim in `backtrack.zig`.** The backtracker's native recursion depth is
  **proportional to the matched-repetition length, not bounded by the program** (the old doc
  said the opposite) — so a long enough input overflows the stack. This is a *stack-exhaustion*
  limit, **not** a time blowup: the `(pc, sp)` memo keeps the step count strictly linear
  (pinned by `engine/redos.zig`). Documented the consequence — the bare `backtrack` backend is
  a **bounded-input** tool; `auto` shields the common path by routing inputs over
  `BACKTRACK_MAX_INPUT` (4096) to the iterative Pike VM. The one uncapped path is grapheme
  (`\X`) matching (backtrack is the only `\X`-capable backend), so a large *quantified*-`\X`
  input is a documented constraint pending an iterative-backtracker rewrite.

### Added

- **ReDoS-immunity regression suite** (`engine/redos.zig`) — makes the linear-time claim
  *testable*, not just asserted. (1) A **deterministic, machine-independent** check that the
  bounded backtracker's exact work count (the new `Scratch.steps`, one tick per `(pc, sp)`
  memo probe — bounded by `program × (input+1)`) grows **~linearly** (≤ 3× per input doubling;
  a quadratic regression reads 4×, an exponential one astronomically more) on the textbook
  catastrophic corpus (`(a+)+$`, `(a*)*$`, `(a|ab)*$`, `(x+x+)+y`, quantified classes, …).
  (2) Cross-backend completion + span agreement at scale through the default `auto` engine, the
  `a+b`/`(a+)+$`/`(x+x+)+y` quadratic regression, the trailing-`$` Θ(n²) guard, and a bounded
  comptime match.
- **`backtrack.Scratch.steps`** (`@stable-since: v0.3.1`) — observable backtracking work count
  for the run just executed; the deterministic ReDoS observable. Read-only, never consulted by
  matching.
- **`auto.Scratch.confirm_probes`** (`@stable-since: v0.3.1`) — observable count of the eager-DFA
  arm's per-occurrence prefilter confirms. Stays **0** for `prone`/`end_anchored` programs (the
  fix above), so `engine/redos.zig` asserts it as a hard, revert-failing guard against the Θ(n²)
  regression. Read-only, never affects a result.
- **`redos` benchmark module** (`bench/modules/redos.zig`) — the catastrophic corpus at growing
  sizes through `auto`; a flat throughput column down each pattern's rows is visible linearity, a
  collapse is ReDoS. This is the bench that caught the Θ(n²) above.

## [0.3.0] - 2026-06-13

### Added

- **Lazy DFA backend** (`engine/backends/dfa.zig`) — the throughput engine the byte
  substrate (landed in `0.2.0`) was built for. It **determinizes the byte Thompson NFA
  on the fly**, advancing **one DFA state per input byte** through a transition table
  keyed on the program's `ByteClasses` (a handful of classes even for a large Unicode
  program), caching each `(state, class)` edge the first time it is taken. The memo is
  the "lazy" part. Determinization keeps the NFA states in **priority order** and
  **cuts on match**, lifting the Pike VM's "cut lower-priority threads on match" rule
  into the DFA state, so it is **leftmost-first** — its span never disagrees with the
  Pike VM (proven by a differential corpus in the backend's own tests and by
  `conformance.zig`). Key properties:
  - **Span-only** (`caps.captures = false`): the DFA finds `[start, end)`.
    `Engine(dfa)` offers `isMatch`/`find`/`findAll`/`count`/`split`; `captures` and
    `replaceAll` are a `@compileError` (route them through `auto`/`pikevm`). This is the
    first contract-legal `captures = false` backend. When opted in via `auto`, the DFA
    accelerates the span ops (`isMatch`/`find`); capture ops run the code-point Pike VM
    **anchored at the DFA-found span** (the *Capture handoff* below, added later this
    cycle for both DFA arms), so captures are correct and bounded to the match.
  - **Runtime-only** (`buildAlloc` + `search`, no `buildComptime`): the cache mutates at
    match time, which const-eval cannot do. The transition cache lives in the
    caller-owned `Scratch` (never on the immutable `Program`), and is the first consumer
    of `ScratchOptions{ max_bytes, on_full }` (via `Scratch.initOptions`) — a bounded
    cache that evicts at a search boundary, always results-invariant.
  - **Dead-on-invalid for free**: the byte lowering emits edges only for well-formed
    UTF-8, so a malformed byte has no transition and lands in the dead state; the
    anchored-restart wrapper resyncs to the next start. No validity check, no decode.
  - **Match start via a reverse DFA** (see *Reverse DFA — `find` is now O(n)* below): a
    forward pass locates the leftmost match end, then a reverse DFA, anchored at that end and
    scanning backward, locates the leftmost start — O(n), replacing the original anchored
    restart and its Θ(n²) worst case. The forward and reverse caches are shared across start
    positions and searches. `dfa.supports(hir)` accepts `\A` / non-multiline `^`
    (`text_start`); it declines `\X`, `\b`/`\B`, `$`/`\z`, and `(?m)` line anchors, which keep
    routing to the code-point engines (the eager DFA additionally handles `$`/`\z`).
- **`auto` byte-engine wiring** (`engine/backends/auto.zig`, `engine/regex.zig`) — the
  `Options.strategy.byte_engine` knob is no longer inert. The front door projects it
  onto the backend's build options (`backendOptions`); with
  `.{ .strategy = .{ .byte_engine = .enabled } }`, `auto` builds the byte lazy DFA
  alongside the NFA program and uses it for the span scan (`isMatch`/`find`), while
  `searchCaptures` still runs the Pike VM — so captures and `\b` are unaffected.
  Results-invariant by contract (`conformance.zig` pins the enabled span to the default
  span and verifies captures still resolve). **Superseded below** — a later 0.3.0 change
  (*The byte DFA is ON BY DEFAULT*) makes the byte DFA the default span engine
  (eager-preferred), so `byte_engine` defaults to *on* and `auto.route` reports
  `"nfa+edfa"` / `"nfa+dfa"`, not a bare `"dfa"`.
- **Byte substrate size compaction** (`engine/byte.zig`) — three changes shrink the
  byte Thompson NFA a Unicode-class pattern lowers to (the input the lazy DFA
  determinizes, and the artifact a future eager comptime DFA would freeze). Measured on
  the real compiler; ASCII patterns are unchanged throughout:
  - **UTF-8 suffix sharing.** A class's byte sequences are now built **back-to-front
    through a `(lo, hi, next)` suffix cache** (RE2 / `regex-automata`'s technique): the
    identical trailing UTF-8 continuation ranges (`[0x80, 0xBF]`) shared across hundreds
    of a class's sequences are emitted **once** and converged on, instead of re-emitted
    per branch. ~1.4–1.55× off a single Unicode class (`\w` 5691→3930 insts, `\p{L}`
    4777→3337, `\d` 391→252). The class's sequences match disjoint scalars, so they are
    mutually exclusive and the sharing is sound (`conformance.zig` and the exhaustive
    lowering tests verify it).
  - **Single-copy unbounded repetition.** `x{min,}` with a capture-free body compiles to
    `x{min-1} · x+` (one looped body copy) instead of `x{min} · x*` (an extra full copy).
    Combined with suffix sharing this is **~2.9× off** the common `+` cases — `\w+`
    11381→3931, `\w+@\w+` 22760→7860 (~273 KB → ~94 KB), `\d+` 781→253. A capturing body
    keeps the two-copy shape (final-iteration group spans unchanged); exact `{n}` still
    needs `n` distinct copies (different successors), collapsed by the DFA, not the NFA.
  - **Cost gate** — new public `byteWorthLowering(hir)` + `max_byte_insts` (`@stable-since
    v0.3.0`): `auto` consults it (with `dfa.supports`) so a pathologically large byte
    automaton (a big Unicode class repeated many times, e.g. `\p{L}{60}`) declines the
    byte/DFA path and stays on the compact code-point engine. Results-invariant — only
    which engine runs changes, never the match.

  Enabling mechanism: `byte_range` now carries an **explicit `next` successor** (it used
  to fall through to `pc + 1`), making the byte automaton a real graph so many
  predecessors can share one tail node; a plain chain still sets `next = pc + 1`. The
  byte VM (`bytepike`) and lazy DFA (`dfa`) follow `next` instead of `pc + 1` — a
  behaviour-identical mechanical change.
- **Eager DFA backend — now the DEFAULT span engine** (`engine/backends/edfa.zig`,
  `backends.edfa`) — the **fully determinized**, frozen byte DFA, and the first DFA that runs
  at **comptime**. Where the lazy `dfa` determinizes on the fly and caches into a `Scratch`,
  this one determinizes the **whole** automaton at build time into an immutable
  `states × byte_classes` table, so the matcher is a bare `state = trans[state][class]` table
  walk with **no per-search state** — `caps.stateless = true`, an **empty `Scratch`**, and
  `buildComptime` bakes the table into `ro_data` (the lazy DFA can't: its cache mutates while
  matching). It is ~5–10× the lazy DFA on class scans and is what `auto` now prefers (below).
  Properties:
  - **O(input) `find` on every pattern, picked statically at build.** `computeProne` detects
    whether the anchored DFA has a **non-accepting cycle reachable from a start** (it can
    consume an unbounded run without ever accepting — `\w+@\w+`'s pre-`@` word run). A
    **non-prone** pattern (`\w+`, `\d+`, `[A-Za-z]+`: their consuming loop is itself
    accepting) uses **anchored restart** — one greedy table walk per match, the headline
    ~1.1 GiB/s, O(input) because no start can scan far without accepting. A **prone** pattern
    uses the **reverse-DFA two-pass**: a frozen *reverse* transition table (`RDet`, comptime +
    runtime) — a forward one-pass (`utrans`) locates the match END, the reverse DFA the START
    — replacing the old Θ(n²) anchored restart. No per-search probing.
  - **One-pass unanchored `isMatch`** (prone patterns, via the `utrans` `.*?`-prefix table);
    anchored-restart earliest-exit for non-prone.
  - **`text_end` (`$`/`\z`) now runs on the DFA.** The closure records a pending `text_end` pc
    as a state member and computes `accept_eoi` (does it reach `match` at end of input — a
    `computeEndReaches` epsilon-fixpoint); the matcher checks it when the scan reaches
    `input.len`. A **trailing-`$`** pattern (every match ends at input end) is matched in
    **O(input)** by a single reverse-DFA pass from `input.len`, not anchored restart — see
    *Quadratic immunity for `$` patterns* below. `edfa.supports` now accepts **`text_start` and
    `anchored_end` `text_end`** — broader than `dfa.supports` (the lazy DFA declines `$`
    outright). `(?m)` line anchors, `\b`/`\B`, `\X` are still declined.
  - **Span-only** (`caps.captures = false`), **leftmost-first** (priority + cut-on-match),
    dead-on-invalid; `conformance.zig` pins its span to the Pike VM's, runtime and comptime.
  - **Builds only the tables it will use.** `utrans` and the reverse table are built **only**
    for prone patterns; a non-prone `\w+` keeps just its `trans` table (~141 KB) instead of
    trans + utrans + reverse (~1 MB) — the bulk of the eager DFA's memory is gone on the
    common case. (Full Hopcroft minimization + a sparse encoding of the *kept* tables remain a
    noted follow-up.)
  - **Bounded.** Eager determinization writes into fixed storage (so the identical code runs
    at comptime, allocator-free), so a pattern whose **full** DFA exceeds `edfa.max_states`
    (4096) is declined — `error.Unsupported` at runtime (fall back to the lazy `dfa`), a
    `@compileError` at comptime. Per-build buffers are sized to the pattern.
  - New public surface: `backends.edfa`, `edfa.max_states`, `edfa.buildComptime`/`supports`
    (`@stable-since v0.3.0`).
- **Quadratic immunity for `$` (`text_end`) patterns** (`engine/backends/edfa.zig`) — a
  trailing-`$` / `anchored_end` pattern (`[ab]*c$`, `\w+@\w+$`, `\w+$`) no longer falls onto the
  Θ(n²) anchored restart it was previously forced onto (every start scanned to end-of-input and
  failed — a ReDoS hole against the linear-time claim). Because `$`/`\z` pins the match end to
  `input.len`, `find`/`isMatch` now run a single **O(input) reverse-DFA pass from the end**: the
  reverse determinizer models `$` via a passable `text_end` reverse epsilon, so `revClosure(match)`
  walks back through it into the pre-`$` states. New `Program.end_anchored` + `revFindEnd`
  (`@stable-since v0.3.0`). A **mixed** `$` (text_end in only some branches, e.g. `a$|b`, where the
  end is not pinned) is now **declined** by `edfa.supports` and routed to the linear Pike VM. Net:
  the eager DFA never takes a super-linear path on any pattern it accepts — linear-time / ReDoS
  immunity is a hard contract. Regression-tested with a 256 KiB no-completer input over
  `[ab]*c$`-class shapes, a `$`-corpus differential vs the Pike VM, and a comptime-`$` match.
  **All-branch `$` alternations** (`foo$|bar$`, `a$|b$`) are covered too: `core/hir.zig`
  `endsAnchored`/`startsAnchored` now prove `anchored_end`/`anchored_start` for an alternation
  when *every* branch is anchored, so they take the same fast path. A **mixed** `$` (text_end in
  only *some* branches, e.g. `a$|b`) is **declined** by `edfa.supports` and routed to the linear
  Pike VM — correct + O(input), just not DFA-accelerated; a documented, intentionally-deferred
  limitation (the rare shape doesn't justify a two-seed reverse DFA).
- **Eager-DFA hash interner — O(states²) → ~O(states) determinization** (`engine/backends/edfa.zig`).
  `Det.intern`/`RDet.intern` now intern DFA states through an **open-addressing hash index**
  (`hashPcs`, in caller-supplied fixed buffers so it stays comptime-compatible) instead of a
  linear scan over all prior states. Determinizing a big Unicode class — and especially the
  reverse DFA a *prone* or *trailing-`$`* pattern builds (`\w+@\w+`, `\w+@\w+$`, `\p{L}+$`) — drops
  from **~seconds to ~milliseconds to *compile*** (the demo's old ~3 s `\w+@\w+` stall is gone).
  Build-time only — **match time is unchanged (O(input))**, and there is **no semantic change**
  (same states, same frozen tables; conformance + differential suites guard it).
- **The byte DFA is ON BY DEFAULT through `auto`, preferring the eager DFA**
  (`engine/backends/auto.zig`, `engine/regex.zig`) — the single biggest throughput change.
  `Options.strategy.byte_engine` defaulted to `.auto`, which used to be **inert**; it now
  means *build and use the byte DFA* on an eligible pattern (`.auto` ≡ `.enabled`). `auto`
  **prefers the eager DFA** (the frozen-table engine above; ~5–10× the lazy DFA on class
  scans, and the only DFA that runs at **comptime**), falling back to the **lazy** DFA only
  when the eager one overflows its `max_states` bound, then to the NFA. The class-scan family
  (`\w+`, `\d+`, `[A-Za-z]+`, `\p{L}+`) is now **at Rust-`regex` parity** (~1–1.3× behind, was ~1.6–2.3×). Results-invariant — `conformance.zig`
  pins every DFA span/captures to the Pike VM and fuzzes the strategy knobs. `.disabled` opts
  back to the compact NFA-only program. `auto.route` reports `"nfa+edfa"` (preferred),
  `"nfa+dfa"` (lazy fallback), `"nfa"`, or `"literal"`.
  - **Comptime CTRE-lane.** `auto.buildComptime` now bakes a real frozen eager DFA into
    `ro_data` for **tiny** patterns (small ASCII classes / alternations / counted reps — gated
    by a cheap, measure-free `tinyForComptimeEdfa` HIR check). A big Unicode class (`\w`,
    `\p{L}`) or `.` stays on the Pike VM at comptime (determinizing it in the const-evaluator
    is too memory-hungry) but still gets the eager DFA at **runtime**.
  - **Lazy DFA hot-loop pass** (`engine/backends/dfa.zig`). The warm path now reads through
    cached raw `[*]const u32`/`[*]const bool` table pointers (refreshed only after a cold,
    realloc-capable transition) and the per-byte cache-budget check moved out of the warm loop
    into the cold path — ~336 → ~517 MiB/s on `\w+`. The lazy DFA is now the **fallback** for
    patterns too big for the eager DFA's bounds.
  - **Reverse DFA — `find` is now O(n)** (`engine/backends/dfa.zig`). A forward pass
    locates the leftmost match **end** (`findEndForward`: re-seed the start each byte until
    the first match, then extend it anchored), then a **reverse DFA** (`ReverseAdj` +
    `revFind`), anchored at that end and scanning *backward*, locates the leftmost
    **start**. This replaces the Θ(n²) anchored restart on the "begins-everywhere-but-
    completes-rarely" class (`\w+@\w+` on a long word run, `[ab]*c`) with two linear passes.
    The reverse is a plain subset construction (no priority/cut — the end is fixed, so only
    *reachability* of the forward start matters), cached like the forward transitions and
    honouring the same `max_bytes` budget. Leftmost-first, pinned to the Pike VM across the
    wide corpus + a dedicated reverse-vs-anchored-restart differential. A pattern with an
    *interior* `text_start` (rare, not fully `anchored_start`) keeps anchored restart so the
    cached reverse transitions stay position-independent.
  - **Capture handoff** (`auto.searchCaptures`): when the DFA arm is present, captures are
    filled by the Pike VM **anchored at the DFA-found span start** (bounded to the match)
    instead of an unanchored Pike VM scan over the whole input — an O(input) capture search
    becomes O(match) on a sparse match. Same groups (the DFA span *is* the leftmost-first
    match), conformance-pinned.
  - **Prefilter, wired and configurable:** the new `strategy.prefilter` knob (default on)
    is live, and the analysis prefilter gained a **rarest-required-byte fast-reject** —
    a byte in `analysis.required_bytes` that occurs in *every* match drives a sound
    `memchr`: if it is absent from the input there is no match, so the search returns at
    once (the win for a prefix-less interior-literal pattern like `\w+@\w+` over text with
    no `@`). The rarest member is chosen by a static byte-frequency heuristic so the probe
    is as selective as possible. `prefilter = false` builds an all-permissive filter.
  - New/updated public Options: `strategy.byte_engine` (now wired, default-on) and
    `strategy.prefilter` (now wired), both `@stable-since v0.3.0`.
- **Wide differential conformance corpus** (`engine/conformance.zig`) — ~85 (pattern,
  input) cases spanning the whole syntax surface (empty/zero-width, greedy vs lazy,
  alternation priority, counted reps, nested captures, multibyte UTF-8, `\p{}` classes,
  special case folds, `^`/`$`/`(?m)`, `\b`/`\B`, dead-on-invalid `\xFF`, sparse matches,
  pathological-but-linear shapes). Every applicable backend (pikevm / backtrack / auto /
  lazy DFA / eager DFA) must produce the **byte-identical span** the Pike VM does, and a
  companion test fuzzes `prefilter`/`byte_engine` on↔off and pins every span to the
  default — the safety net for the DFA-on-by-default + prefilter wiring. The corpus now also
  covers `text_end` (`a$`, `\d+$`, `^abc$`, `\w+@\w+$`) on the eager DFA, and the eager-DFA
  differential builds each pattern **once** and reuses it across inputs (the heavy reverse-DFA
  determinization is paid once, not once per input).
- **Backtracker: touched-words visited clearing** (`engine/backends/backtrack.zig`). The
  `(pc, sp)` visited bitset is no longer fully `@memset` every search — a touched-words list
  records the dirtied words and clears only those next run, so an early-exit search no longer
  pays an O(program × input) clear. The out-of-range `save` guard became an assertion, and the
  program-structure-bounded recursion depth (only `split.a`/`save` recurse) is documented.
  Behaviour is unchanged (proven by added results-invariance tests).

### Fixed

- **Literal alternation was accidentally Θ(input²)** (`engine/backends/literal.zig`). The
  unanchored search did one `indexOfPos` per branch, so each `count` step scanned toward the
  *rarest* needle's next occurrence — re-scanning the same region for a sparse branch on every
  match. It now collects the distinct first bytes and skips to the next candidate with a single
  SIMD `indexOfAny` pass, verifying branches in priority order at each candidate — O(input).
  `foo|bar|baz|qux` went from **~7 MiB/s to ~460 MiB/s** in the bench (Rust's Teddy is still far
  ahead, but it is no longer quadratic). A single-literal pattern is unchanged (one `indexOfPos`).

### Changed

- **Dependency:** pinned `ezi_code` to **0.4.1** (was a `0.3.0-dev` commit). The 0.4.x
  releases hardened the decode contract the engine relies on — "lossy never errors,
  unchecked never panics" now holds structurally across all three codecs, so the
  engine's `\b` reverse-decode and dead-on-invalid paths inherit a stronger guarantee —
  and unified the `BufferTooSmall` error name. **No `ezi_gex` source change was
  required**: the breaking 0.4.x changes were confined to UTF-8 stream / UTF-16/32 paths
  the engine does not use, and the facade (`src/utils/unicode.zig`) absorbed the rest.

### Notes

- The byte-compiler size follow-up flagged in 0.2.0 is **largely addressed** by the
  suffix sharing + single-copy repetition above (a class's internal redundancy is shared;
  an unbounded `x{min,}` no longer duplicates its body). What remains is structural, not a
  bug: an **exact `x{n}`** still emits `n` copies because each has a distinct successor
  (a flat Thompson NFA has no subroutine/return), and the un-shared cross-class
  duplication of `\p{L}{3}`-style patterns is collapsed at match time by the lazy DFA
  (`\w+` → ~10 DFA states regardless of its ~3.9 k-instruction NFA). The eager comptime
  DFA (the deferred CTRE-lane backend) is what would carry that collapse
  into `ro_data` for the comptime path.

## [0.2.0] - 2026-06-09

### Added

- **Byte-NFA lowering + `ByteMap` equivalence classes** (`engine/byte.zig`) — the
  UTF-8 automaton substrate the future lazy DFA will determinize. A
  scalar range lowers to UTF-8 **byte-range sequences** (the Cox/RE2 `utf8-ranges`
  algorithm, exact across length + surrogate boundaries), so a Unicode class becomes
  a byte sub-automaton that matches the same code points with **zero decode**. The
  byte `Program` is a Thompson NFA whose only consuming instruction is a `byte_range`
  test; it builds at comptime and runtime. `byteClasses(program)` computes sound,
  contiguous byte equivalence classes (alphabet compression: even `\w+`'s automaton
  collapses to ~112 classes). Gated by `byteLowerable(hir)` — `\X` (grapheme) and
  `\b`/`\B` (word boundary needs the adjacent code point) are not byte-lowerable and
  route to the code-point engines. **Memory note:** byte programs are *larger* than
  the code-point program for Unicode classes (a single `\w+` is ~137 KB vs 6.5 KB;
  ASCII patterns are unchanged) — expected for an NFA substrate, and only paid when
  the byte path is used. The byte compiler does not yet intern repeated classes
  (future work).
- **`bytepike` backend** (`engine/backends/bytepike.zig`) — a byte-stepping Pike VM
  that executes the byte `Program`: linear-time, leftmost-first, captures, comptime +
  runtime, same caller-owned `Scratch` design. The reference executor proving the
  byte lowering correct (`conformance.zig` shows it agrees with `pikevm`/`backtrack`/
  `auto` across the whole case table, runtime and comptime) and the substrate for the
  lazy DFA. It is **not** `auto`'s default — stepping per byte is not a throughput win
  over the code-point VM; the DFA will be. **Invalid UTF-8** is dead-on-invalid by
  construction (the lowering only accepts well-formed sequences).

- **`(?x)` extended / verbose mode** (`core/scanner.zig`, `core/token.zig`). In
  normal (non-class) context, unescaped whitespace and `#`-to-end-of-line comments
  are insignificant, so patterns can be laid out readably. Works globally (`(?x)…`)
  and scoped (`(?x:…)`, restored at the group's `)`); an escaped space (`\ `) stays
  literal. It is a lex-time flag, so it is set via inline `(?x)` (not the front-door
  `Options`, which is applied after lexing).

- **`SearchOptions.span_end` and `earliest`** (`engine/backend.zig`). `span_end`
  bounds a search to the sub-range `[start, span_end)` without copying — the agnostic
  `Engine` ops clamp the haystack, so backends are unchanged and returned offsets
  still index the full input (reachable via `findAt`/`isMatchAt`/`capturesAt`).
  `earliest` is reserved (a no-op for the leftmost-first engines, which already
  return the leftmost match and short-circuit `isMatch`).

- **`Options.strategy` reserved tier** (`engine/regex.zig`). A `Strategy` sub-struct
  (`byte_engine`, `unicode_word_boundary_in_dfa`, `prefilter`) separates
  results-invariant execution knobs from the semantic flags. Currently inert
  (reserved for the byte-engine work); locks the option shape so wiring them later is
  non-breaking. Flipping any field never changes which text matches.

- **Grapheme `\X`** (UAX #29 extended grapheme clusters) is now supported. `\X`
  matches one whole cluster (combining marks, emoji ZWJ/modifier sequences,
  regional-indicator pairs, …). It compiles to a variable-width `grapheme` NFA
  instruction executed by the **backtracker**; `auto` routes any `\X` pattern there,
  while the breadth-first Pike VM refuses grapheme programs at build (it cannot
  consume a variable number of code points per step). Segmentation lives behind the
  `utils.unicode.grapheme` facade helper. Previously `\X` was `error.Unsupported`.
  Limitation: `\X` over very large inputs is bounded by the backtracker's memo.

- **`Match.pattern` reserved field** (`engine/backend.zig`). A defaulted `u32`
  (always `0` today) is threaded through `Match` so a future multi-pattern / set
  API can report which pattern matched without breaking `Match`'s shape.

- **ASCII mode for shorthand classes** (`Options.unicode = false`). `\d`/`\w`/`\s`
  resolve to the classic ASCII sets (`[0-9]`, `[0-9A-Za-z_]`, `[ \t\n\v\f\r]`)
  instead of their Unicode definitions, keeping automata small. Affects only the
  shorthands — `.` and `\b` stay Unicode-aware. Default `true` (today's behaviour).

- **`Options` initial-flag seeding** (`engine/regex.zig`). `compileRuntime` /
  `compileComptime` now accept `case_insensitive`, `multiline`, and
  `dot_matches_newline` — seeding `(?i)` / `(?m)` / `(?s)` for the whole pattern
  without writing the inline flag. Inline flags still compose (OR-merged onto the
  seed; scoped `(?-i:…)` groups are unaffected). The comptime compile path now
  raises its eval-branch quota so `(?i)`/folded patterns build at compile time.

- **Full case folding** (`Options.case_fold = .full`). Under `(?i)`, a literal whose
  Unicode full fold expands now matches its expansion too: `ß` matches `ss`/`SS`,
  `ﬀ` matches `ff`, `ﬃ` matches `ffi`, … It lowers (`core/hir.zig` →
  `lowerLiteralFull`) to an alternation of the code point's simple-fold orbit and
  the spelled-out expansion (each letter case-folded). Literals only — character
  classes keep simple folding (a class matches one code point), and the pattern is
  folded, not the input (so `ss` does not match a lone `ß`). Previously `.full`
  behaved like `.simple` (a v1 gap). Build-time only (O(1) full-fold table lookup,
  ASCII short-circuited); match-time is unchanged.

- **`utils` module — the single `ezi_code` seam** (`src/utils/{root,unicode}.zig`).
  All Unicode/encoding access (`CodePoint`, `utf8`, `properties`, `scripts`,
  `casing`) now flows through `utils.unicode.*`. Enforced by the build graph: the
  engine module imports `utils`, not `ezi_code`, so a stray `@import("ezi_code")`
  anywhere else fails to compile. Reserves one home for the value-added Unicode
  helpers (full case folding, grapheme `\X`, invalid-UTF-8 decode policy) still to
  land. No change to match semantics or performance.

- **`re.capturesComptime(input)`** (`engine/regex.zig`, `@stable-since: v0.2.0`) —
  resolve a match's submatches at compile time, rounding out
  `isMatchComptime`/`findComptime`/`countComptime`. The returned `Captures` freezes
  the slot offsets and input into `ro_data`, so `groupSlice`/`namedSlice` (numbered
  **and named** groups) work on it at comptime and at runtime.

### Changed

- **Invalid UTF-8 in input is now dead-on-invalid** (`engine/nfa.zig` + both NFA
  backends). A malformed byte matches nothing (`.` no longer matches it) and the
  unanchored scan resyncs one byte past it, so a match never spans a bad byte.
  **Behaviour change:** previously an invalid byte decoded to `U+FFFD` and could match
  `.` or a class containing `U+FFFD`. `decodeAt` now reports a `valid` bit;
  `char`/`range`/`any` fail on an invalid byte in both the Pike VM and the
  backtracker. The PATTERN is still strictly validated (invalid pattern bytes remain a
  compile error, not a substitution).

- **Binary size: ~525 KB smaller** for a representative build (`main.zig` demo:
  3.29 MB → 2.76 MB on macOS arm64, Debug), with no change to match semantics or
  match-time performance. Two independent causes of Unicode-table bloat were
  removed:
  - The scanner now validates group names with `ezi_code`'s range-table
    identifier predicates (`isIdentifierStartByRanges`/`isIdentifierContinueByRanges`),
    and `\b` word-boundary goes through the range-table `isWord`, so ezi_gex no
    longer links `ezi_code`'s ~220 KB of per-code-point property page tries — the
    HIR and the matcher now consult *only* the enumerable range tables.
  - The bumped `ezi_code` pin de-duplicates those range tables (each had been
    emitted 2–3× in consumer binaries).
- **Program range interning** (`engine/nfa.zig`): the compiler interns identical
  resolved class range-blocks in the `Program`, so a pattern that repeats a class
  (e.g. `(\w+)@(\w+)\.(\w+)`) stores those ranges once instead of per occurrence.
  Shrinks both the heap program and the comptime `ro_data` it bakes into. Sound —
  blocks are immutable and read-only at match time — and the match result is
  unchanged.

### Fixed

- **Case-fold orbit closure** (`core/hir.zig`): under `(?i)` /
  `case_fold = .simple` a class/literal now admits the *entire* simple-fold
  orbit, including members reached transitively. Previously `(?i)K` (U+004B)
  matched `K`/`k` but not U+212A KELVIN SIGN even though all three fold to `k`;
  likewise `(?i)Å` (U+00C5) now also matches U+212B ANGSTROM SIGN. (Full
  `1→many` folding such as `ß`↔`ss` remains a documented v1 gap.)

## [0.1.0] - 2026-06-07

First public surface and first tagged release. Everything here is annotated
`@stable-since: v0.1.0` in the source and is covered by SemVer from this tag on.

### Added

- **Pipeline:** `pattern → AST → HIR → Program → match`, runnable at **runtime**
  (heap) and **comptime** (ro_data) from one code path.
- **Front door** (`engine/regex.zig`): `compileRuntime` / `compileComptime` and
  their `*With(Backend, …)` variants returning a backend-parametric `Compiled`,
  with `isMatch` / `find` / `captures` / `findAll` / `capturesAll` / `count` /
  `split` / `replaceAll`, plus `isMatchComptime` / `findComptime` / `countComptime`.
- **Backend contract** (`engine/backend.zig`): a duck-typed, vtable-free `type`
  contract (`caps`, `Program`, `Scratch`, build + search primitives), the
  `Engine(Backend)` agnostic operation layer (every iterator/capture/replace op
  implemented once, generically), `verifyBackend`, and the optional `Cell`/`Carver`
  comptime-friendly scratch convention.
- **Backends:** `pikevm` (Pike VM, captures, linear-time), `backtrack` (bounded
  backtracker, memoized, linear-time), `literal` (stateless substring /
  literal-alternation), and `auto` (the default dispatcher: literal-vs-NFA at
  build, backtrack-vs-pikevm per input). All build and run at comptime and runtime.
- **Tier-1 prefilter (literal + `auto`):** the `literal` backend scans with
  `std.mem.indexOf` (SIMD `memchr` for one-byte needles, Boyer–Moore–Horspool with a
  skip table otherwise) instead of an `eql` at every position — ~20× on
  memchr-friendly needles, never slower. `auto` now consumes the HIR `Analysis` on the
  NFA arm: a leading-literal first-byte `memchr` prefilter (anchored-confirm at each
  hit), a `^`/`\A` start short-circuit, and a `min_utf8_len` length gate — all sound
  one-sided bounds, so no real match is ever dropped. Works at comptime and runtime.
- **Target-agnostic library:** the importable surface (`src/root.zig`) is pure
  computation over caller-provided memory — no syscalls, allocator globals, or
  platform assumptions — and is verified to compile for `wasm32-freestanding`,
  `wasm32-wasi`, `riscv64-freestanding`, and `aarch64-linux`.
- **Frontend** (`core/`): storage-agnostic scanner (single-pass, explicit-stack,
  no recursion), flat AST, an `error.zig` diagnostic catalogue (precise code + byte
  span; unsupportable constructs are *rejected*, not mis-parsed), and the **HIR**
  builder — applies/drops flags, resolves all Unicode (`\d \w \s`, `\p{…}`/`\P{…}`,
  scripts, classes) to sorted/merged/negation-applied code-point ranges via
  `ezi_code` range tables, simple case folding, simplification, and a sound
  prefilter/length `Analysis`.
- **Unicode:** code-point-based matching with zero match-time Unicode-table
  lookups for classes; `\p{}`/`\P{}` general categories, groups, derived
  properties, and scripts; Unicode-aware `\w`/`\b`; simple case folding under `(?i)`.
- **Errors as data:** `Diagnostic` (code + span + message + caret renderer);
  runtime `parse` returns `error.InvalidPattern` and never crashes on bad input;
  comptime `compile` turns a bad pattern into a located `@compileError`.

### Notes & known limitations (intentional for 0.1.0)

- **No backreferences, lookaround, atomic/conditional groups, recursion, or
  `\Q…\E`.** A Thompson NFA cannot express them; each is rejected with a specific
  error code (same scope as RE2 / Go `regexp` / Rust `regex`).
- **Anchors are JS/RE2-style:** `$` (without `m`) means end-of-input (`\z`), not
  "before a trailing newline"; `\Z` is treated as `\z`.
- **`\X` (grapheme cluster)** parses but no current backend executes it — such a
  pattern fails at build with `error.Unsupported` (`caps.grapheme = false`).
- **`case_fold = .full`** currently behaves like `.simple` (the 1→many fold,
  e.g. `ß` → `ss`, is not yet implemented). `Script_Extensions` falls back to the
  plain `Script` ranges.
- **`{m,n}` is not size-capped yet** — a huge counted repeat expands to a large
  program (bounded by allocation / the comptime branch quota, never UB).
- **No lazy-DFA backend yet.** Tier-1 (the literal/prefilter fast path) is wired, but
  on general (non-prefixable) patterns throughput is still NFA-simulation-bound and
  below RE2/Rust. A one-pass capture path and a runtime-only lazy DFA are the next,
  additive tiers — the backend contract is the seam for both. See
  `docs/architecture.md` for the planned tiers.
