# Cynical fuzzing — design

**Status:** approved design, pre-plan · **Date:** 2026-09-30 · **Branch:** `fuzz/cynical`

## 1. Goal

Move `fuzz/` from "every backend agrees with the Pike VM on small, fresh, well-formed cases" to a
suite that **trusts nothing**: not the oracle, not fresh state, not well-formed input, not the
allocator, not the size regime, and not the fuzzer itself.

**Success =** the new targets exist and fuzz in parallel like today's groups; `zig build test` still
replays them finitely (≤ 30 s added under `-Doptimize=ReleaseSafe`); a shakedown + ~2 h campaign has
been run; every finding is minimized, gated, and recorded in a ledger; the owner receives a findings
report and **chooses which to fix** (fixes are follow-ups, not part of this effort).

## 2. Why — the blind spots (evidence)

| # | Blind spot | Evidence |
|---|-----------|----------|
| 1 | **Size regime.** Inputs cap at 64 B. | `auto` switches backtrack→Pike VM at 4096 B (`auto.zig:107`); DFA-arm reach budgets and the 4×-unrolled memmem only run on longer inputs. |
| 2 | **Fresh state.** Every call builds a fresh `Scratch`. | 2b48f18 (stale `(ptr,len)`-keyed ASCII cache on buffer refill) is this class and was found outside the fuzzer. `same_input` and `initBuffer` scratches are unfuzzed. |
| 3 | **Shared-front-end oracle.** Pike VM shares scanner→AST→HIR→nfa with every backend. | README: the one front-end bug found was found by an external oracle. Oracle-free invariants run only on the oracle. |
| 4 | **Comptime.** | `compileComptime` / `*Comptime` methods never fuzzed. |
| 5 | **Generator reach.** | 9-char alphabet; classes only `a-c \d \w \p{L}`; 10 properties; `(?x)` emitted without whitespace/comments; no length-changing case folds; no targeted invalid UTF-8; no literal sets aimed at Teddy (≤ 8 branches, prefix ≤ 16 B). |
| 6 | **API reach.** | `split/splitN`, `replace/replaceN`, `replaceAllWith`, `capturesAll`, `capturesAt`, `isMatchAt`, `${name}`/bare-`$` templates unfuzzed. |
| 7 | **Failure paths.** | No allocation-failure injection; scanner target checks only `diag.code != .none`. |

## 3. Decisions (owner-approved)

- **End state:** build → shakedown → campaign → minimize + gate + ledger → findings report. Owner picks fixes.
- **Oracle:** *both* an independent reference matcher **and** metamorphic rewrites.
- **Complexity:** existing counters only (`backtrack.Scratch.steps`, `auto.Scratch.confirm_probes`). **No engine changes.**
- **Structure:** approach B — tree-first generator, layered `fuzz/`, `chaos` as one group.
- **Housekeeping:** branch `fuzz/cynical`; Conventional Commits, no trailers; the owner's uncommitted `src/main.zig` / `CLAUDE.md` are never staged.

- **Engine hardening (added 2026-09-30, owner request):** one engine change is in scope — a program-size
  limit. `Options.size_limit` (default 1 000 000) bounds `hir.expandedSize`, an O(pattern), saturating
  upper bound on the unrolled program; a pattern over it is rejected with `error.PatternTooComplex` (or a
  `@compileError`) before any backend walks or allocates the expansion. Motivation: `max_repetition` bounds
  each `{m,n}` count, but nested counts multiply (`(?:(?:a{1000}){1000}){1000}` ≈ 10⁹ copies), so compiling
  one untrusted pattern could exhaust memory. Additive: a new defaulted `Options` field, an existing error.
  The fuzz suite gains a compile-bomb target that pins it (plan Task 32).

**Non-goals:** engine fixes for fuzz findings (follow-ups the owner picks); cross-language oracles (stay
outside the repo per `fuzz/README.md`); new engine work counters; any public-API change other than the
additive `Options.size_limit` / `hir.expandedSize`.

