# backends/ — the built-in matchers

Seven backends. All satisfy the same contract (`../backend.zig`) and are leftmost-first
(Perl/JS), so their match and captures agree bit-for-bit. All build and run at **comptime
and runtime** *except* the lazy `dfa`, which is runtime-only (its cache mutates at match
time). `auto` is the default.

| Backend | Strategy | Memory | Captures | When `auto` picks it |
|---|---|---|---|---|
| `literal` | substring / literal-alternation byte scan (`indexOf` / SIMD `indexOfAny`) | none (stateless) | whole-match only | pure-literal pattern (`abc`, `cat\|dog`) |
| `pikevm` | breadth-first NFA (thread set, one code point/step) | O(program), input-independent | ✅ | NFA pattern, large input — and it fills captures for the DFA span arm |
| `backtrack` | depth-first NFA + `(pc,sp)` memo | O(program × input) | ✅ | NFA pattern, small input that fits (≤ 4096 B) |
| `bytepike` | breadth-first **byte** NFA (`../byte.zig`), one *byte*/step, zero-decode | O(program); larger for Unicode classes | ✅ | **never** — the byte-lowering reference VM / DFA substrate; refuses `\X`; evaluates `\b`/`\B` as **ASCII** word boundaries |
| `edfa` | **eager DFA**: fully determinizes the byte NFA at build into a frozen `states × byte_classes` table — a bare table walk, zero decode | the frozen table (`ro_data` at comptime / heap at runtime); **empty `Scratch`** | **span-only** (`caps.captures = false`) | **the default span arm** (`isMatch`/`find`); captures come from the Pike VM |
| `dfa` | **lazy DFA**: determinizes the byte NFA on the fly, one DFA *state*/byte via a cached `(state, class)` table; O(input) `find` (forward end + reverse start). Handles `\b`/`\B` (Unicode, decode-hybrid), anchored-end `$`, and a single **leading `(?m)^`** (line-gated re-seed + reverse line-accept — the quadratic-immune line support the eager DFA's anchored-restart declines, e.g. `log_line`) | the transition cache in `Scratch` (heap; runtime-only) | **span-only** (`caps.captures = false`) | **the fallback** when the eager DFA overflows `max_states` or declines (prone `(?m)^`, big Unicode class) |
| `auto` | dispatcher over the others | per sub-backend | ✅ | the default |

## The shared NFA

`pikevm` and `backtrack` are **not** independent engines — they execute the *same*
`nfa.Program` (compiled once by `../nfa.zig`), just traversed differently (breadth-first
vs depth-first). The shared compiler guarantees they agree bit-for-bit on match and
capture semantics; they differ only in performance constants. `literal` is the one
independent code-point matcher (and only for pure literals).

## The byte substrate

`bytepike`, `edfa`, and `dfa` execute the **byte** automaton from `../byte.zig` (the UTF-8
`utf8-ranges` lowering), not the code-point `nfa.Program`. Matching a Unicode class therefore
needs **zero decode** — the Unicode-ness is baked into the byte transitions at build. Two
properties fall out for all three:

- **Dead-on-invalid UTF-8.** The lowering only emits well-formed UTF-8 sequences, so a
  malformed byte has no transition and a match never spans it — no validity check, no decode
  in the hot loop.
- **Leftmost-first, agreeing with the Pike VM.** Determinization (or `bytepike`'s thread
  closure) keeps the NFA states in **priority order** and **cuts on match** — exactly the
  Pike VM's leftmost-first rule, lifted into a DFA state.

The substrate gate is `byteLowerable(hir)`: **no `\X`** (a grapheme cluster is variable-width).
`\b`/`\B` **do** lower — they become a byte `assertion` evaluated as an **ASCII** word boundary
(`isAsciiWordByte` on the adjacent bytes). A byte cannot classify a *code point's* word-ness (a
continuation byte is part of a word char after one lead and a non-word char after another), so:
the **eager DFA** bakes the ASCII boundary into byte classes (fast, frozen), the **lazy DFA**
evaluates the full **Unicode** boundary by decoding the adjacent code points at match time
(`decode-hybrid`), and the dispatcher (`auto`) routes a `\b` program's **ASCII** input to the eager
DFA, its **non-ASCII** input to the lazy DFA, and anything either declines to the Pike VM (which
also evaluates Unicode `\b`). `byteWorthLowering(hir)` adds a cost gate — a pathologically large
byte automaton (a big Unicode class repeated dozens of times, `\p{L}{60}`) declines the byte path
and stays on the compact code-point engine.

**Byte-DFA leftmost-first safety gates (v0.5.0).** The byte DFAs match leftmost-**longest** over the
merged automaton, which silently loses the Pike VM's leftmost-**first** priority around empty/zero-width
constructs. `dfa.supports`/`edfa.supports` therefore **decline** the following shapes to the Pike VM
(correct + O(input)); each is a `hir.Analysis` flag, surfaced by the fuzz suite + external Rust oracle,
and pinned by a conformance regression whose controls keep the benchmarked fast paths (`\bthe\b`,
`\b\w+\b`, `\d+$`, `^abc$`, `(?m)^\w+`, `(?m)foo$`) DFA-eligible:

