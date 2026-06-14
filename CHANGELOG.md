# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

`0.4.0-dev` on `main`.

### Added

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