## 4. Semantics the suite treats as spec

Pinned from `docs/architecture.md` §8–9, `conformance.zig`, and the CHANGELOG (0.6.0+):

- Leftmost-first; match offsets are byte offsets.
- **Empty-width loops follow RE2/Rust** (0.6.0): `(|a)*` on `"aaa"` → `""`, `(?:a?b??)+` on `"ab"` → `"a"`.
  (`DESIGN.md` §2.1 still says "JS" — stale; logged as a doc finding, not fixed here.)
- `$` ≡ `\z` ≡ `\Z` without `(?m)`; `(?m)` lines split on `\n` only (verify in shakedown).
- `.` = any scalar except `\n` unless `s`.
- `\d` = `Nd`, `\w` = `isWord`, `\s` = `White_Space`; `unicode = false` → ASCII sets; `\b` stays Unicode.
- **Dead-on-invalid input:** a malformed byte matches nothing; unanchored scan resyncs one byte past it.
- Unanchored starts are code-point-aligned over valid UTF-8.
- `(?i)` with `case_fold = .simple`: `c ≡ x` iff `caseFoldSimple(c) == caseFoldSimple(x)`.
- Byte engines (`bytepike`/`dfa`/`edfa`) evaluate `\b` as ASCII — contracted only on ASCII input (existing gate).
- Scanner escapes: `\n \r \t \f \v \a \e \0`, `\xHH`, `\x{…}`, `\uHHHH`, `\u{…}`, `\cX`; flags `i m s x`.

Anything the shakedown shows to differ is a **spec question**: ezi's documented behaviour wins, the
rule is added to the `fuzz/README.md` semantics list, and the reference is aligned.

## 5. Layout

```
fuzz/
  gen/
    tree.zig        semantic tree: generate · print (N surface forms) · witness · canonical dump
    pattern.zig     today's pattern_smith.zig, widened (trap code points, (?x) content)
    input.zig       evil UTF-8 · long motif inputs with planted witnesses · case-swapped copies
    literals.zig    literal sets for literal / Teddy / prefix-set paths
  ref/
    nfa.zig         tree → Thompson NFA (Rust regex-automata construction)
    pike.zig        naive Pike simulation with captures
    uni.zig         scalar UTF-8 decode (dead-on-invalid) · per-cp predicates · fold orbits
  check/
    common.zig      Outcome/CapRes/IterRes, backend lists, byte-engine \b gate, case printing
    differential.zig  existing span/captures/iter/replace/offset/strategy bodies (migrated)
    invariants.zig  metamorphic.zig  reference.zig  state.zig  api.zig  oom.zig
    comptime.zig    complexity.zig   utf8class.zig  scanner.zig  large.zig  literals.zig
    chaos.zig       known_open.zig
  groups/           thin `test` blocks, one binary each (19 groups)
  health.zig        vacuity guards (finite)
  findings.zig      known-open ledger (finite)
  threads.zig       shared-Program multi-thread check (finite)
  min.zig           `zig build fuzz-min` delta-debugger
  root.zig          aggregate unit: every group's seed replay + health + findings + threads + ref self-check
```

`harness.zig` / `pattern_smith.zig` are migrated into `check/` / `gen/`, not deleted-then-rewritten;
the existing 7 groups keep their checks.

## 6. Generators

### 6.1 `gen/tree.zig` — the semantic tree

Nodes (generator-owned, never ezi's AST): `Lit(cp)`, `Dot`, `Class{items, negated}` (items: range,
`\d \w \s` ± negation, `\p{…}`/`\P{…}`, nested negation), `Assert(^ $ \A \z \Z \b \B)`, `Concat`, `Alt`,
`Repeat{min, max?, greedy}`, `Group{capturing, name?}`, `Flags{set, clear, child}`. Every node carries
the **resolved** `i m s` flags in force, so the tree is the meaning independent of spelling. A tree
also carries a random global `Options` (`unicode`, `case_insensitive`, `multiline`,
`dot_matches_newline`, `case_fold ∈ {none, simple}`).

