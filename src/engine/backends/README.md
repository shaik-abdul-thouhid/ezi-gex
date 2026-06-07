# backends/ — the built-in matchers

Four backends. All satisfy the same contract (`../backend.zig`), all build and run at
**comptime and runtime**, all are leftmost-first (Perl/JS). `auto` is the default.

| Backend | Strategy | Memory | Captures | When `auto` picks it |
|---|---|---|---|---|
| `literal` | substring / literal-alternation byte scan | none (stateless) | whole-match only | pure-literal pattern (`abc`, `cat\|dog`) |
| `pikevm` | breadth-first NFA (thread set, one code point/step) | O(program), input-independent | ✅ | NFA pattern, large input |
| `backtrack` | depth-first NFA + `(pc,sp)` memo | O(program × input) | ✅ | NFA pattern, small input that fits |
| `auto` | dispatcher over the three | per sub-backend | ✅ | the default |

## The shared NFA

`pikevm` and `backtrack` are **not** independent engines — they execute the *same*
`nfa.Program` (compiled once by `../nfa.zig`), just traversed differently
(breadth-first vs depth-first). The shared compiler guarantees they agree bit-for-bit
on match and capture semantics; they differ only in performance constants. `literal`
is the one independent matcher (and only for pure literals).

## How `auto` dispatches

```
build time  (by analysis):  literal.supports(hir) ? → literal   :  → shared nfa.Program
search time (by input):     nfa pattern, input ≤ 4096 B and fits scratch ? → backtrack : → pikevm
```

Both NFA arms run the identical program, so the per-input switch is invisible — same
match, same captures. `auto.route(&program)` reports `"literal"` or `"nfa"` for tests.

## Notes

- **`backtrack`'s memory grows with input** (`program × (input+1)` bits). A heap
  `Scratch` grows it; a fixed-buffer `Scratch` caps it — `fits()` reports the ceiling,
  which is why `auto` only routes small inputs to it.
- **`pikevm` is the general backstop** — constant memory, linear time, no input ceiling.
- **None support `\X`** (`caps.grapheme = false`); such a pattern fails at build.
- To add a fifth backend (e.g. a lazy DFA), implement the contract and either route to
  it from a copy of `auto.zig` or use it directly via `compile*With`. See
  [`../../../docs/architecture.md`](../../../docs/architecture.md) §5 and §10.
