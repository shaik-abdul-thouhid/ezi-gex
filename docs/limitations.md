# ezi_gex — known limitations

A short, honest list of the places where ezi_gex does **not** behave the way you might
expect, why, and what to do about it. For how the engine works see
[`architecture.md`](architecture.md); for the public API see
[`usage-guide.md`](usage-guide.md).

Every entry below is **deliberate** — a behaviour or a performance trade-off ezi_gex makes on
purpose. None of it is on the roadmap to change. The semantic choices are pinned by the
cross-backend conformance suite and the fuzz differential (`fuzz/`) so they cannot silently
change; the performance limitations are accepted shapes where the engine is and will remain
comparatively slow.

There are no open correctness limitations: every backend agrees on the leftmost-first match (RE2/Rust
semantics), at runtime and comptime. This page lists only the deliberate trade-offs.

---

## Deliberate

### `\X` (extended grapheme cluster) runs on the backtracker only

`\X` (a UAX #29 grapheme cluster) is supported by the **`backtrack`** backend, and the
default **`auto`** engine handles it by routing any `\X` pattern to the backtracker. It is
**not** available on the linear-time `pikevm`, `dfa`, `edfa`, `bytepike`, `onepass`, or
`literal` backends (their `caps.grapheme == false`). Because `auto` routes automatically,
`\X` "just works" through the default front door; you only hit the limit if you select a
linear-time backend *directly* and compile a `\X` pattern (it declines at build time).

Consequence: a pattern using `\X` does not get the linear-time / DFA guarantees — it runs
under the bounded backtracker. For large inputs over `\X`-heavy patterns, prefer
expressing the intent without `\X` if the linear-time guarantee matters.

### `{m,n}` repetition counts are bounded

The scanner rejects a repetition whose count exceeds a configurable ceiling
(`Options.max_repetition`, default `100_000`) with `quantifier_exceeds_limit`, so a
pattern like `a{999999999}` fails to compile rather than blowing up the program. Raise or
lower it per-compile via `Options.max_repetition` (see `usage-guide.md`). This is a
safeguard, not a matching limitation — within the ceiling, counted repetition is exact.

Nested counts multiply, though: `(?:(?:a{1000}){1000}){1000}` has every count under the
ceiling yet unrolls to ~10⁹ copies. `Options.size_limit` (default `1_000_000`) bounds the
unrolled size, measured arithmetically from the HIR by `hir.expandedSize` in O(pattern) time,
and rejects such a pattern with `error.PatternTooComplex` before any program is built. Lower it
when compiling untrusted patterns.

### Performance shapes ezi_gex does not chase

A handful of pattern shapes are meaningfully slower than the rest of the engine. These are
accepted: they are not bugs and not on the roadmap. Each would only improve by trading away
something the engine will not give up — its linear-time guarantee, its portability (no
hand-written per-architecture SIMD), or its simplicity.

- **An unbounded gap between two required literals** — `Holmes(?:\s*.+\s*){0,10}Watson` and
  similar. Both literals prefilter fine, but the `.+` between them still has to be walked; nothing
  can skip an arbitrary-length span. The common **leading-alternation** form
  (`Holmes…Watson|Watson…Holmes`) is no longer slow — as of 0.6.2 it jump-and-confirms
  prefix-to-prefix with a reach budget. The residual gap is only on shapes where neither literal
  is a sound leading prefix (the match can begin mid-span), where the engine must fall back to
  walking the span.
- **A common single byte as the only distinctive feature** — `\b\w+n\b`. The one selective
  thing is the trailing `n`, which is far too common to prefilter on and too short for the
  literal skip. There is no rare anchor to jump to.
- **A bounded run of a negated class** — `["'][^"']{0,30}[?!.]["']`. The `[^"']{0,30}`
  span is scanned byte by byte. A specialized negated-class skip could shave this, but only on
  this narrow shape and not without growing the DFA machinery.
- **An unbounded case-insensitive alternation** — `(?i:Sher[a-z]+|Hol[a-z]+)`. It is
  prefiltered, but because the branch is unbounded it cannot use the fast per-occurrence confirm
  without risking quadratic time, so it falls back to a slower scan. Keeping the linear-time
  guarantee is worth more than the throughput here. (The *bounded* form,
  `(?i:Sherlock|Holmes|Watson)`, does take the fast path.)
- **A line anchor inside an alternation** — `(?m)^...|...`. This routes to the linear
  Pike VM; the DFAs do not carry `(?m)` line context through an alternation. Correct, just not
  the fast path.
- **Pure-literal alternation throughput** — `Sherlock|Street`. The prefilter is the right one
  (Teddy), but a hand-tuned per-architecture Teddy would scan faster, and that would mean
  per-architecture assembly, which ezi_gex deliberately avoids in favour of portable `@Vector`
  code.