Cost knobs mirror today: depth ≤ 4, repeat bounds ≤ 6, printed length ≤ 160 B, fixed-size node pool.

**Code-point pool:** the ASCII alphabet plus traps — length-changing folds (K U+212A↔k, ſ U+017F↔s,
Ⱥ U+023A↔ⱥ U+2C65), fold orbits (Σσς, µ/μ, İ/ı, ǅ), 4-byte cased (𐐀/𐐨), U+FFFD, and every UTF-8
boundary (U+7F/80, 7FF/800, D7FF/E000, FFFF/10000, 10FFFF). ~40 property names spanning
general-category groups/values, scripts, and binary properties.

**Printer** renders one tree through randomly chosen *equivalent* spellings — each a no-op the front
end must honour:

- literal as raw / `\xHH` / `\x{…}` / `\u{…}` / `\uHHHH` / named escape / `[c]`;
- minimal vs maximal escaping, tracked separately in and out of classes;
- `(?:…)` wrapping; named ↔ numbered groups;
- flags inline `(?i)rest` vs scoped `(?i:…)` vs pushed to leaves vs supplied through `Options`;
- `(?x)` with injected whitespace and `#comments\n` (literal space → `\ `);
- `\A`↔`^`, `\z`↔`$`↔`\Z` where `m` is off;
- `{m,n}` expanded to Rust's nested form, `x+`↔`xx*` — **only for non-nullable `x`**.

**Witness sampler:** walks the tree and emits a string that the pattern matches anchored at 0
(assertions satisfied by construction, else the sample is rejected and retried a bounded number of
times).

**Canonical dump:** a deterministic, maximal-escaping print used in failure reports and by `fuzz-min`.

### 6.2 `gen/input.zig`

- **Evil UTF-8:** truncated leads (esp. at end), stray continuations, overlong (`C0 80`, `E0 80 80`,
  `F0 80 80 80`), surrogates (`ED A0 80`), > U+10FFFF (`F4 90 80 80`), `F5`–`FF`, real U+FFFD adjacent
  to an invalid byte.
- **Long inputs (0–12 KiB):** a 4–32 B motif repeated; witnesses and near-misses (witness with one
  byte flipped) planted at `k·16±1`, `k·32±1`, `k·64±1`, and in the last 1–3 bytes; lengths biased to
  4095 / 4096 / 4097.
- **Case-swapped copies** (ASCII + trap orbits) for `(?i)` checks.

### 6.3 `gen/literals.zig`

1–12 literals (crossing `MAX_PREFIX_BRANCHES = 8`), each 0–20 B (crossing `MAX_PREFIX_LEN = 16`); shared
prefixes; one literal a prefix of another; duplicates; the empty literal; optional `(?i)` with fold
traps. Planted into long inputs.

### 6.4 `gen/pattern.zig`

Today's generators, widened with the trap pool, more properties, `(?x)` whitespace/comments, and the
named escapes. Keeps feeding the existing groups.

## 7. Reference matcher (`fuzz/ref/`)

**Independence:** consumes the tree, never a pattern string; never imports `ezi_gex`; uses `ezi_code`
only through per-code-point predicate functions (not range tables).

- **Construction (Rust `regex-automata`):** `x?` → `split(x, exit)`; `x+` → `x; split(x.start, exit)`;
  `x*` → `(x+)?` if `x` nullable, else `L: split(x, exit); x; jmp L`; `x{n,}` → `x{n-1} x+`;
  `x{m,n}` → `m` copies then `n−m` nested optional copies sharing one exit; lazy swaps split priority;
  `{0}`/`{0,0}` → empty.
