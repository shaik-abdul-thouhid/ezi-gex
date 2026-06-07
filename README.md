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
  drop it into the same front door. See [`docs/architecture.md`](docs/architecture.md).
- **Target-agnostic.** Pure computation over caller-provided memory — no syscalls,
  no global allocator, no platform assumptions in the library code. Imports and
  compiles anywhere Zig (plus `ezi_code`) does: native, `wasm32-freestanding` /
  `wasm32-wasi`, and bare-metal `*-freestanding` (verified to compile for all four).

## Status

Version `0.1.0` — the first tagged release. Pre-1.0, so the API may still change,
but everything in the public surface is annotated `@stable-since: v0.1.0` and is
covered by SemVer from this tag on. Tracks a recent Zig dev build (`0.17.0-dev`); it
will not compile on stable 0.16.

**What works is tested** (≈210 tests: per-module behaviour, cross-backend
conformance, runtime + comptime parity). The **first prefilter tier is now wired**:
the `literal` backend scans with `std.mem.indexOf` (SIMD `memchr` + Boyer–Moore–
Horspool) and `auto` reads the HIR `Analysis` to skip work on NFA patterns — a
leading-literal `memchr` prefilter, a `^`/`\A` start short-circuit, and a min-length
gate. There is still **no lazy-DFA backend**, so on general (non-prefixable) patterns
throughput is below RE2/Rust; the architecture absorbs a DFA without API changes —
see the *Performance* section.

## Installing

Via git ref (resolves the tag at fetch time):

```sh
zig fetch --save git+https://github.com/shaik-abdul-thouhid/ezi-gex.git#v0.1.0
```

Or via plain HTTP tarball (pins the content hash in `build.zig.zon`):

```sh
zig fetch --save https://github.com/shaik-abdul-thouhid/ezi-gex/archive/refs/tags/v0.1.0.tar.gz
```

Then in `build.zig` (the `ezi_code` dependency is resolved transitively — you only
add `ezi_gex`):

```zig
const ezi_gex = b.dependency("ezi_gex", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ezi_gex", ezi_gex.module("ezi_gex"));
```

## Quick look

```zig
const gex = @import("ezi_gex");

// ── runtime: compile a (possibly user-supplied) pattern; never crashes ──────
var diag: gex.Diagnostic = .{};
var re = gex.compileRuntime(gpa, "(?<user>\\w+)@(?<host>\\w+)", &diag, .{}) catch {
    // diag.message() + diag.faultySlice(pattern) tell you what and where.
    return;
};
defer re.deinit();

// The Scratch is the per-search working state — you own it; one per thread. The
// front door hands you only the *type*; you construct it off the backend's own
// init (allocator-backed here; `.initBuffer(buf, &re.program)` needs no allocator).
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
> 2. **Embedding many comptime programs bloats the binary.** Each `compileComptime` adds its
>    program tables to `ro_data`, and Unicode classes are large: one `\w` ≈ 800 ranges ≈ 6 KB
>    *per occurrence*, and counted repetition multiplies it — a single `\w{3,32}` is ~200 KB.
>    *Measured:* 30 realistic patterns added **~625 KB**; ~100 can be **2 MB+** (tens of MB if
>    they use counted Unicode-class repeats). The matching *code* is shared across all of
>    them, so the cost is almost entirely data.

## Supported syntax

| Category | Supported |
|---|---|
| Literals, `.`, `\|`, `*` `+` `?` `{m,n}`, lazy `*?`… | ✅ |
| Groups `(…)`, `(?:…)`, named `(?<n>…)`/`(?P<n>…)` | ✅ |
| Classes `[...]`, `[^...]`, ranges, `\d \w \s` (+ negations) | ✅ |
| Unicode `\p{L}` `\P{…}` `\p{Script=…}`, `\pL` | ✅ |
| Anchors `^ $ \A \z`, word boundary `\b \B`, multiline `(?m)` | ✅ |
| Inline flags `(?i)` `(?m)` `(?s)`, scoped `(?i:…)` | ✅ |
| Escapes `\n \t \xHH \x{…} \u{…} \cX`, comments `(?#…)` | ✅ |
| Backreferences, lookaround, atomic/conditional, recursion, `\Q…\E` | ❌ rejected with a precise error |
| `\X` grapheme | ⚠️ parses, not yet executable |

Anchors are JS/RE2-style: `$` without `(?m)` is end-of-input (`\z`), and `\Z` is
treated as `\z`. See [`docs/architecture.md`](docs/architecture.md) §Caveats.

## Backends

| Backend | Strategy | Captures | Comptime | Use |
|---|---|---|---|---|
| `auto` *(default)* | dispatches the others | ✅ | ✅ | just use this |
| `pikevm` | breadth-first NFA | ✅ | ✅ | general, large inputs |
| `backtrack` | bounded depth-first NFA | ✅ | ✅ | small inputs |
| `literal` | substring / literal-alternation | whole-match | ✅ | pure-literal patterns |

`compileRuntime`/`compileComptime` use `auto`. Force one with the `*With` variants:
`gex.compileRuntimeWith(gex.backends.pikevm, gpa, pat, &diag, .{})`.

## Thread-safety

Compile once, share the immutable `Compiled`/`Program` across threads, and give **each
thread its own `Scratch`** — no locks, no atomics, no global state. **One caveat:** the
`backtrack` backend (which `auto` uses for small inputs) **allocates during a search** to
grow its visited set, so a per-thread `Scratch` also needs a per-thread or thread-safe
allocator — or use a buffer-backed `Scratch` (`initBuffer`) or the `pikevm` backend, which
never allocate while matching. Full details in
[`docs/architecture.md`](docs/architecture.md) §11.

## Performance

Honest about where it stands. **Tier 1 — the literal / prefilter fast path — is now
wired:**

1. The `literal` backend scans with `std.mem.indexOf`: SIMD `memchr` to locate a
   one-byte needle, Boyer–Moore–Horspool with a skip table for longer ones — instead
   of an `eql` at every byte position. On memchr-friendly needles that is **~20×** the
   old position-by-position scan; it is never slower.
2. `auto` consumes the HIR `Analysis` on NFA patterns: when every match must begin
   with a fixed literal, its first byte drives a `memchr` that skips straight to each
   candidate start (each confirmed with an *anchored* NFA run); a `^`/`\A` pattern
   skips the leftward scan entirely; and a min-length gate rejects inputs too short to
   hold any match. Every `Analysis` fact is a sound one-sided bound, so the prefilter
   never drops a real match — it only avoids running the NFA where one cannot start.

**Still open (additive, no API change):** a one-pass NFA capture path, and a lazy-DFA
backend (the RE2/Rust core — runtime-only, since it mutates state at match time). The
backend contract is exactly the seam to drop a DFA in without disturbing the comptime
path or the API. See [`docs/architecture.md`](docs/architecture.md) for the planned tiers.

## Documentation

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
