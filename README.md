# ezi_gex

A Unicode-aware regex engine for Zig that runs at both runtime and `comptime`, with a pluggable
backend architecture.

- **Linear-time.** It's Thompson-NFA based, so there's no catastrophic backtracking. `(a*)*b` on
  a long input is fine.
- **Unicode-first.** `\w`, `\b`, `\p{L}`, `\p{Script=Greek}`, case folding, and classes are all
  Unicode-correct. Classes resolve once to sorted code-point ranges and match by a range check,
  with no per-character table lookup; `\b` and `\X` read `ezi_code`'s property tables directly.
  All Unicode comes from [`ezi_code`](https://github.com/shaik-abdul-thouhid/ezi-code); ezi_gex
  never touches `std.unicode`.
- **Comptime-capable.** You can compile a pattern and run the match at compile time: the program
  lands in `ro_data` and the matcher runs in `comptime`. (It's the C++ `ctre` trick in Zig, with
  full Unicode.)
- **Pluggable.** Matching sits behind a small, vtable-free backend contract. The library ships
  seven backends and a dispatcher, and you can write your own against the same front door. See
  [`docs/architecture.md`](docs/architecture.md) for the contract and the
  [*write your own backend*](docs/usage-guide.md#8-writing-your-own-backend) walkthrough.
- **Target-agnostic.** It's pure computation over caller-provided memory: no syscalls, no global
  allocator, no platform assumptions in the library code. It compiles anywhere Zig (plus
  `ezi_code`) does, including `wasm32-freestanding`/`wasm32-wasi` and bare-metal `*-freestanding`
  (all four are verified to compile).

## Status

The latest release is `v0.6.1`; `main` is the development branch (`0.7.0-dev`). See
[Installing](#installing) for pinning the tag versus tracking `main`. It is pre-1.0, so the API
can still change, though everything public is annotated `@stable-since: vX.Y.Z` and follows
SemVer. It needs a recent Zig dev build (`0.17.0-dev`) and will not compile on stable 0.16.

The default `auto` engine is byte-DFA-first: a Hopcroft-minimized eager DFA as the primary span
engine, a lazy DFA as the fallback. It runs in O(input) on every pattern, is leftmost-first,
agrees byte-for-byte with the reference Pike VM, and works at both comptime and runtime.
[Backends](#backends) and [Performance](#performance) cover how it works;
[CHANGELOG.md](CHANGELOG.md) has what each release added.

It is benchmarked against Rust's `regex` and Go's `regexp` on real
[rebar](https://github.com/BurntSushi/rebar) haystacks. The harness is a separate, reproducible
repo: [regex-bench](https://github.com/shaik-abdul-thouhid/regex-bench). Around 490 tests cover
per-module behaviour, cross-backend conformance (every backend has to agree with the Pike VM, at
runtime and comptime), and ReDoS immunity (`engine/redos.zig`), plus a hardened, parallel
**fuzz** suite (`fuzz/` — every backend differenced against the Pike VM; `zig build fuzz --fuzz=N`).

## Installing

The latest **tagged** release is **`v0.6.1`** — the recommended choice for reproducible
builds. Via git ref (resolves the tag and pins its content hash in `build.zig.zon`):

```sh
zig fetch --save git+https://github.com/shaik-abdul-thouhid/ezi-gex.git#v0.6.1
```

Or via plain HTTP tarball (also pins the content hash):

```sh
zig fetch --save https://github.com/shaik-abdul-thouhid/ezi-gex/archive/refs/tags/v0.6.1.tar.gz
```

**Tracking `main` (unreleased `0.7.0-dev`)** — if you want the latest in-development surface
before it's tagged, fetch the branch instead of a tag. This resolves `main`'s current commit
and pins its hash in `build.zig.zon`; re-run it to move up:

```sh
zig fetch --save git+https://github.com/shaik-abdul-thouhid/ezi-gex.git#main
```

`main` is the development branch: it builds and is tested, but APIs there are not yet covered
by a tag, so they can still change before `0.7.0`. For reproducible builds prefer the `v0.6.1`
tag; reach for `main` only when you specifically need unreleased work.

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
`Buf` / `bufferLen` / `initBuffer` — every built-in except the runtime-only lazy `dfa`
does), you can hand it caller-owned storage instead, with no allocator and no allocation
*during* a search:

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
var head = re.splitN(&sc, "a,b,c,d", 2);   // at most 2 pieces: "a", then "b,c,d"
```

The `*At` variants take `SearchOptions` to resume/anchor: `isMatchAt`, `findAt`, `capturesAt`.

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

Map group names ↔ indices straight from the compiled pattern (no match needed) with
`re.groupIndex("user")` (→ `?usize`) and `re.groupName(1)` (→ `?[]const u8`).

### 4. Replace — templates, counts, an owned string, or a callback

`$0`/`$&` is the whole match, `$1`/`${name}` reference groups, `$$` is a literal `$`.
There's a `Writer`-based form, a count-bounded form, an **allocating** form, and a
**callback** form:

```zig
var re = try gex.compileRuntime(gpa, "(\\w+)@(\\w+)", &diag, .{});
defer re.deinit();
var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
defer sc.deinit(gpa);
const slots = try gpa.alloc(?usize, re.slotCount());
defer gpa.free(slots);

// (a) into a Writer:
var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try re.replaceAll(&sc, "bob@example", "$2/$1", slots, &out.writer); // "example/bob"

// (b) get an owned []u8 directly — no Writer to build:
const s = try re.replaceAllAlloc(gpa, &sc, "bob@example", "$2/$1", slots); // "example/bob"
defer gpa.free(s);

// (c) bounded: only the first match (`replace`), or the first n (`replaceN(..., n)`).
try re.replace(&sc, "a@b c@d", "<$1>", slots, &out.writer); // first match only

// (d) callback — compute each replacement from the captures:
try re.replaceAllWith(&sc, "a@b c@d", slots, &out.writer, {}, struct {
    fn run(_: void, c: gex.Captures, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (c.groupSlice(1).?) |ch| try w.writeByte(std.ascii.toUpper(ch)); // upper-case the user
    }
}.run);
```

Replace is **fast by default**: a template that references no group (a constant, or only
`$0`) runs at span-search speed (the DFA), skipping the capture engine entirely; only
`$1`+/`${name}` templates pay for captures.

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
| `pikevm` | breadth-first NFA | ✅ | ✅ | general, large inputs; Unicode `\b` |
| `backtrack` | bounded depth-first NFA | ✅ | ✅ | small inputs; the only `\X` backend |
| `literal` | substring (two-byte SIMD **`memmem`**) / literal-alternation (SIMD **Teddy**) | whole-match | ✅ | pure-literal patterns |
| `onepass` | single deterministic NFA thread | ✅ | ✅ | provably one-pass capture fill (anchored) |
| `bytepike` | byte-stepping Pike VM (zero-decode) | ✅ | ✅ | byte-automaton substrate; ASCII `\b`, no `\X` |
| `edfa` *(default span engine)* | **eager** DFA — frozen `states × byte_classes` table | span-only | ✅ | fast O(n) span scan; ASCII `\b`, `(?m)`, `$`/`\z` |
| `dfa` | lazy DFA over the byte automaton (cached transitions) | span-only | ✗ (runtime-only) | fallback when the eager table overflows; Unicode `\b` |

`compileRuntime`/`compileComptime` use `auto`, which **prefers the eager DFA** (`edfa`) for
the span scan, falls back to the lazy `dfa` when the eager table overflows its state bound,
then to the NFA. Captures are filled **anchored at the DFA span** by `onepass` (for one-pass
patterns) or the Pike VM. `auto` routes feature by feature and **never `@compileError`s** — it
is correct for every pattern and input: ASCII `\b` and non-prone `(?m)` ride the **eager** DFA,
**Unicode `\b`** (non-ASCII input) the **lazy** DFA, and `\X` / a prone `\b` or `(?m)` / a mixed
`$` stay on the code-point Pike VM. The DFA is **on by default** (`byte_engine = .auto`/
`.enabled`); `.disabled` opts back to the NFA-only program. Force a specific backend with the
`*With` variants: `gex.compileRuntimeWith(gex.backends.pikevm, gpa, pat, &diag, .{})`.

A **single** literal (`Sherlock`) routed to `literal` is scanned with a portable two-byte SIMD
**`memmem`** (`engine/memmem.zig`): probe the two rarest needle bytes, AND their `@Vector` equality
masks across a 16/32-byte chunk, verify only where both coincide — no arch asm (lowers to SSE2/NEON
everywhere). A literal **alternation** (`cat|dog|fish`) instead uses the **Teddy** SIMD prefilter on
a target with a native dynamic shuffle (x86-64 SSSE3/AVX2, aarch64 NEON) — fingerprint all branches
across a 16-byte chunk at once, then verify. Slim (≤8 buckets) by default; **fat** (16 buckets) on
AVX2 for larger sets; portable scalar fallback at comptime and on other targets. Both are governed by
`strategy.simd` (`.auto`/`.off`) — a *permission*, not a command: there is no way to force SIMD onto
a target that lacks it, so the result is always correct.

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
(802 ranges × 8 B), `\p{L}` ~5.3 KB (684 ranges), `\d` ~0.6 KB (72 ranges), `\s` ~80 B (10 ranges). **Identical classes
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

> **Benchmark:** the numbers below come from a like-for-like, three-way throughput +
> compile-time comparison against **Rust `regex`** and **Go `regexp`** on byte-identical
> [rebar](https://github.com/BurntSushi/rebar) haystacks. The harness is a separate,
> reproducible repo — clone it and run `./run.sh`:
> **[github.com/shaik-abdul-thouhid/regex-bench](https://github.com/shaik-abdul-thouhid/regex-bench)**
> (it fetches this engine from GitHub, so anyone can reproduce the comparison).

ezi_gex is competitive with Rust's `regex`, and it never goes quadratic. On the rebar Sherlock
suite its throughput is within a small factor of Rust overall (geometric mean about 1.5×, against
Rust's 1.16×), it matches Rust on most character-class scans, and it beats Rust on a number of
literal and case-insensitive patterns. Against its own simple reference engine it is several times
faster across the board.

The default `auto` engine compiles each pattern into a minimized byte-level DFA and matches with a
plain table walk, at comptime as well as runtime. Ahead of that sit SIMD prefilters that jump
straight to where a match could begin (literals, alternations, case-insensitive names, leading
digit and number classes), so the engine rarely touches the bytes between matches. And `find` is
O(input) on every pattern and every input: there is no catastrophic backtracking, and a dedicated
ReDoS suite proves it. Every fast path is checked byte-for-byte against the reference engine, so
none of it changes a result.

Where it still trails Rust is dense Unicode-class throughput: `\p{L}+`, `[A-Za-z]+` and similar,
where the match is the whole input, so there is nothing to skip and the table walk itself is the
cost. That is the current focus. See [`docs/architecture.md`](docs/architecture.md) §10, and
[CHANGELOG.md](CHANGELOG.md) for the performance work in each release.

## Binary size

Class matching costs almost nothing in the binary. The HIR resolves every class (`\d`, `\w`,
`\p{…}`, scripts, `[...]`) to sorted code-point ranges from `ezi_code` and matches them with a
range check, so there is no per-character table to link. What does pull in data is the Unicode
*assertions*: Unicode `\b` needs the DerivedCoreProperties table, `\X` the grapheme-break table,
and `(?i)` the case-fold tables. Those add up to roughly 385 KB, most of it DerivedCoreProperties.

That cost is fixed, not growing. The tables are shared and linked once, whether you compile one
pattern or ten thousand. A `compileRuntime` regex lives on the heap and adds nothing to the
binary. A `compileComptime` regex bakes one small program into `ro_data` (a few KB for a Unicode
class, well under 1 KB for ASCII), and identical classes within a pattern are stored once.

The byte DFA that `auto` runs by default is built on the heap and is never linked in. The one
exception is the eager DFA at comptime, which freezes its table into `ro_data` (tiny for
literal/ASCII patterns, a few hundred states for a Unicode class). Either way determinization is
a one-time build cost; match time stays O(input). For the details see
[`docs/architecture.md`](docs/architecture.md).

As a reference point, here is the bundled `main.zig` demo — which exercises runtime and comptime
compilation, classes, captures, replace, split, `\p{L}`, scripts, and all three byte backends —
built with Zig `0.17.0-dev` on macOS arm64:

| Optimize mode | Demo binary |
|---|---|
| `Debug` | 3.64 MB (3,819,672 B) |
| `ReleaseSafe` | 1.35 MB (1,415,288 B) |
| `ReleaseFast` | 1.20 MB (1,262,472 B) |
| `ReleaseSmall` | 0.79 MB (830,712 B) |

Most of the `Debug` figure is Zig's debug runtime, not regex data. Your own binary will come in
under the demo: it won't link the demo's full spread of backends and Unicode features, and
`compileRuntime` adds nothing beyond the shared tables.

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
- [`src/engine/backends/README.md`](src/engine/backends/README.md) — the built-in
  backends (incl. `bytepike`/`dfa`/`edfa`) and how `auto` chooses.

## Building & testing

```sh
zig build                                   # build the demo exe (zig-out/bin/ezi_gex)
zig build run                               # build + run it
zig build bench                             # benchmarks (ReleaseFast by default)
zig build test -Doptimize=ReleaseSafe       # full suite (ReleaseSafe is faster than Debug)
```

The test suite is split into **16 independently-cacheable units** — one named module per area, so a
test binary only ever contains its own `test {}` blocks (Zig pulls a file's tests into every module
that reaches it via a *relative* import, but never across a *named*-module boundary). Editing one
file recompiles and re-runs only the unit(s) whose inputs changed; the rest stay cached. The units:
`utils`, `core`, `engine_base`, the eight backends (`backtrack`, `pikevm`, `bytepike`, `dfa`, `edfa`,
`onepass`, `literal`, `auto`), `regex`, `conformance`, `redos`, `fuzz`, and `exe`.

```sh
zig build test-core                         # run ONE unit (cached; also test-auto, test-edfa, …)
zig build test-conformance -Doptimize=ReleaseSafe
zig build --help                            # lists every test-<unit> step
# Gate the aggregate `test` step to a subset (REPEAT the flag — there is no comma form):
zig build test -Dinclude-test=auto -Dinclude-test=conformance -Doptimize=ReleaseSafe
```

Use `test-<unit>` while iterating on one file; run the full `zig build test` before committing.
`zig build test` prints nothing and exits `0` on success; a failure prints the failing test.

### Fuzzing

The `fuzz` unit is a coverage-guided harness (Zig's `std.testing.fuzz` + `Smith`) over the public
API — see [`fuzz/README.md`](fuzz/README.md). It runs **finite** by default (replays a seed corpus,
doubling as a smoke test in `zig build test`); add `--fuzz=N` for a bounded soak:

```sh
zig build fuzz                              # finite smoke run (no instrumentation)
zig build fuzz --fuzz=200000                # bounded coverage-guided session (K/M/G suffixes ok)
```

> ⚠️ Bare `zig build test --fuzz` (no `=N`) fuzzes **forever** across every binary by design — for a
> bounded run always use `--fuzz=N` and target the `fuzz` unit. Targets: scanner-never-crashes,
> cross-backend span agreement (Pike VM oracle), and exact `{m,n}`-limit accept/reject.

## Known limitations

Two things are deliberate. `\X` (grapheme clusters) runs on the backtracker only, so a `\X`
pattern doesn't get the linear-time guarantee — `auto` routes it there automatically. And `{m,n}`
repetition counts are capped (default 100,000, set via `Options.max_repetition`) so a count like
`a{999999999}` fails to compile instead of blowing up. Both are written up in
[`docs/limitations.md`](docs/limitations.md).

Empty-width loops follow RE2/Rust leftmost-first semantics on every backend, at runtime and
comptime — a deliberate semantic choice, pinned by the cross-backend conformance suite and the
parallel fuzz differential (`fuzz/`, the full backend matrix against the Pike VM oracle) so it
can't silently drift.

There are also a few **performance** shapes where ezi_gex is slower than Rust and that won't be
optimized — each fix would cost the linear-time guarantee, portability, or simplicity. From the
rebar Sherlock suite: an unbounded gap between two literals (`Holmes(?:…){0,10}Watson`, ~20×), a
common single byte as the only distinctive feature (`\b\w+n\b`, ~8×), a bounded negated-class run
(`["'][^"']{0,30}…`, ~6.5×), an unbounded case-insensitive alternation (`(?i:Sher[a-z]+|…)`,
~6.4×), a line anchor inside an alternation (`(?m)^…|…`, ~4.7×), and pure-literal alternation
throughput (`Sherlock|Street`, ~4×). These are spelled out in
[`docs/limitations.md`](docs/limitations.md).

## License

MIT — see [LICENSE](LICENSE).