| Flag | Declines (example) | Why |
|---|---|---|
| `word_boundary_in_alternation` | `\b\|.` | empty-`\b` branch must win, DFA takes the longer |
| `word_boundary_with_nullable_alternation` | `\B(?:\|.*)` | empty-branch priority beside a boundary |
| `word_boundary_with_lazy_repetition` | `a*?\b`, `[^a]+?\B *` | lazy "prefer fewer" vs longest-match |
| `word_boundary_with_adjacent_repetition` | `\n+(\n.*){0,2}\b` | two adjacent reps + `\b`: ambiguous split, boundary holds early & late |
| `word_boundary_after_varying_alternation` | `(b+\|.+)\B` | `\b`/`\B` after an overlapping-first alternation: eager DFA loses branch priority (lazy DFA is fine — eager arm only) |
| `word_boundary_in_repetition` | `(b.{0,2}\B)+` | `\b`/`\B` inside a repetition: boundary end ambiguous across iterations, eager DFA takes the longer (lazy DFA is fine — eager arm only) |
| `nullable_alternation_in_repetition` | `(?:\|.)+` | nullable-alternation empty-loop priority the DFA can't reproduce; Pike VM is leftmost-first correct |
| `interior_text_end` | `$b$`, `\z.?\z`, `$^\z` | a non-trailing `$`/`\z` is masked by a trailing one |
| `complex_line_anchor` | `(?m:$\n)`, `(?m:\n$)*`, `(?m:$)\A`, `(?m:$^)`, `(?m:$)\|.` | `(?m)` anchor non-trailing / under-rep / anchor-mixed / `$^` (line_end before line_start) / in an alternation branch |

Conservative by design (whole-pattern co-occurrence): they may forgo the DFA on an uncommon pattern
that would have been fine, but never trade correctness. (See `../../../fuzz/README.md`.)

## How `auto` dispatches

```
build time (by analysis):
  literal.supports(hir) ?                         → literal               (route "literal")
  else → shared nfa.Program  (+ a POD prefilter Filter distilled from hir.Analysis)
  byte DFA arm?  byte_engine != .disabled
              && byteWorthLowering(hir)
              && edfa.supports(hir) ?             → + eager DFA           (route "nfa+edfa")
                  ↳ byte NFA > EAGER_BYTE_INST_MAX (big Unicode join: \w+@\w+, email)
                    OR eager overflows max_states, && dfa.supports(hir) ?
                                                  → + lazy DFA (fallback) (route "nfa+dfa")
                  ↳ neither                       → NFA only              (route "nfa")

search time (span / prefilter): input shorter than min_utf8_len ?         → no match
                                anchored_start ?                          → only offset 0
                                (?m)^ & no eager DFA (line_anchored) ?     → attempt anchored at each line start
                                leading fixed literal ?                   → SIMD memmem its whole run
                                  ↳ \b-wrapped pure literal (lit_wb_confirm)? → O(1) boundary check, no automaton
                                interior anchor after a fixed run (\d{4}-…)?  → jump to anchor, bounded-confirm at q−off
                                leading selective class (\d+, \p{N}+) ?   → SIMD scan to next class byte
                                rarest required byte absent from input ?  → no match (fast-reject)
search time (NFA, by input):    no DFA arm, input ≤ 4096 B and fits ?     → backtrack : → pikevm
```

When a DFA arm is present it serves the **span** ops (`isMatch`/`find`); `searchCaptures`
runs the Pike VM **anchored at the DFA-found span start** (the capture handoff — an O(input)
capture search becomes O(match)). Both NFA arms run the identical program, so the per-input
backtrack/pikevm switch is invisible — same match, same captures. The prefilter facts are
sound one-sided bounds (hold for *every* match), so a skip never drops a real match.
`auto.route(&program)` reports `"nfa+edfa"`, `"nfa+dfa"`, `"nfa"`, or `"literal"`.

### The byte DFA arm (on by default)

`Options.strategy.byte_engine` defaults to `.auto` (≡ `.enabled`), so the byte DFA is built
**by default** — building it is a strict throughput win (~5–10× the code-point engine on a
class scan, never slower; class scans are now at Rust-`regex` parity). `auto` **prefers the
eager DFA** and falls back to the **lazy DFA** when the eager one declines a pattern because its
full state space overflows `edfa.max_states` (4096), then to the NFA. For a **`\b`/`\B` program**
the lazy DFA is *also* built alongside the eager one as the **non-ASCII arm**: `auto` runs the
eager DFA (ASCII boundary) on ASCII input and the lazy DFA (Unicode boundary, decode-hybrid) on
non-ASCII input — the latter chosen per search by a cached input-ASCII check (so a `count`/`findAll`
over one input pays the scan once). `.disabled` opts back to the compact NFA-only program.