- **Execution:** naive Pike simulation — per-position priority-ordered thread lists; epsilon closure
  with a per-position visited set; per-thread capture slots; unanchored start thread appended at
  lowest priority until the first match is found.
- **Input decode:** own scalar UTF-8 decoder (table-free, ~30 lines), dead-on-invalid; candidate
  starts step by decoded length, or 1 over a malformed byte.
- **Predicates:** `\d` = `generalCategory == .Nd`; `\w` = `isWord`; `\s` = White_Space; ASCII sets under
  `unicode = false`; `.` per `s`; properties via `generalCategory` / script lookup.
- **Case folding:** `c ≡ x` iff folds equal; a class matches `c` if any member of `c`'s simple-fold orbit
  is in it (orbit from an inverse fold map built once); an item's own negation applies before
  folding, the class's `[^…]` after (Rust's rule).
- **Assertions:** `$` = `\z` without `m`; `(?m)` on `\n`; `\b`/`\B` via `isWord` on the decoded
  neighbours, a malformed byte counts as non-word.
- **Out of scope:** `\X`, `case_fold = .full`; inputs capped at ~256 B.
- **Self-check (finite):** the reference runs every `conformance.zig` case it can express (translated
  into trees by a small table-driven converter in the test) and must reproduce the pinned expectation.

## 8. Checks per group

Existing groups (`scanner diff anchors unicode captures iter search`) keep their checks, get the
widened generators, and gain:

- **scanner:** mutation of valid patterns (1–3 edits from a metachar-heavy set); on reject,
  `diag.span` ⊆ `[0, len]` and `start ≤ end`; on accept, every backend agrees on accept/reject.
- **unicode:** `\X` oracle — `findAll(\X)` over valid UTF-8 tiles the input exactly on `ezi_code`
  grapheme boundaries.

New groups:

