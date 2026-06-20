# ezi_gex — known limitations

A short, honest list of the places where ezi_gex does **not** behave the way you might
expect, why, and what to do about it. For how the engine works see
[`architecture.md`](architecture.md); for the public API see
[`usage-guide.md`](usage-guide.md).

Every entry below is **Deliberate** — a semantic choice ezi_gex makes on purpose. It will
not "get fixed"; it is the defined behaviour. The cross-backend conformance suite and the
fuzz differential (`fuzz/`) pin all of it so it cannot silently change.

> **No deferred bugs.** As of v0.6.0 there are no known correctness gaps where one backend
> disagrees with another. The two former deferred entries — an empty-width loop over a
> nullable concat body (`(?:a?b??)+`), and a `\b`/`\B` after a length-varying alternation
> (`(b+|.+)\B`) — are both **fixed** and every backend now agrees on the leftmost-first
> span. See the [CHANGELOG](../CHANGELOG.md) (v0.6.0).

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
