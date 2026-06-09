# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
