# ezi_gex fuzzing

Coverage-guided fuzz targets on Zig's `std.testing.fuzz` + `Smith`, driving the **published
`ezi_gex` module** exactly as a downstream user would. The suite is deliberately cynical: it
does not trust any one engine, any hand-written expectation, or its own reach. It checks every
backend against an **independent reference matcher**, against equivalent spellings of the same
pattern, and against oracle-free laws. It also checks that each check actually compared
something — a check that silently skips everything fails the build.

## Layout

| Path | What it is |
|------|------------|
| `lib.zig` | The `fuzz_lib` module: `gen`, `ref` and `check` namespaces, shared by every group, the health tests and `fuzz-min`. |
| `gen/` | Generators. `pattern.zig` (three `Smith` pattern generators), `tree.zig` (a **semantic pattern tree** with random construction), `print.zig` (prints a tree in many equivalent spellings), `witness.zig` (inputs the tree must match), `input.zig` (evil UTF-8, 12 KiB inputs with planted witnesses, fold-swapped copies), `literals.zig`, `props.zig`, `replay.zig` (small-word seed streams — see below). |
| `ref/` | The **independent reference matcher**: a Thompson construction plus a naive Pike VM over the semantic tree, with its own Unicode lookups (`uni.zig`). It shares nothing with the engine past `ezi_code`'s tables, so a bug in the engine's shared scanner → AST → HIR → NFA front end shows up as a disagreement. |
| `check/` | One file per property (table below), plus `common.zig` (the `Case` + replay line, backends, counters), `known_open.zig` (gates + auto-minimized reporting), `minimize.zig`, `registry.zig`. |
| `groups/*.zig` | 19 thin groups, one test binary each, so they fuzz in parallel. |
| `health.zig` | Vacuity guards (see Health). |
| `findings.zig` | The known-open ledger: minimized cases that must still fail until fixed. |
| `threads.zig` | Four threads sharing compiled programs must get the serial answers. |
| `min.zig` | `zig build fuzz-min`: replay and shrink one `FUZZ-CASE` line. |
| `root.zig` | Pulls every group into one binary, so `zig build test` runs the suite finitely. |

## Running

```sh
zig build test-fuzz -Doptimize=ReleaseSafe      # finite: seed corpora, health floors, ledger, threads
zig build fuzz -Doptimize=ReleaseSafe           # finite smoke of all 19 groups, in parallel (~1 min)
zig build fuzz-oom -Doptimize=ReleaseSafe --fuzz=5000   # one group, 5000 iterations (~1 min)
zig build fuzz -Doptimize=ReleaseSafe --fuzz=100K       # every group, 100K iterations EACH
```

> ⚠️ Bare `--fuzz` (no `=N`) soaks forever by design — always pass `=N`. Iteration cost
> differs a lot by group: `oom`, `iter`, `search` and `invariants` are the heavy ones. Size `N`
> per group rather than giving every group the same large number.

## What the groups check

The **Pike VM** is the in-process oracle (linear-time, capture-complete, every feature bar `\X`).
Any other backend that accepts a pattern must agree byte for byte. A backend that declines
(`Unsupported`, a resource ceiling) is counted as skipped, never compared.