- **Eager (`edfa`) — preferred, comptime + runtime.** Fully determinizes the byte NFA at
  build into a frozen `states × byte_classes` table, so its `Scratch` is **empty**
  (`caps.stateless = true`) and it runs at **comptime** — baking the table into `ro_data` —
  as well as runtime. `find` is **O(input) on every pattern**, chosen statically at build by
  `program.prone`: a *non-prone* pattern (its consuming loop is itself accepting — `\w+`,
  `\d+`, `[A-Za-z]+`) uses one greedy **anchored restart**; a *prone* pattern (`\w+@\w+`'s
  pre-`@` word run, `[ab]*c`) uses the **reverse-DFA two-pass** (a forward pass locates the
  match end, a frozen reverse DFA the start) — no Θ(n²). `edfa.supports` accepts `\A`/`^`
  (`text_start`), **`$`/`\z`** (`text_end`), and **isolated `\b`/`\B`** (`text_start`/`$`/`(?m)`
  combos and chained `\b\b` excepted). A `\b` program runs on **anchored restart with ASCII word
  context**: the ASCII word set is isolated into byte classes, the start state is chosen by the
  preceding byte's word-ness, and acceptance uses a one-byte word-lookahead (the mirror of `(?m)$`'s
  `\n`-lookahead) — an **ASCII** boundary, frozen into the table with zero match-time decode. It
  builds **only the tables it uses** — a non-prone `\w+` keeps just its forward table (~141 KB), not
  forward + `.*?`-prefix + reverse.
- **Lazy (`dfa`) — the fallback, runtime-only.** Determinizes on the fly, caching
  `(state, class)` edges in the caller-owned `Scratch` (bounded by
  `ScratchOptions{ max_bytes, on_full }`), so it materializes only the states an input
  actually visits (a handful over ordinary text) — the right tool when the eager table is too
  large. It is **runtime-only** (the cache mutates while matching, which const-eval cannot do).
  It also carries the **Unicode `\b`/`\B`** the eager DFA can't: a `\b` program runs the
  **decode-hybrid** — consumption stays the cached byte-DFA walk, but a state holding a pending
  boundary decodes the adjacent code points at match time (`nfa.assertionHolds`, the Pike VM's own
  routine — Unicode-correct), so only sparse boundary positions pay a decode. `auto` routes a `\b`
  program's **non-ASCII** input here (its ASCII input goes to the faster eager DFA). Its plain
  `find` is also O(input) (a forward end-pass + a reverse DFA for the start; a `\b` program uses
  anchored restart, as a decoded boundary can't be reversed).

Both DFAs are span-only; the Pike VM fills captures (it also remains the fallback for anything the
DFAs decline — a `\b` combined with `$`/`(?m)`, a chained `\b\b`, a prone `\b`, `\X`). The eager DFA
evaluates **ASCII** `\b`, the lazy DFA **Unicode** `\b`, the Pike VM **Unicode** `\b` — all agree.
The DFA span *is* the leftmost-first match, so every switch is results-invariant: `conformance.zig`
pins every DFA span (and the handed-off captures) to the Pike VM, runtime and comptime — including
`\b`/`\B` over non-ASCII input for the lazy DFA — and fuzzes the `byte_engine`/`prefilter` knobs on↔off.

## Notes

- **`backtrack`'s memory grows with input** (`program × (input+1)` bits). A heap `Scratch`
  grows it; a fixed-buffer `Scratch` caps it — `fits()` reports the ceiling, which is why
  `auto` only routes small inputs (≤ 4096 B) to it.
- **`pikevm` is the general backstop** — constant memory, linear time, no input ceiling — and
  the engine that fills captures for the DFA span arm.
- **`\X` (grapheme) is `backtrack`-only** (`caps.grapheme = true` on `backtrack` and `auto`).
  `\X` compiles to a variable-width `grapheme` NFA instruction; the breadth-first `pikevm`,
  the byte backends, and `literal` set `caps.grapheme = false` and reject such a program at
  build, so `auto` routes any `\X` pattern to the backtracker.
- **`edfa` and `dfa` are the worked examples of a span-only backend** — `caps.captures =
  false` matchers over the shared `byte.Program` substrate that consume `ByteClasses`. `edfa`
  is the stateless, comptime-bakeable, frozen-table form; `dfa` the runtime-only, lazily-cached
  form. To add your own backend, implement the contract and either route to it from a copy of
  `auto.zig` or select it directly via `compile*With`. See
  [`../../../docs/architecture.md`](../../../docs/architecture.md) §5 and §10, and the
  step-by-step, runnable walkthrough in
  [`../../../docs/usage-guide.md`](../../../docs/usage-guide.md) §8.