| Group | Asserts |
|---|---|
| `reference` | Pike VM and `auto` agree with the reference on span and **every capture slot**, across random `Options`. |
| `metamorphic` | Two printings of one tree ⇒ identical find / isMatch / captures (by index) / findAll on every backend. |
| `invariants` | Oracle-free, every backend: `isMatchAt == (findAt != null)`; **unanchored `findAt(start=s)` = first anchored `findAt(start=k)` over decoded-step `k ≥ s`**; `findAll` spans non-overlapping, monotone, each = `findAt` at its resume point under the pinned empty-match bump; captures: slot 0 = span, groups ⊆ group 0, offsets on code-point boundaries over valid UTF-8; `replaceAll("$0") == input`; `split` pieces ⧺ matches rebuild the input; `count == |findAll|`. |
| `state` | A ≤ 8-op script on **one long-lived Scratch** (heap and `initBuffer`) must equal fresh-Scratch Pike VM per op. Moves: new buffer; **same buffer mutated in place (same ptr+len)**; shorter prefix of same ptr; same bytes at a new ptr; **abandon `findAll` midway**; honest `same_input = true`; interleave two Regexes on their own scratches. |
| `large` | Long inputs with planted witnesses; every backend vs Pike VM; bare `backtrack` only at ≤ 4096 B (auto's `BACKTRACK_MAX_INPUT` — its documented stack-safe regime). |
| `literals` | Literal sets on `literal` / `auto` (Teddy, memmem, prefix sets) vs Pike VM, incl. `simd = .off`, `prefilter = false`. |
| `api` | `split/splitN`, `replace/replaceN`, `replaceAllWith`, `capturesAll`, `capturesAt`, `isMatchAt`, `groupIndex/groupName/named`; templates incl. `${name}`, bare `$`, `$99`, malformed `${` — cross-backend agreement + the reconstruction laws above. |
| `oom` | `std.testing.checkAllAllocationFailures` over compile, `Scratch.init`, `replaceAllAlloc`: each failure point ⇒ `error.OutOfMemory` only, no panic, no leak; the following success is correct. |
| `comptime` | ~40 patterns (seeds + conformance regressions) compiled at comptime, run on fuzzed inputs, must equal the runtime compile. Plus a finite test of `isMatchComptime`/`findComptime`/`countComptime`/`capturesComptime` vs runtime. |
| `complexity` | Generated pattern × motif at n, 2n, 4n: `backtrack.steps` grows ≤ 2.25× per doubling; `auto` `confirm_probes == 0` where contracted. Compile bombs (nested counted repetitions): rejected by `size_limit` having allocated < 1 MiB, or compiled within a memory budget proportional to `expandedSize`. |
| `utf8class` | Classes with UTF-8-boundary endpoints (± negation), inputs = code points around each boundary + evil bytes; the harness knows the ranges, so **membership is checked directly** on every backend incl. byte DFAs. |
| `chaos` | Random composition of the above generators, inputs, scratch policies, and API ops. |

## 9. Keeping the fuzzer honest

- **`health.zig` (finite):** per generator, 2,000 fixed-seed `Smith{ .in = … }` runs ⇒ valid-pattern rate
  ≥ a recorded floor; per check × backend, *compared* (not skipped) fraction ≥ a recorded floor; `large`
  inputs exceed 4096 B in ≥ 25 % of cases. Floors are recorded from the first green run with margin.
- **Known-open gates (`check/known_open.zig`):** each gate skips only the minimized shape of one open
  finding, counts its skips, and `health` fails if any gate skips > 1 % of cases.
- **`findings.zig` ledger:** each open finding is a test asserting it **still reproduces**; a fix flips
  it to failing with "fixed — move to conformance.zig and drop gate `<id>`".
- **Threads (`threads.zig`, finite):** one `Program`, 4 threads, own Scratch each, ≡ serial results.

## 10. Triage tooling

Every failing check prints a **complete replayable case**: check id, pattern hex, input hex,
`Options`, `SearchOptions`, template, and the canonical tree dump (tree groups).
`zig build fuzz-min -- <case>` re-runs that exact check and delta-debugs — tree cases by node
deletion/simplification, string cases by byte deletion, inputs by byte deletion — then prints the
minimal case as a Zig literal ready for `findings.zig` or `conformance.zig`.

## 11. Build wiring

- `fuzz_groups` in `build.zig`: 7 → 19; each its own binary + `fuzz-<group>` step; `zig build fuzz
  --fuzz=N` runs all in parallel (unchanged mechanism).
- Aggregate `fuzz` unit (`test-fuzz`, in `zig build test`): seed replay of every group + health +
  findings + threads + reference self-check. **Budget ≤ 30 s** added under ReleaseSafe; if the comptime
  group's compile time breaks it, that group moves to its own opt-in step.
- New `fuzz-min` run step.
- `fuzz/README.md` rewritten: groups, semantics list, gates, `fuzz-min`, ledger.

## 12. Campaign & handoff

1. **Shakedown:** `--fuzz=200K` per group; fix harness false positives and resolve spec questions (in
   the harness/reference only — never the engine).
2. **Campaign:** all 19 groups in parallel, ~2 h wall-clock.
3. Every finding → `fuzz-min` → ledger entry + known-open gate.
4. **Findings report** to the owner: minimized repro, affected backends, suspected layer, bug vs spec
   question. Owner selects fixes as follow-ups.

## 13. Risks

- **Reference false positives** (construction or fold-rule mismatch) — mitigated by the conformance
  self-check and the spec-question rule (§4).
- **Metamorphic rewrites that aren't equivalent** — restricted to non-nullable operands where
  construction shape matters; any divergence is first checked against the reference.
- **Comptime compile time** — bounded pattern count; opt-in step fallback (§11).
- **Flaky complexity ratios** — none: counters are deterministic work counts, not timers.
- **Campaign noise from one frequent finding** — known-open gates keep a group productive after its
  first hit.
