# ezi_gex — known limitations

A short, honest list of the places where ezi_gex does **not** behave the way you might
expect, why, and what to do about it. For how the engine works see
[`architecture.md`](architecture.md); for the public API see
[`usage-guide.md`](usage-guide.md).

Every entry under **Deliberate** is a behaviour or a performance trade-off ezi_gex makes on
purpose, and none of it is on the roadmap to change. The semantic choices are pinned by the
cross-backend conformance suite and the fuzz suite (`fuzz/`) so they cannot silently change; the
performance limitations are accepted shapes where the engine is and will remain comparatively
slow.

Every backend agrees on the leftmost-first match (RE2/Rust semantics), at runtime and comptime.
The one known gap — a Unicode property that is approximated — is under **Known gaps** at the end.

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
and rejects such a pattern with `error.PatternTooComplex` before any program is built.

Within the limit, compile time and memory are **linear** in the unrolled size: roughly 150 bytes
of peak memory per unit, plus a few MB fixed for a large Unicode class's DFA construction. So the
default limit admits a single compile of up to ~150 MB. Lower `size_limit` when compiling
untrusted patterns.

### Invalid UTF-8 in the haystack is dead

A malformed byte in the input matches **nothing** — not `.`, not `[^a]`, not `\P{…}` — and no
match spans it; the unanchored scan resyncs one byte past it. For `\b`/`\B` it counts as a
non-word character from either side. There is no byte mode: to search binary or Latin-1 data,
decode or transcode it first. (Pattern bytes must be valid UTF-8; an invalid pattern is a
compile error.)

### Some backends allocate during a search

With the default `auto` backend and a heap `Scratch`, a search may allocate through the
allocator you gave `initScratch`: the backtracker grows its visited set (inputs ≤ 4096 bytes)
and the lazy DFA grows its transition cache. If that allocation fails, `auto` falls back to the
Pike VM and returns the same answer. If you select **`backtrack`** or the lazy **`dfa`**
directly, their plain `search`/`isMatch` **panic** on allocation failure, because the search API
has no error channel. Call `backtrack.reserve` first, or use `dfa.trySearch`/`dfa.tryIsMatch`,
to get `error.OutOfMemory` back instead. A buffer-backed `Scratch` (`initScratchBuffer`) or the
`pikevm` backend never allocates while matching.

### The byte engines evaluate `\b` as ASCII

`bytepike`, `dfa` and `edfa` treat `\b`/`\B` as **ASCII** word boundaries: exact on ASCII
input, but a non-ASCII letter counts as non-word. `auto` routes a `\b` search over non-ASCII
input to the code-point engines, so the default front door is Unicode-correct; you only see the
ASCII behaviour if you select a byte engine directly.

### Case-insensitive classes use simple folding

`Options.case_fold = .full` expands a **literal**'s 1→many foldings (`(?i)ß` also matches `ss`),
but a character class always matches one code point, so `(?i)[ß]` does not match `ss`. A negated
property folds **before** it negates, as in Rust and Perl: `(?i)\p{Lu}` matches `a`, and
`(?i)\P{Ll}` matches no cased letter. (JavaScript's `u`-mode negates first, so there
`/\P{Ll}/iu` matches every letter; ezi_gex does not.)

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

---

## Known gaps

### `\p{scx=…}` matches like `\p{sc=…}`

Script_Extensions resolves to the plain Script ranges, because `ezi_code` does not yet expose
the extension sets as enumerable ranges. A character shared between scripts is therefore missed:
U+30FC KATAKANA-HIRAGANA PROLONGED SOUND MARK has Script=Common and Script_Extensions={Hira,
Kana}, so `\p{scx=Hira}` should match it but does not. Use `\p{sc=…}` plus the shared
characters you need, explicitly, until this is closed.
