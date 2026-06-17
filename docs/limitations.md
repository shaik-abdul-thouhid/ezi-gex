# ezi_gex — known limitations

A short, honest list of the places where ezi_gex does **not** behave the way you might
expect, why, and what to do about it. For how the engine works see
[`architecture.md`](architecture.md); for the public API see
[`usage-guide.md`](usage-guide.md).

Two kinds of entry appear below:

- **Deliberate** — a semantic choice ezi_gex makes on purpose. It will not "get fixed";
  it is the defined behaviour.
- **Deferred** — a real bug with a known fix that has been scoped but not yet landed,
  because the fix is disproportionately invasive relative to how rare the trigger is.
  The **default `auto` engine is unaffected**; only a specific backend chosen directly is.

The cross-backend conformance suite and the fuzz differential (`fuzz/`) both pin these so
they cannot silently change.

---

## Deferred

### Empty-width loop over a nullable *concat* body (Pike VM / backtracker only)

**Symptom.** An unbounded repetition (`*`, `+`, `{m,}`) whose body is a **concatenation
that can match the empty string and contains a lazy quantifier** over-consumes on the
`pikevm` and `backtrack` backends:

| pattern | input | `auto` (and Rust `regex` / RE2) | `pikevm` / `backtrack` direct |
|---|---|---|---|
| `(?:a?b??)+`  | `"ab"` | `"a"` ✅ | `"ab"` ✗ |
| `(?:a??b??)+` | `"ab"` | `""` ✅  | `"a"`  ✗ |

**Why.** ezi follows leftmost-first (Perl/JS/Rust-style) semantics, under which a
repetition iteration that matches the empty string terminates the loop. The **byte DFA
implements this correctly**, so the default `auto` engine — which runs the DFA on all but
the tiniest inputs — returns the right answer. The Pike VM's epsilon-closure does not yet
carry the empty-width-loop guard, so a greedy outer loop over a nullable lazy body keeps
consuming. A correct fix is a guard inside the Pike VM closure (and the backtracker);
it is **deferred** because it is a deep change to the core matcher and the trigger is a
pathological nested-lazy shape.

The related **single-repetition** form (`(?:c*?)+`, `(?:a??){3,}`) *is* fixed: it is an
algebraic identity (`(S*)* ≡ S*`, `(S??){3,} ≡ S*?`) collapsed in HIR, so every backend
agrees. Only the **concat-body** form remains, because a concatenation is not a single
repetition that can be widened.

**What to do.** Use the default `auto` engine (or the `dfa`/`edfa` byte backends) for
these patterns — they are correct. Pin: `empty_loop_concat_auto_cases` in
`src/engine/conformance.zig`. A long `--fuzz` run on the iteration/anchor differentials
will re-surface this class (they assert `pikevm == auto`); that is this known gap, not a
new bug.

### `\b`/`\B` after a length-varying alternation (eager DFA / `auto`)

**Symptom.** A `\b`/`\B` *following* an alternation whose branches can match the same start
at **different lengths** loses leftmost-first priority on the **eager** byte DFA — and so
on `auto`, which routes ASCII `\b` to the eager arm:

| pattern | input | `pikevm` / `backtrack` / lazy `dfa` | `edfa` / `auto` |
|---|---|---|---|
| `(b+\|.+)\B`   | `"baaa"`  | `"b"` ✅ | `"baa"` ✗ |
| `(?:b\|baaa)\B`| `"baaab"` | `"b"` ✅ | `"baaa"` ✗ |

**Why.** Leftmost-first must try the first branch first: `b+` matches `"b"`, then `\B` holds
between `b` and `a`, so the match is `"b"` and the later `.+` branch is never tried. The
eager DFA's word-boundary determinization (the ASCII byte-class state-splitting that makes
`\b\w+\b` fast) doesn't preserve that branch priority once a boundary follows, so it accepts
the longest boundary-valid position instead. This is the **same eager-DFA `\b`-priority
theme** as `word_boundary_with_adjacent_repetition`; the *lazy* DFA's decode-hybrid boundary
handling gets it right. A correct fix (teach the eager DFA to preserve alternation priority
across a trailing boundary, or route these shapes eager → lazy) is **deferred**.

Unlike the concat-body case above, here **`auto` is affected** (it uses the eager arm for
ASCII `\b`). The trigger is narrow — it needs *overlapping, length-varying* branches before
the boundary; non-overlapping alternations (`(?:b+|a+)\B`) and the common pinned forms
(`\b\w+\b`, `\bthe\b`, `\b(foo|bar)\b`) are unaffected and stay on the DFA fast path.

**What to do.** If you need the leftmost-first span for such a pattern, run it on the
`pikevm` or `backtrack` backend. Pin: `word_boundary_after_alt_ref_cases` in
`src/engine/conformance.zig`. Like the case above, a long `--fuzz` run will re-surface it.

---

## Deliberate

### Empty-alternation loops follow JS, not RE2

A repetition over an alternation with an **empty branch** resolves the empty-iteration
tie the way V8/JavaScript does — the **consuming** branch wins — not the way RE2/Rust/Go
do (they return empty):

| pattern | input | ezi_gex (= JS/V8) | RE2 / Rust |
|---|---|---|---|
| `(\|a)*`  | `"aaa"` | `"aaa"` | `""` |
| `(?:\|a)+` | `"aaa"` | `"aaa"` | `""` |

All ezi_gex backends agree with each other here; this is the defined semantics, not a
divergence between engines. It is consistent with ezi's leftmost-first lineage but
differs from POSIX-leftmost-longest and from RE2's empty-loop rule. If you need RE2's
behaviour, rewrite the alternation so no branch is empty.

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
