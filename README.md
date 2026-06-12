# ezi_gex

A Unicode-aware regex engine for Zig that runs at **runtime and `comptime`**, with
a **pluggable backend** architecture.

- **Linear-time.** Thompson-NFA based — no catastrophic backtracking, ever.
  `(a*)*b` on a long input is fine.
- **Unicode-first.** `\w`, `\b`, `\p{L}`, `\p{Script=Greek}`, case folding, and
  classes are all Unicode-correct, resolved once into code-point ranges so there
  are **zero Unicode-table lookups at match time**. Unicode comes from
  [`ezi_code`](https://github.com/shaik-abdul-thouhid/ezi-code); ezi_gex never
  touches `std.unicode`.
- **Comptime-capable.** Compile a pattern *and run the match* at compile time —
  the program lands in `ro_data`, the matcher runs in `comptime`. (The C++ `ctre`
  trick, in Zig, with full Unicode.)
- **Pluggable.** Matching lives behind a small, vtable-free **backend contract**.
  The library ships four backends and a dispatcher; you can write your own and
  drop it into the same front door. See [`docs/architecture.md`](docs/architecture.md)
  for the contract, and the step-by-step
  [*write your own backend*](docs/usage-guide.md#8-writing-your-own-backend) walkthrough
  in the usage guide.
- **Target-agnostic.** Pure computation over caller-provided memory — no syscalls,
  no global allocator, no platform assumptions in the library code. Imports and
  compiles anywhere Zig (plus `ezi_code`) does: native, `wasm32-freestanding` /
  `wasm32-wasi`, and bare-metal `*-freestanding` (verified to compile for all four).

## Status

Version `0.2.0` — the current tagged release; **`0.3.0-dev` is now under
development** on `main`. Pre-1.0, so the API may still change, but everything in the
public surface is annotated `@stable-since: vX.Y.Z` and is covered by SemVer. Tracks a
recent Zig dev build (`0.17.0-dev`); it will not compile on stable 0.16.

**What works is tested** (**297 tests**, all passing: per-module behaviour, cross-backend
conformance — including a wide differential corpus where every backend must agree with
the Pike VM — and runtime + comptime parity). `0.2.0` added full case folding, grapheme
`\X`, a two-tier `Options` (semantic + results-invariant strategy), `(?x)` verbose
mode, ASCII mode, dead-on-invalid UTF-8, and the **byte-NFA lowering + `ByteMap`
equivalence classes** (`engine/byte.zig`): the zero-decode UTF-8 automaton substrate,
executed by the `bytepike` reference backend.

`0.3.0-dev` makes the **byte DFA the default span engine, on by default** — and the
primary engine is the **eager DFA** (`engine/backends/edfa.zig`): it **fully determinizes
the byte automaton at build time** into a frozen `states × byte_classes` table, so the
matcher is a bare table walk with **no per-search state**, and — unlike the lazy DFA, whose
cache mutates while matching — it runs at **comptime as well as runtime** (so the default
`auto` now bakes a real frozen DFA into `ro_data` for *tiny* patterns at comptime — the
genuine CTRE-lane — while a big Unicode class stays on the Pike VM at comptime but still gets
the eager DFA at runtime). Its `find` is **O(input) on every pattern**, via a
static, build-time strategy choice (`program.prone`): a pattern whose consuming loop is
itself accepting (`\w+`, `\d+`, `[A-Za-z]+`) gets a single greedy **anchored restart**; a
*prone* pattern that can consume an unbounded run before it can accept (e.g. `\w+@\w+`'s
pre-`@` word run) gets the **reverse-DFA two-pass** (a forward pass locates the match end, a
frozen reverse DFA the start) — no Θ(n²) anchored restart. It now also supports **`$`/`\z`**
(`text_end`), so it is broader than the lazy DFA. The **lazy DFA**
(`engine/backends/dfa.zig`) is now the **fallback** — it determinizes the byte automaton on
the fly (one cached DFA state per input byte) and serves patterns whose full eager table
overflows the state bound. Both are span-only (the Pike VM still fills captures and `\b`)
and leftmost-first, conformance-proven against the Pike VM. The **first prefilter tier is
also wired** (`literal` scans with `std.mem.indexOf`, and a literal *alternation* skips with
a single SIMD `indexOfAny` pass; `auto` reads the HIR `Analysis` for a leading-literal
`memchr` prefilter, a `^`/`\A` start short-circuit, and a min-length gate). The architecture
absorbs all of this without API changes — see *Performance*.

## Installing

Via git ref (resolves the tag at fetch time):

```sh
zig fetch --save git+https://github.com/shaik-abdul-thouhid/ezi-gex.git#v0.2.0
```

Or via plain HTTP tarball (pins the content hash in `build.zig.zon`):

```sh
zig fetch --save https://github.com/shaik-abdul-thouhid/ezi-gex/archive/refs/tags/v0.2.0.tar.gz
```

**Tracking `main` (unreleased `0.3.0-dev`)** — if you want the latest, in-development
surface before it's tagged, fetch the branch instead of a tag. This resolves `main`'s
current commit and pins its hash in `build.zig.zon`; re-run it to move up:

```sh
zig fetch --save git+https://github.com/shaik-abdul-thouhid/ezi-gex.git#main
```

`main` is the development branch: it builds and is tested, but APIs there are not yet
covered by a tag, so they can still change before `0.3.0`. For reproducible builds,
prefer a tagged release; reach for `main` only when you specifically need unreleased work.

Then in `build.zig` (the `ezi_code` dependency is resolved transitively — you only
add `ezi_gex`):

```zig
const ezi_gex = b.dependency("ezi_gex", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ezi_gex", ezi_gex.module("ezi_gex"));
```

## Quick look

> For the full hands-on tour — every op, the pipeline from lexing, comptime paths,
> and writing your own backend — see [`docs/usage-guide.md`](docs/usage-guide.md).

```zig
const gex = @import("ezi_gex");

// ── runtime: compile a (possibly user-supplied) pattern; never crashes ──────
var diag: gex.Diagnostic = .{};
var re = gex.compileRuntime(gpa, "(?<user>\\w+)@(?<host>\\w+)", &diag, .{}) catch {
    // diag.message() + diag.faultySlice(pattern) tell you what and where.
    return;
};
defer re.deinit();

// The Scratch is the per-search working state — you own it; one per thread.
// Build it directly off the backend's `Scratch` type (heap-backed here); the front
// door never constructs it for you. Reuse one across many searches; never share a
// Scratch across threads.
var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
defer sc.deinit(gpa);

if (re.find(&sc, "ping bob@example")) |m| {
    _ = m.slice("ping bob@example"); // "bob@example"
}

// captures: provide a slots buffer of re.slotCount() == 2*(groups+1)
const slots = try gpa.alloc(?usize, re.slotCount());
defer gpa.free(slots);
if (re.captures(&sc, slots, "bob@example")) |c| {
    _ = c.namedSlice("user"); // "bob"
    _ = c.namedSlice("host"); // "example"
}

// ── comptime: program baked into the binary; match runs at compile time ─────
const Re = comptime gex.compileComptime("(\\d{4})-(\\d{2})", .{});
const yes = comptime Re.isMatchComptime("y2026-06"); // true, computed at build
const cap = comptime Re.capturesComptime("y2026-06").?; // groups resolved at build (usable from v0.2.0-dev)
const year = comptime cap.groupSlice(1).?;              // "2026", a ro_data slice (usable from v0.2.0-dev)
```

> ### ⚠️ Comptime has limits — and the trade-off is yours
>
> `compileComptime` runs the **entire** parse → HIR → program lowering inside the Zig
> compiler's const-evaluator and bakes the result into `ro_data`. Two consequences you own
> as a deliberate choice — the library will not decide them for you:
>
> 1. **It only works until the compiler runs out of room.** Const-eval is bounded by the
>    eval-branch quota and compiler memory; a large, deeply-nested, or pathological pattern
>    can blow the quota or make builds slow and memory-heavy. **Prefer `compileRuntime` for
>    big or user-supplied patterns** — runtime compilation has no such ceiling.
> 2. **Each comptime program adds *its* ranges to `ro_data`.** A `compileComptime` regex
>    bakes its class ranges in: ~6.3 KB per *distinct* `\w` (~800 ranges), ~5.3 KB per
>    `\p{L}`, ≤0.5 KB for ASCII classes. **Identical classes within a pattern are interned
>    to one range-block**, so a counted repeat like `\w{3,32}` costs *one* `\w`, not one
>    per copy — repetition no longer multiplies the table. The cost is one block per
>    *distinct* class per comptime pattern; `compileRuntime` adds nothing to the binary.
>    The Unicode *tables* themselves are a fixed one-time cost, **not** per-pattern — see
>    [§ Binary size](#binary-size). Stacking many *different* Unicode classes across many
>    comptime programs is the only thing that grows `ro_data`; check the delta then.

## Matching & captures

Everything below uses the default `auto` engine — `compileRuntime` /
`compileComptime`. The shape never changes: **compile once → make a `Scratch` →
run searches**. The compiled regex is immutable and shareable; the `Scratch` is the
single piece of mutable per-search state.

> Prefer copy-paste? The usage guide has a runnable recipe for each op below in
> [§3 Front-door recipes](docs/usage-guide.md#3-front-door-recipes), plus the
> [`Options`](docs/usage-guide.md#options) reference and the
> [comptime / no-allocator](docs/usage-guide.md#4-comptime--no-allocator-usage) paths.

### 1. The `Scratch` — the engine only needs *a* scratch

The engine is **`Scratch`-type agnostic.** Every search op takes a
`*@TypeOf(re).Scratch`, and that is the *entire* requirement. The front door never
constructs it, never stores an allocator for it, and assumes **nothing** about what it
holds — whether a `Scratch` is heap-allocated, carved from a caller buffer, stateless
(`struct{}`), or something exotic is **purely the backend's design**. Buffer
semantics, allocator semantics, comptime-ability: all optional, all the backend's
call. `Compiled` holds only the `Scratch` *type* and forwards your `&sc` straight
through to the backend — so you build the `Scratch` yourself, directly off
`@TypeOf(re).Scratch`, threading in `&re.program`:

```zig
var re = try gex.compileRuntime(gpa, "[a-z]+\\d+", &diag, .{});
defer re.deinit();

// Heap-backed — every built-in backend's Scratch defines `init` / `deinit`.
var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
defer sc.deinit(gpa);
```

If the backend implements the **buffer convention** (its `Scratch` exposes
`Buf` / `bufferLen` / `initBuffer` — all four built-ins do), you can hand it
caller-owned storage instead, with no allocator and no allocation *during* a search:

```zig
// Fixed buffer — `bufferLen` reports how many `Buf` words this program needs.
const buf = try gpa.alloc(@TypeOf(re).Scratch.Buf, @TypeOf(re).Scratch.bufferLen(&re.program));
defer gpa.free(buf);
var sc_buf = try @TypeOf(re).Scratch.initBuffer(buf, &re.program);

// For a comptime regex the length is comptime-known → a stack array, no allocator:
const Re = comptime gex.compileComptime("[a-z]+\\d+", .{});
var stack_buf: [@TypeOf(Re).Scratch.bufferLen(&Re.program)]@TypeOf(Re).Scratch.Buf = undefined;
var sc_ct = try @TypeOf(Re).Scratch.initBuffer(&stack_buf, &Re.program);
```

A backend with a different construction protocol is built however *it* specifies — for
a stateless one that is simply `var sc: @TypeOf(re).Scratch = .{};`. Whatever the
backend's choice, you end up with a value the engine accepts.

> The front door dictates no representation and reaches for no scratch method on the
> runtime path: it cares that a `Scratch` *value* exists, not how it was made. (The
> comptime helpers — `isMatchComptime`/`findComptime`/… — are the one exception: with
> no allocator in const-eval they carve a buffer `Scratch` inline, so there they do
> require the backend's buffer convention.)

### 2. Searching — `isMatch`, `find`, `findAll`, `count`, `split`

```zig
var re = try gex.compileRuntime(gpa, "\\w+", &diag, .{});
defer re.deinit();
var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
defer sc.deinit(gpa);

const text = "the quick brown fox";

_ = re.isMatch(&sc, text);                 // true
const m = re.find(&sc, text).?;            // first match (leftmost)
_ = m.start;  _ = m.end;  _ = m.slice(text); // "the"

_ = re.count(&sc, text);                   // 4 — non-overlapping matches

var it = re.findAll(&sc, text);            // iterate every match
while (it.next()) |hit| _ = hit.slice(text); // "the","quick","brown","fox"

var parts = re.split(&sc, "a, b ,c");      // split on the pattern
while (parts.next()) |piece| _ = piece;    // "a, b ,c" split on /\w+/ → punctuation/spaces
```

Matching is **leftmost-first** (Perl/JS), linear-time, and Unicode-correct. `find`
returns `null` (not an error) when there is no match.

### 3. Captures — numbered and named groups

`captures` resolves the first match's submatches into a `slots` buffer you provide.
Size it with `re.slotCount()` (`== 2 * (groups + 1)` — two offsets per group plus the
whole match at index 0). At **runtime** the group count is dynamic, so allocate; at
**comptime** it is known, so a stack array works.

```zig
var re = try gex.compileRuntime(gpa, "(?<user>\\w+)@(?<host>\\w+)", &diag, .{});
defer re.deinit();
var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
defer sc.deinit(gpa);

const slots = try gpa.alloc(?usize, re.slotCount()); // 2 * (2 groups + 1) = 6
defer gpa.free(slots);

if (re.captures(&sc, slots, "ping bob@example")) |c| {
    _ = c.match().slice("ping bob@example"); // "bob@example"  (group 0)
    _ = c.groupSlice(1).?;                    // "bob"          (by number)
    _ = c.namedSlice("user").?;               // "bob"          (by name)
    _ = c.namedSlice("host").?;               // "example"
    _ = c.group(2);                           // ?Match for group 2, or null if absent
}
```

A group that did not participate reads back `null` (`groupSlice`/`namedSlice` return
`null`, never stale data). To stream captures over every match, use `capturesAll`
(it reuses one `slots` buffer — each `Captures` is valid only until the next
`next()`):

```zig
var cit = re.capturesAll(&sc, slots, "a@b x@y");
while (cit.next()) |c| _ = c.namedSlice("user"); // "a", then "x"
```

### 4. Replace — `replaceAll` with `$0`/`$1`/`$name` templates

```zig
var re = try gex.compileRuntime(gpa, "(\\w+)@(\\w+)", &diag, .{});
defer re.deinit();
var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
defer sc.deinit(gpa);
const slots = try gpa.alloc(?usize, re.slotCount());
defer gpa.free(slots);

var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try re.replaceAll(&sc, "bob@example", "$2/$1", slots, &out.writer); // "example/bob"
```

### 5. The same calls at comptime

When the whole regex *and* the input are known at compile time, the match runs in
const-eval — no `Scratch` to manage, no allocator. The results are baked into
`ro_data` and are usable at runtime as well:

```zig
const Re = comptime gex.compileComptime("(\\d{4})-(\\d{2})", .{});

const ok   = comptime Re.isMatchComptime("y2026-06"); // true
const m    = comptime Re.findComptime("y2026-06").?;  // whole match
const n    = comptime Re.countComptime("2026 2027");  // 2
const c    = comptime Re.capturesComptime("y2026-06").?;
const year = comptime c.groupSlice(1).?;              // "2026" — by number
```

**Comptime named captures.** Named groups resolve at compile time exactly like at
runtime — `namedSlice` works inside const-eval, and the result is a `ro_data` slice
you can keep as a plain `const`:

```zig
const Re = comptime gex.compileComptime("(?<year>\\d{4})-(?<month>\\d{2})", .{});

if (comptime Re.capturesComptime("y2026-06")) |c| {
    const year  = comptime c.namedSlice("year").?;  // "2026"
    const month = comptime c.namedSlice("month").?; // "06"
    _ = year;  _ = month;
}

// …or pull one straight out as a compile-time constant baked into the binary:
const year = comptime Re.capturesComptime("y2026-06").?.namedSlice("year").?; // "2026"
```

## Supported syntax

| Category | Supported |
|---|---|
| Literals, `.`, `\|`, `*` `+` `?` `{m,n}`, lazy `*?`… | ✅ |
| Groups `(…)`, `(?:…)`, named `(?<n>…)`/`(?P<n>…)` | ✅ |
| Classes `[...]`, `[^...]`, ranges, `\d \w \s` (+ negations) | ✅ |
| Unicode `\p{L}` `\P{…}` `\p{Script=…}`, `\pL` | ✅ |
| Anchors `^ $ \A \z`, word boundary `\b \B`, multiline `(?m)` | ✅ |
| Inline flags `(?i)` `(?m)` `(?s)` `(?x)`, scoped `(?i:…)` | ✅ |
| Escapes `\n \t \xHH \x{…} \u{…} \cX`, comments `(?#…)`, verbose `(?x)` | ✅ |
| `\X` grapheme cluster (UAX #29) | ✅ (matched by `backtrack`/`auto`) |
| Backreferences, lookaround, atomic/conditional, recursion, `\Q…\E` | ❌ rejected with a precise error |

Anchors are JS/RE2-style: `$` without `(?m)` is end-of-input (`\z`), and `\Z` is
treated as `\z`. See [`docs/architecture.md`](docs/architecture.md) §Caveats.

## Backends

| Backend | Strategy | Captures | Comptime | Use |
|---|---|---|---|---|
| `auto` *(default)* | dispatches the others | ✅ | ✅ | just use this |
| `pikevm` | breadth-first NFA | ✅ | ✅ | general, large inputs |
| `backtrack` | bounded depth-first NFA | ✅ | ✅ | small inputs |
| `literal` | substring / literal-alternation | whole-match | ✅ | pure-literal patterns |
| `bytepike` | byte-stepping Pike VM (zero-decode) | ✅ | ✅ | byte-automaton substrate (no `\X`/`\b`) |
| `edfa` *(default span engine)* | **eager** DFA — frozen `states × byte_classes` table | span-only | ✅ | fast span scan; O(n) `find`; `auto` prefers it |
| `dfa` | lazy DFA over the byte automaton (cached transitions) | span-only | ✗ (runtime-only) | the fallback when the eager DFA overflows its state bound |

`compileRuntime`/`compileComptime` use `auto`, which now **prefers the eager DFA**
(`edfa`) for the span scan on an eligible pattern (no `\b`/`\X`/`(?m)` line anchors — but
`$`/`\z` *is* fine), falling back to the lazy `dfa` only when the eager table overflows its
state bound, then to the NFA; the Pike VM fills captures anchored at the DFA span. The DFA
is **on by default** (`byte_engine = .auto`/`.enabled`); `.disabled` opts back to the
NFA-only program. Force a specific backend with the `*With` variants:
`gex.compileRuntimeWith(gex.backends.pikevm, gpa, pat, &diag, .{})`.

The usage guide covers [choosing a backend](docs/usage-guide.md#choosing-a-specific-backend)
and walks the whole [*write your own backend*](docs/usage-guide.md#8-writing-your-own-backend)
process end to end.

## When to use comptime — honest advice

The library has two things it calls "comptime" and they behave quite differently, so
it's worth being clear about which one you actually want.

**`compileComptime` — program in ro_data, match at runtime.** The full compile pipeline
runs in the Zig const-evaluator and the result is baked into the binary. Matching still
happens at runtime over runtime input. You use it exactly like a `compileRuntime` regex
once compiled.

**`*Comptime` methods (`isMatchComptime`, `findComptime`, `capturesComptime`, …) — both
pattern and input are compile-time constants.** The entire match runs during the build
and the result is a compile-time constant. These are a different beast.

### For most code: just use `compileRuntime`

Pattern compilation is a one-time cost — microseconds to low milliseconds, paid once at
startup and never again. There is no meaningful performance argument for `compileComptime`
over `compileRuntime` followed by runtime matching. The compiled regex is immutable; you
compile once, store it somewhere, and reuse it for the lifetime of the process.

`compileRuntime` also has cleaner error handling (a `Diagnostic` with a caret, not a
`@compileError` buried in a stack of const-eval frames), no binary-size overhead, and no
compiler eval-quota ceiling. It should be your default for nearly everything — fixed
patterns included.

### When `compileComptime` is actually worth it

Use it when **all three** are true:

1. The pattern is fixed in source (not user-supplied, not assembled at runtime).
2. You specifically want the build-time guarantee — a typo in the pattern is a
   `@compileError`, not a runtime error path you have to handle.
3. The pattern is light on Unicode classes.

That third one is the catch — though a much smaller one than it used to be. This engine
resolves Unicode classes to sorted code-point ranges at HIR time, and a
`compileComptime` program bakes its ranges into `ro_data`. One `\w` is ~6.3 KB
(802 ranges × 8 B), `\p{L}` ~5.3 KB, `\d` ~0.5 KB, `\s` ~80 B. **Identical classes
inside a pattern are interned to a single range-block**, so a counted repeat like
`\w{3,32}` costs *one* `\w` (~6.3 KB), not one per copy — repetition no longer
multiplies the table. The remaining cost is one block per *distinct* class per
comptime pattern. If your pattern is ASCII-heavy (`\d`, `[a-z]`, explicit ranges) the
cost is negligible; if it stacks many *different* Unicode classes, check the delta.
See [§ Binary size](#binary-size) for the whole picture (the Unicode tables themselves
are a fixed one-time cost, not a per-pattern one).

### When the `*Comptime` match methods make sense

These require the input to be a compile-time constant, which makes them self-selecting:
if your data is dynamic, you simply cannot use them. That rules out essentially all
production matching code.

They genuinely shine as build-system tools: asserting at build time that a constant
string matches an expected format (`comptime assert(Re.isMatchComptime(EXPECTED))`),
generating a lookup table from a constant corpus, or pulling a named group out of a
source-level constant as its own typed constant. The results are baked in and cost
nothing at runtime. Just keep the input short — the eval-branch quota scales with input
length, and a large string in const-eval will slow your build.

## Thread-safety

The `Program` is `*const` during a search — compiler-enforced immutable, so a single
`Compiled`/`Program` is freely shareable across threads with no locks, no atomics, no
global state. The `Scratch` is the only mutable per-search state, and **how it behaves
under concurrency is the backend's choice** — a backend is free to make its `Scratch`
thread-safe. The built-in backends do **not**: their `Scratch` is mutated on every
search, so give **each thread its own** (never pool one across threads).

Two facts about the built-ins, both stemming from the *caller-supplied* allocator
rather than any hidden internal one — the front door allocates nothing during a search:

- The `backtrack` heap `Scratch` (which `auto` uses for small inputs) grows its visited
  set on demand **through the allocator you passed to `Scratch.init`**. So if several
  threads' scratches share one *non-thread-safe* allocator, two growing at once race
  inside that allocator — give each thread its own allocator, or a thread-safe one.
- A **buffer-backed `Scratch`** (`initBuffer`) and the **`pikevm`** backend allocate
  nothing at all while matching, sidestepping that entirely.

Full details in [`docs/architecture.md`](docs/architecture.md) §11 and the usage guide's
[§9 Thread-safety](docs/usage-guide.md#9-thread-safety).

## Performance

Honest about where it stands. **Tier 1 — the literal / prefilter fast path — is now
wired:**

1. The `literal` backend scans with `std.mem.indexOf`: SIMD `memchr` to locate a
   one-byte needle, Boyer–Moore–Horspool with a skip table for longer ones — instead
   of an `eql` at every byte position. On memchr-friendly needles that is **~20×** the
   old position-by-position scan; it is never slower.
2. `auto` consumes the HIR [`Analysis`](docs/usage-guide.md#7-the-analysis-prefilter-facts)
   on NFA patterns: when every match must begin
   with a fixed literal, its first byte drives a `memchr` that skips straight to each
   candidate start (each confirmed with an *anchored* NFA run); a `^`/`\A` pattern
   skips the leftward scan entirely; the **rarest required byte** drives a sound
   fast-reject (no `@` in the input ⇒ no `\w+@\w+` match, return at once); and a
   min-length gate rejects inputs too short to hold any match. Every `Analysis` fact is a
   sound one-sided bound, so the prefilter never drops a real match — it only avoids
   running the engine where one cannot start. Toggle with `strategy.prefilter`.

**Tier 3 — the byte DFA — is wired and now ON BY DEFAULT, with the *eager* DFA as the
primary span engine** (`backends/edfa.zig`, reached through `auto`). On an eligible pattern
(no `\b`/`\X`/`(?m)` line anchors — but `$`/`\z` *is* eligible), `auto` builds the eager
DFA, a fully-determinized frozen `states × byte_classes` table, and uses it for
`isMatch`/`find`; captures are filled by the Pike VM **anchored at the DFA span** (the
capture handoff). The lazy DFA (`backends/dfa.zig`) is the **fallback** — used only when the
eager table overflows its state bound — and it took a hot-loop perf pass (cached raw table
pointers refreshed only on a cold transition; `\w+` ~336 → ~517 MiB/s). The bench
(`bench-vs-rust/`) shows the default is **at Rust parity (~1.1×–1.3×) on every class scan**
and **≥ the code-point Pike VM in every cell** (5–10× on character-class scans), and it is
**results-invariant** (`conformance.zig` pins the span and captures to the Pike VM, and
fuzzes the strategy knobs). `strategy.byte_engine = .disabled` opts back to the compact
NFA-only program.

**`find` is O(n) on every pattern — via a build-time strategy choice.** `computeProne`
detects, at build, whether the anchored DFA has a **non-accepting cycle reachable from a
start** (it can consume an unbounded run without ever accepting):

- **Non-prone** (`\w+`, `\d+`, `[A-Za-z]+` — the consuming loop is itself accepting) →
  **anchored restart**: one greedy frozen-table walk per match. O(input) because no start
  can scan far without hitting an accepting state (~1.1 GiB/s).
- **Prone** (`\w+@\w+` on long word runs, `[ab]*c`) → the **reverse-DFA two-pass**: a
  forward one-pass (`utrans` `.*?`-prefix table) locates the match **end**, a frozen
  **reverse** DFA (determinized at comptime *and* runtime) the leftmost **start**. O(input),
  replacing the old Θ(n²) anchored restart on this begins-everywhere-completes-rarely class.

There is **no per-search probing** — the arm is fixed at build. `$` patterns are forced
non-prone (anchored restart + an end-of-input check). The eager DFA also **builds only the
tables it will use**: `utrans` + the reverse table are built **only for prone patterns**, so
a non-prone `\w+` now stores just its forward `trans` table (~141 KB) instead of all three
(~1 MB). Leftmost-first, conformance-pinned to the Pike VM.

**Still open (additive, no API change):** an interior-literal `memmem`/Teddy prefilter
(multi-substring SIMD for literal alternations — the single biggest remaining gap), DFA
**Hopcroft minimization + a sparse table encoding** (to shrink the Unicode-class eager
tables that *are* kept), line anchors `(?m)` / `\b` in the DFA, and a one-pass NFA capture
path. See [`docs/architecture.md`](docs/architecture.md) §10 for the tier roadmap.

## Binary size

All Unicode work is delegated to `ezi_code`'s **enumerable range tables** — the HIR
resolves every class (`\d \w \s`, `\p{…}`, scripts, `[...]`) to sorted code-point
ranges, and the matcher and `\b` consult those same tables. ezi_gex links **none** of
`ezi_code`'s per-code-point page tries.

This makes the Unicode contribution to your binary a **fixed constant, not a growing
one**:

| What | Cost | Grows with…? |
|---|---|---|
| `ezi_code` range tables (General_Category, DerivedCoreProperties, Script, simple case-fold) | **~135 KB, linked once** | **nothing** — same for 1 pattern or 10 000 |
| per-code-point page tries | **0** — not linked | — |
| a runtime-compiled regex (`compileRuntime`) | on the **heap**, not the binary | the pattern |
| a comptime-compiled regex (`compileComptime`), per pattern | one program in `ro_data`; ~6.3 KB per *distinct* `\w`, ~5.3 KB per `\p{L}`, ≤0.5 KB for ASCII classes | the pattern's distinct classes |

So once a program touches the regex engine at all, the Unicode tables are paid for
**once** and never again — adding more patterns, longer patterns, or more Unicode
classes cannot push that ~135 KB any higher. The only size that scales with your code
is `ro_data` for the `compileComptime` programs you choose to bake in, and even there
**identical classes are interned** (a class used N times in one pattern is stored once;
`\w{3,32}` costs one `\w`, not 35). `compileRuntime` adds nothing to the binary beyond
the shared tables.

> **The byte engine** (on by default; `byte_engine = .disabled` opts out) builds a
> separate *byte* automaton on the **heap** — never linked into the binary — and it is
> larger than the code-point program because a Unicode class becomes automaton structure
> rather than a flat table. Two passes keep it bounded: **UTF-8 suffix sharing** (a
> `(lo,hi,next)` cache that emits each class's shared continuation tails once) and
> **single-copy `x+`** compilation. Measured: `\w+` is ~3.9 k instructions (down from
> ~11 k), `\w+@\w+` ~7.9 k (down from ~23 k); ASCII patterns are unchanged. A
> `byteWorthLowering` cost-gate keeps a pathological pattern (a big class repeated dozens
> of times) on the compact code-point engine entirely. The **lazy** DFA (the fallback)
> never builds the whole automaton — it materializes only the states an input visits (a
> handful over ordinary text), so the NFA's bulk is build-time, not per-search, memory.
> The **eager** DFA (`backends.edfa`, the default span engine) *does* freeze the whole DFA
> into a `states × byte_classes` table — into `ro_data` at comptime — and is also the
> CTRE/bake-it-in path: tiny for literal/ASCII patterns (`abc` is 5 states / ~100 B), a
> few hundred states for a Unicode class. It now **builds only the tables it uses** (a
> non-prone `\w+` keeps just its forward table, ~141 KB, not the forward + `.*?`-prefix +
> reverse trio, ~1 MB). See [`docs/architecture.md`](docs/architecture.md) → *The byte
> substrate* / *The eager DFA*.

Reference point: the bundled `main.zig` demo (which exercises runtime *and* comptime
compilation, classes, captures, replace, split, and `\p{L}`) is **~2.76 MB** in `Debug`
on macOS arm64 — the rest is the Zig `Debug` runtime (DWARF self-unwind, UBSan, the
allocator), not regex data. `ReleaseSmall` is far smaller.

## Documentation

- [`docs/usage-guide.md`](docs/usage-guide.md) — **the hands-on guide**: copy-paste
  recipes for every front-door op, the full pipeline used **from lexing** (scan → AST
  → HIR → backend), comptime/no-allocator paths, and a complete, runnable, step-by-step
  **"write your own backend"** walkthrough. Start here if you want to *do* something.
- [`docs/architecture.md`](docs/architecture.md) — architecture, data flow,
  **how to write your own backend** (with a complete tiny example), caveats, and
  the implicit assumptions backends rely on.
- [`src/core/README.md`](src/core/README.md) — the frontend (scanner → AST → HIR).
- [`src/engine/README.md`](src/engine/README.md) — the contract, the NFA, the
  backends, the front door, and a backend quickstart.
- [`src/engine/backends/README.md`](src/engine/backends/README.md) — the four
  backends and how `auto` chooses.

## License

MIT — see [LICENSE](LICENSE).