| Group | Property |
|-------|----------|
| `scanner` | `parseWith` never crashes on arbitrary bytes; the `{m,n}` ceiling is exact; mutated patterns get located diagnostics on reject and agree on accept. |
| `diff` | span / `find` / `isMatch` across all backends; `isMatch == (find != null)`. |
| `anchors` | anchor- and zero-width-heavy patterns over newline-rich input. |
| `unicode` | `\p{}`/scripts/`(?i)` over valid and raw UTF-8; `\X` against a grapheme oracle. |
| `captures` | full capture-slot arrays across the capture backends. |
| `iter` | the `findAll` sequence and `count`; `$`-template `replaceAll` output. |
| `search` | `findAt` with `start`/`anchored`/`span_end`; strategy flags never change a match. |
| `reference` | pikevm / backtrack / `auto` agree with the **independent reference** on span, every capture slot and the `findAll` sequence, over trees printed in a random equivalent spelling. |
| `metamorphic` | two equivalent printings of one tree behave identically; under `(?i)`, swapping input characters for fold-equivalents changes nothing. |
| `invariants` | oracle-free laws on every backend (`find` inside `isMatch`, `findAll` ordered and non-overlapping, anchored ⇒ starts at `start`, …). |
| `state` | a long-lived, dirty scratch (random op scripts, reused across inputs) behaves like a fresh one. |
| `large` | 12 KiB inputs across `auto`'s 4096-byte backtrack/Pike-VM cut and SIMD block edges, with planted witnesses. |
| `literals` | literal-set searches across backends and strategy flags. |
| `api` | the whole public search / replace / split surface. |
| `oom` | an allocation failure at a sampled point surfaces as `OutOfMemory` with nothing leaked; `auto` absorbs a mid-search failure and still returns the Pike VM's answer. |
| `comptime_parity` | comptime-compiled programs agree with runtime-compiled ones. |
| `complexity` | matching work stays linear (the backtracker's memo-probe counter, input doubling); `auto` never does per-occurrence confirms on an end-anchored pattern; compile bombs stay under a peak-memory budget **and** doubling the outer count at most ~doubles it. |
| `utf8class` | byte-lowered UTF-8 classes against code-point ground truth. |
| `chaos` | one generated case through every check that can take it. |

**Byte-engine ASCII-`\b`.** `bytepike`/`dfa`/`edfa` evaluate `\b`/`\B` as ASCII word boundaries
(`auto` routes non-ASCII `\b` to the code-point engines), so for a `\b` pattern over non-ASCII
input the byte engines are skipped, not compared. A malformed byte is non-word in both contracts.

## Replay-mode Smith

Every draw reads one little-endian `u64`, and an out-of-range word falls back to the range
**minimum**. So generators use count draws, not `eos`; they put the interesting branch at the
minimum; and seed corpora are small-word streams (`gen/replay.zig`). A choice that must be even,
such as `oom`'s backend, is hashed from the case rather than drawn.

## Health

`health.zig` runs every check over fixed seeds and asserts three things:

- **Nothing fails.** A failure found while measuring is replayed loudly (replay line plus
  minimized case) and fails the test. This is not just a count: one real divergence once sat
  unreported in these seeds.
- **Every check reaches its logic** (a floor on valid cases per seed).
- **Every backend is actually compared** on at least a floor fraction of valid cases, and no
  known-open gate swallows more than 1 % of cases.

Floors are about 0.8 × the measured value (the `rows` table). A floor that trips is a finding
first (vacuity) and a floor change second, with a stated reason.

## Triaging a finding

Every failure prints the check, the pattern and input, a replayable `FUZZ-CASE` line, and an
**auto-minimized** case. For tree cases it also prints the canonical spelling. To reproduce or
shrink a case again:

```sh
zig build fuzz-min -Doptimize=ReleaseSafe -- 'FUZZ-CASE check=… pat=… in=…'
```

It exits 1 if the case no longer reproduces. Then decide whether it is a real bug or a
documented contract (such as the ASCII-`\b` byte engines):

- **Fixing now:** pin the minimized case as a `src/engine/conformance.zig` (or unit)
  regression, fix, and note it in the CHANGELOG.
- **Fixing later:** add a ledger entry in `findings.zig` and a narrow gate in
  `check/known_open.zig`. The ledger test fails when the case stops reproducing, which is the
  cue to move it into `conformance.zig` and delete both.

**Minimize before theorizing.** More than one finding was first blamed on the wrong feature.
The minimized case, not the first stack trace, names the cause.

## Findings so far

The fix history is in the [CHANGELOG](../CHANGELOG.md). The durable shape:

- The early differential found divergences almost entirely in the **byte-DFA span path** and
  the **`auto` dispatcher**: leftmost-longest DFAs losing leftmost-first priority, and
  empty-width-loop priority over nullable bodies.
- The **independent reference** and **metamorphic** checks then found bugs that every backend
  shared, because they sat in the common front end: `\b` reading a malformed byte as a word
  character when looking backward, and `(?i)` not folding property classes. Backend agreement
  alone could never have caught these.
- The **allocation-failure** and **compile-bomb** checks found resource bugs: search-time
  panics and a leak under OOM, quadratic compile memory from the one-pass accelerator
  (`(?:(a)){10000}` asked for 21 GB), and quadratic compile time from a per-state clear.

## Cross-engine (external oracle)

Diffing against an independent *engine* (Rust `regex`) is a cross-language activity and lives
outside this repository. ezi follows RE2/Rust leftmost-first semantics throughout, including
the empty-loop rule and fold-before-negate for `(?i)` classes, so the two can be compared
directly across the ASCII space.

## Open (to triage)

Nothing open. New findings go in `findings.zig` plus `check/known_open.zig` until they are fixed.
