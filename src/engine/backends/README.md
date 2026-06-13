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
| `bytepike` | breadth-first **byte** NFA (`../byte.zig`), one *byte*/step, zero-decode | O(program); larger for Unicode classes | ✅ | **never** — the byte-lowering reference VM / DFA substrate; refuses `\X`/`\b` |
| `edfa` | **eager DFA**: fully determinizes the byte NFA at build into a frozen `states × byte_classes` table — a bare table walk, zero decode | the frozen table (`ro_data` at comptime / heap at runtime); **empty `Scratch`** | **span-only** (`caps.captures = false`) | **the default span arm** (`isMatch`/`find`); captures come from the Pike VM |
| `dfa` | **lazy DFA**: determinizes the byte NFA on the fly, one DFA *state*/byte via a cached `(state, class)` table | the transition cache in `Scratch` (heap; runtime-only) | **span-only** (`caps.captures = false`) | **the fallback** when the eager DFA overflows its `max_states` bound |
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

The substrate gate is `byteLowerable(hir)`: **no `\X`, no `\b`/`\B`** (a word boundary needs
the adjacent *code point*, not a byte). `byteWorthLowering(hir)` adds a cost gate — a
pathologically large byte automaton (a big Unicode class repeated dozens of times,
`\p{L}{60}`) declines the byte path and stays on the compact code-point engine.

## How `auto` dispatches

```
build time (by analysis):
  literal.supports(hir) ?                         → literal               (route "literal")
  else → shared nfa.Program  (+ a POD prefilter Filter distilled from hir.Analysis)
  byte DFA arm?  byte_engine != .disabled
              && byteWorthLowering(hir)
              && edfa.supports(hir) ?             → + eager DFA           (route "nfa+edfa")
                  ↳ eager overflows max_states && dfa.supports(hir) ?
                                                  → + lazy DFA (fallback) (route "nfa+dfa")
                  ↳ neither                       → NFA only              (route "nfa")

search time (span / prefilter): input shorter than min_utf8_len ?         → no match
                                anchored_start ?                          → only offset 0
                                leading fixed literal ?                   → memchr its 1st byte
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
eager DFA** and falls back to the **lazy DFA** only when the eager one declines a pattern
because its full state space overflows `edfa.max_states` (4096), then to the NFA. `.disabled`
opts back to the compact NFA-only program.

- **Eager (`edfa`) — preferred, comptime + runtime.** Fully determinizes the byte NFA at
  build into a frozen `states × byte_classes` table, so its `Scratch` is **empty**
  (`caps.stateless = true`) and it runs at **comptime** — baking the table into `ro_data` —
  as well as runtime. `find` is **O(input) on every pattern**, chosen statically at build by
  `program.prone`: a *non-prone* pattern (its consuming loop is itself accepting — `\w+`,
  `\d+`, `[A-Za-z]+`) uses one greedy **anchored restart**; a *prone* pattern (`\w+@\w+`'s
  pre-`@` word run, `[ab]*c`) uses the **reverse-DFA two-pass** (a forward pass locates the
  match end, a frozen reverse DFA the start) — no Θ(n²). `edfa.supports` accepts `\A`/`^`
  (`text_start`) **and `$`/`\z`** (`text_end`). It builds **only the tables it uses** — a
  non-prone `\w+` keeps just its forward table (~141 KB), not forward + `.*?`-prefix + reverse.
- **Lazy (`dfa`) — the fallback, runtime-only.** Determinizes on the fly, caching
  `(state, class)` edges in the caller-owned `Scratch` (bounded by
  `ScratchOptions{ max_bytes, on_full }`), so it materializes only the states an input
  actually visits (a handful over ordinary text) — the right tool when the eager table is too
  large. It is **runtime-only** (the cache mutates while matching, which const-eval cannot do)
  and **narrower** than the eager DFA: `dfa.supports` declines `$`/`\z`, so a `$` pattern
  routes to the eager DFA, or to the NFA if that overflows. Its `find` is also O(input) (a
  forward end-pass + a reverse DFA for the start).

Both DFAs are span-only; the Pike VM fills captures and evaluates `\b`. The DFA span *is* the
leftmost-first match, so the switch is results-invariant — `conformance.zig` pins every DFA
span (and the handed-off captures) to the Pike VM, runtime and comptime, and fuzzes the
`byte_engine`/`prefilter` knobs on↔off.

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
