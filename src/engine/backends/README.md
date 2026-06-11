# backends/ — the built-in matchers

Six backends. All satisfy the same contract (`../backend.zig`) and are leftmost-first
(Perl/JS). All build and run at **comptime and runtime** *except* `dfa`, which is
runtime-only (its cache mutates at match time). `auto` is the default.

| Backend | Strategy | Memory | Captures | When `auto` picks it |
|---|---|---|---|---|
| `literal` | substring / literal-alternation byte scan | none (stateless) | whole-match only | pure-literal pattern (`abc`, `cat\|dog`) |
| `pikevm` | breadth-first NFA (thread set, one code point/step) | O(program), input-independent | ✅ | NFA pattern, large input |
| `backtrack` | depth-first NFA + `(pc,sp)` memo | O(program × input) | ✅ | NFA pattern, small input that fits |
| `bytepike` | breadth-first **byte** NFA (`../byte.zig`), one *byte*/step, zero-decode | O(program); program is larger for Unicode classes | ✅ | never (not a default arm) — the byte-lowering reference VM / DFA substrate; refuses `\X`/`\b` |
| `dfa` | **lazy DFA**: determinizes the byte NFA on the fly, one DFA *state*/byte via a cached `(state, class)` table | the transition cache in `Scratch` (heap; runtime-only) | **span-only** (`caps.captures = false`) | the span scan (`isMatch`/`find`) when `byte_engine = .enabled` and the pattern is eligible (no `\b`/`\X`/`$`/line anchors; `\A`/`^` are fine); captures still come from the Pike VM |
| `auto` | dispatcher over the others | per sub-backend | ✅ | the default |

## The shared NFA

`pikevm` and `backtrack` are **not** independent engines — they execute the *same*
`nfa.Program` (compiled once by `../nfa.zig`), just traversed differently
(breadth-first vs depth-first). The shared compiler guarantees they agree bit-for-bit
on match and capture semantics; they differ only in performance constants. `literal`
is the one independent matcher (and only for pure literals).

## How `auto` dispatches

```
build time  (by analysis):  literal.supports(hir) ? → literal   :  → shared nfa.Program
                            distil a POD prefilter Filter from hir.Analysis (NFA arm)

search time (NFA, prefilter): input shorter than min_utf8_len ?            → no match
                              anchored_start ?                              → only offset 0
                              every match starts with a fixed literal ?     → memchr its
                                first byte, confirm each hit with an anchored NFA run
search time (NFA, by input):  no usable filter → input ≤ 4096 B and fits ? → backtrack : → pikevm
```

The prefilter facts are **sound one-sided bounds** (true for every match), so the
skip never drops a real match. Both NFA arms run the identical program, so the
per-input switch is invisible — same match, same captures. The `literal` backend
itself scans with `std.mem.indexOf` (SIMD memchr / Boyer–Moore–Horspool), not an
`eql` per position. `auto.route(&program)` reports `"literal"`, `"nfa"`, or `"dfa"`.

### The byte lazy DFA arm (opt-in)

With `Options.strategy.byte_engine = .enabled` (projected onto the backend by the
front door), `auto` also builds a byte lazy DFA (`dfa.zig`) for any NFA-arm pattern the
DFA can run (`dfa.supports`: byte-lowerable, no `$`/line anchors — `\A`/`^` are fine).
It then uses the
DFA for the **span scan** — `isMatch`/`search` — and the Pike VM for `searchCaptures`,
since the DFA is span-only. The two agree on the span by construction (priority +
cut-on-match determinization is the Pike VM's leftmost-first rule), so the switch is
results-invariant; `conformance.zig` pins it. The default (`.auto`) leaves the DFA off.
The DFA is **runtime-only**, so the comptime path (`buildComptime`/`initBuffer`) never
builds it and stays on the NFA program.

## Notes

- **`backtrack`'s memory grows with input** (`program × (input+1)` bits). A heap
  `Scratch` grows it; a fixed-buffer `Scratch` caps it — `fits()` reports the ceiling,
  which is why `auto` only routes small inputs to it.
- **`pikevm` is the general backstop** — constant memory, linear time, no input ceiling.
- **`\X` (grapheme) is `backtrack`-only** (`caps.grapheme = true` on `backtrack` and
  `auto`). `\X` compiles to a variable-width `grapheme` NFA instruction; the
  breadth-first `pikevm` and the `literal` backend set `caps.grapheme = false` and
  reject such a program at build, so `auto` routes any `\X` pattern to the backtracker.
- The `dfa` backend is the worked example of adding a non-trivial engine: a span-only
  (`caps.captures = false`), runtime-only (`buildAlloc` only) matcher that reuses the
  shared `byte.Program` substrate and consumes `ByteClasses` — see `dfa.zig`. To add
  another, implement the contract and either route to it from a copy of `auto.zig` or
  use it directly via `compile*With`. See
  [`../../../docs/architecture.md`](../../../docs/architecture.md) §5 and §10, and the
  step-by-step, runnable walkthrough in
  [`../../../docs/usage-guide.md`](../../../docs/usage-guide.md) §8.
