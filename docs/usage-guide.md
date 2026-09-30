# ezi_gex — usage guide (hands-on)

A copy-paste tutorial for **using** ezi_gex, end to end:

1. [Quick start](#1-quick-start) — match something in 30 seconds.
2. [The pipeline at a glance](#2-the-pipeline-at-a-glance) — `pattern → AST → HIR → Program → match`.
3. [Front-door recipes](#3-front-door-recipes) — `isMatch` / `find` / captures (`+At`, `groupIndex`/`groupName`) / `findAll` / `split` (`+N`) / replace (`replaceAll`/`replace`/`replaceN`/`replaceAllAlloc`/`replaceAllWith`).
4. [Comptime & no-allocator usage](#4-comptime--no-allocator-usage).
5. [Using the stages from lexing up](#5-using-the-stages-from-lexing-up) — drive the scanner, HIR, and a backend by hand.
6. [Reading the HIR](#6-reading-the-hir) — what the resolved IR looks like, with concrete output.
7. [The `Analysis` prefilter facts](#7-the-analysis-prefilter-facts).
8. [Writing your own backend](#8-writing-your-own-backend) — a complete, runnable example, built up step by step.
9. [Thread-safety](#9-thread-safety).
10. [Gotchas](#10-gotchas--semantics).
11. [Unicode syntax reference](#11-unicode-syntax-reference): every Unicode escape, property,
    and script, with all accepted spellings (Unicode 18.0).

> This is the *how-to*. For the *why* — the design, the contract's fine print, the
> performance roadmap — read [`architecture.md`](architecture.md). For the one-screen
> overview, the [README](../README.md). The doc comments on `core/hir.zig`,
> `engine/backend.zig`, and `engine/regex.zig` carry the same guidance inline.

Throughout, the import alias is:

```zig
const std = @import("std");
const gex = @import("ezi_gex");
```

(Add the dependency to your `build.zig.zon`/`build.zig` first — see the README.)

---

## 1. Quick start

```zig
var diag: gex.Diagnostic = .{};
var re = try gex.compileRuntime(gpa, "\\d+", &diag, .{}); // gpa: std.mem.Allocator
defer re.deinit();

// The caller OWNS the per-search scratch and makes it from the regex.
var sc = try re.initScratch(gpa);
defer sc.deinit(gpa);

std.debug.print("{}\n", .{re.isMatch(&sc, "abc123")});          // true
if (re.find(&sc, "abc123")) |m|
    std.debug.print("{s}\n", .{m.slice("abc123")});             // 123
```

Two things to internalize, because they recur everywhere:

- **`re` is immutable and shareable; `sc` is the mutable per-search state.** You build
  `sc` with `re.initScratch(gpa)` (or `re.initScratchBuffer(buf)`, no allocator) and pass
  `&sc` to every call. One `sc` per thread (see [§9](#9-thread-safety)). The types are
  nameable as `gex.Regex` / `gex.Scratch` (the default-backend regex and its scratch).
- **A bad pattern never crashes.** `compileRuntime` returns `error.InvalidPattern`
  and fills `diag` (code + byte span + message). Surface it however you like:

```zig
var re = gex.compileRuntime(gpa, "a(b", &diag, .{}) catch |e| switch (e) {
    error.InvalidPattern => {
        std.debug.print("{s} at \"{s}\"\n", .{ diag.message(), diag.faultySlice("a(b") });
        return; //                                unclosed_group at "("
    },
    else => return e,
};
```

---

## 2. The pipeline at a glance

```
 pattern ─scan─▶ AST ─hir.build─▶ Hir(+Analysis) ─Backend.build─▶ Program ─Engine─▶ match
 (text)         (syntax)         (resolved IR)                   (executable)      (result)
```

Each stage is a usable building block, re-exported from the root module. You almost
always want the front door (which runs all of them for you), but you can stop at any
stage or swap the last one out.

| Stage | Input → Output | Front-door call | Stage-on-its-own call |
|---|---|---|---|
| Lex + parse | `pattern` → `Ast` | (internal) | `gex.parse` / `gex.compile` / `gex.scan` |
| Lower | `Ast` → `Hir` | (internal) | `gex.buildHir` / `gex.buildHirComptime` |
| Compile | `Hir` → `Program` | (internal) | `Backend.buildAlloc` / `.buildComptime` |
| Match | `Program` + `Scratch` → result | `re.find` etc. | `gex.Engine(Backend).<op>` |

The front door (`compileRuntime`/`compileComptime`) glues the first three together and
hands you a `Compiled` you call match ops on. The rest of this guide shows both the
front door (§3–§4) and the hand-wired path (§5–§8).

---

## 3. Front-door recipes

Every recipe assumes `re` + `sc` are built as in [§1](#1-quick-start). All offsets in a
`Match` are **byte** offsets on UTF-8 boundaries; `m.slice(input)` gives the text.

### isMatch / find

```zig
_ = re.isMatch(&sc, "abc123");           // bool — cheapest; stops at the first match
_ = re.find(&sc, "x abc123 y");          // ?Match → "abc123"

// Start later, or require the match to begin exactly at the offset:
_ = re.findAt(&sc, input, .{ .start = 4 });
_ = re.isMatchAt(&sc, input, .{ .anchored = true }); // must match AT offset 0

// Search a sub-range without copying: `span_end` caps where a match may end.
// Returned offsets still index the full `input`.
_ = re.findAt(&sc, input, .{ .start = 4, .span_end = 12 }); // search input[4..12]
```

### Captures (numbered and named)

`captures` resolves submatches into a caller-owned `slots` array sized by `slotCount()`
(`= 2 * (capture_count + 1)`). Group 0 is the whole match; 1..N are the parens left to
right; a group that didn't participate reads back `null`.

```zig
var re = try gex.compileRuntime(gpa, "(?<user>\\w+)@(?<host>\\w+)", &diag, .{});
defer re.deinit();
var sc = try re.initScratch(gpa);
defer sc.deinit(gpa);

const slots = try gpa.alloc(?usize, re.slotCount()); // here: 6 = 2*(2+1)
defer gpa.free(slots);

if (re.captures(&sc, slots, "ping bob@example")) |c| {
    _ = c.match().slice("ping bob@example"); // "bob@example"  (group 0)
    _ = c.groupSlice(1).?;                    // "bob"          (group 1)
    _ = c.groupSlice(2).?;                    // "example"      (group 2)
    _ = c.namedSlice("user").?;               // "bob"          (by name)
    _ = c.namedSlice("host").?;               // "example"
}
```

`capturesAt(&sc, slots, input, .{ .start = n })` is the same but with `SearchOptions` — the
capture-filling peer of `findAt`/`isMatchAt`, for resuming or anchoring a capture search. And you
can map names ↔ indices straight from the compiled pattern, no match needed:

```zig
_ = re.groupIndex("user"); // ?usize → 1
_ = re.groupName(1);       // ?[]const u8 → "user"
```

### Iterate all matches / count

```zig
var it = re.findAll(&sc, "a1 b22 c333");
while (it.next()) |m| std.debug.print("{s}\n", .{m.slice("a1 b22 c333")}); // 1, 22, 333
_ = re.count(&sc, "a1 b22 c333");            // 3
```

To iterate *captures* per match, use `capturesAll` — but note each yielded `Captures`
borrows the **shared** `slots` and is only valid until the next `next()`:

```zig
var ci = re.capturesAll(&sc, slots, input);
while (ci.next()) |c| {
    const g1 = c.groupSlice(1); // use it NOW; the next iteration overwrites slots
    _ = g1;
}
```

### split

The pattern is the separator; the pieces between matches are yielded (empty matches are
skipped, the final piece is always yielded):

```zig
var sep = try gex.compileRuntime(gpa, "\\s+", &diag, .{});
defer sep.deinit();
var ssc = try sep.initScratch(gpa);
defer ssc.deinit(gpa);

var parts = sep.split(&ssc, "the  quick fox");
while (parts.next()) |p| std.debug.print("[{s}]", .{p}); // [the][quick][fox]

var head = sep.splitN(&ssc, "the  quick fox", 2); // at most 2: [the][quick fox]
while (head.next()) |p| std.debug.print("[{s}]", .{p});
```

### replace (templates, counts, an owned string, or a callback)

The template references captures: `$0`/`$&` is the whole match, `$1`/`${name}` reference groups
(`${0}`/`${12}` to disambiguate), and `$$` is a literal `$`. There are four forms:

```zig
var re = try gex.compileRuntime(gpa, "(\\w+)@(\\w+)", &diag, .{});
defer re.deinit();
var sc = try re.initScratch(gpa);
defer sc.deinit(gpa);
const slots = try gpa.alloc(?usize, re.slotCount());
defer gpa.free(slots);

// (a) write to any std.Io.Writer:
var buf: [128]u8 = undefined;
var w = std.Io.Writer.fixed(&buf);
try re.replaceAll(&sc, "from a@b to c@d", "$2.$1", slots, &w);
std.debug.print("{s}\n", .{w.buffered()});                 // from b.a to d.c

// (b) get an owned []u8 (no Writer to manage):
const out = try re.replaceAllAlloc(gpa, &sc, "a@b c@d", "$2.$1", slots);
defer gpa.free(out);                                       // "b.a d.c"

// (c) bounded — first match only (`replace`), or first n (`replaceN(..., n)`):
try re.replace(&sc, "a@b c@d", "<$1>", slots, &w);         // only "a@b" → "<a>"

// (d) callback — compute each replacement from the captures:
try re.replaceAllWith(&sc, "a@b c@d", slots, &w, {}, struct {
    fn run(_: void, c: gex.Captures, out_w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (c.groupSlice(1).?) |ch| try out_w.writeByte(std.ascii.toUpper(ch));
    }
}.run);                                                    // "A C"
```

> **Performance:** a template that references no group (a constant, or only `$0`) runs at
> span-search speed — the capture engine is skipped entirely. Only `$1`+/`${name}` templates pay
> for captures.

### Choosing a specific backend

The default backend is `auto` — it picks the span engine from the pattern (literal scan /
eager DFA / lazy DFA / Pike VM) and the capture engine (`onepass` for one-pass patterns, else
the Pike VM), switching per search (backtrack vs. Pike VM, eager vs. lazy DFA). To pin one,
use the `*With` constructors — the returned `Compiled` has the exact same API:

```zig
const pikevm = gex.backends.pikevm; // or .backtrack / .literal / .onepass / .auto / .bytepike / .dfa / .edfa
var re = try gex.compileRuntimeWith(pikevm, gpa, "\\w+", &diag, .{});
defer re.deinit();
```

> **The `edfa` backend is the eager DFA — the default span engine, span-only, comptime
> *and* runtime.** `gex.backends.edfa` fully determinizes the byte automaton at build time
> into a frozen `states × byte_classes` table, so its `Scratch` is empty, its `find` is
> **O(input) on every pattern** (a build-time strategy choice — see below), and it works at
> **comptime** (`compileComptimeWith(edfa, …)` bakes the table into `ro_data`) as well as
> runtime. It finds the match *span* fast but does not fill captures
> (`re.captures`/`re.replaceAll` are a `@compileError` on it; use `auto`/`pikevm`). Its
> capability gate runs patterns with `\A`/`^` (`text_start`), anchored-end `$`/`\z`
> (`text_end`), **non-prone `(?m)` line anchors** (`(?m)^`/`(?m)$`, via anchored restart with
> line context), and **isolated `\b`/`\B`** (evaluated as **ASCII** word boundaries baked into the
> byte classes — the lazy `dfa` carries the *Unicode* `\b` for non-ASCII input). It declines
> `\X`, a **mixed** `$` (`a$|b`), a **prone** `(?m)`/`\b`, a *chained* `\b\b`, and `\b` combined
> with `$`/`(?m)` — a **prone leading `(?m)^`** (`log_line`) then routes to the **lazy DFA** (its
> single-pass line support is quadratic-immune), the rest to the code-point engines. It is **bounded**: a
> pattern whose full DFA exceeds `edfa.max_states` is declined (`error.Unsupported` / a
> `@compileError`) — `auto` then falls back to the lazy `dfa`. Pin it directly when you want a
> comptime-bakeable DFA; otherwise just use `auto`, which prefers it.
>
> **The strategy is fixed at build, not probed per search.** A *non-prone* pattern (its
> consuming loop is itself accepting, e.g. `\w+`, `\d+`, `[A-Za-z]+`) uses a single greedy
> **anchored restart** per match; a *prone* pattern (one that can consume an unbounded run
> before it can accept, e.g. `\w+@\w+`'s pre-`@` word run) uses the **reverse-DFA two-pass**
> (forward locates the match end, a frozen reverse DFA the start) — O(input), no Θ(n²). The
> eager DFA also builds **only the tables it will use** (a non-prone `\w+` keeps just its
> forward table, not the forward + `.*?`-prefix + reverse trio).

> **The `dfa` backend is the lazy DFA — span-only, runtime-only, the *fallback*.**
> `gex.backends.dfa` determinizes the byte automaton on the fly (one cached DFA state per
> byte). It does not fill captures (`re.captures`/`re.replaceAll` are a `@compileError` on
> it; use `auto`/`pikevm`). It runs `\A`/`^` (`text_start`), anchored-end `$`/`\z`,
> **Unicode `\b`/`\B`** (via the *decode-hybrid* — it decodes the adjacent code points only at
> boundary positions), and **a single leading `(?m)^`** (line-gated forward re-seed + reverse
> line-accept — O(input), no anchored restart, so a *prone* newline-crossing line pattern like
> `log_line` runs here rather than the Pike VM), and only at runtime (no
> `compileComptimeWith(dfa, …)`, because its cache mutates while matching). It declines `\X`,
> `(?m)$` / interior `(?m)^`, and `\b`+`$` (the code-point engines cover those). Through `auto` it
> is the arm reached when the eager `edfa` overflows its `max_states` bound **or declines a prone
> leading `(?m)^`**, and for **Unicode** `\b` on non-ASCII input; you rarely pin it. When you *do* pin it, its
> determinization cache is bounded by a `ScratchOptions`: plain `re.initScratch(gpa)` uses the
> default (`max_bytes = 1 MiB`, `on_full = .reset` — clear the cache and continue). To override it,
> build the backend's scratch yourself and wrap it:
> `var sc = @TypeOf(re).Scratch.fromBackend(try gex.backends.dfa.Scratch.initOptions(gpa, &re.program, .{ .max_bytes = …, .on_full = … }));`
> (`on_full`: `.reset` / `.give_up` (fail the search; `auto` then routes to the NFA) / `.grow`).
> Only the lazy `dfa` has a growable cache; every other backend's scratch takes no options.

### Options

`compile*` takes a comptime-known `Options` with two tiers — **semantic** flags
(change what matches) and a results-invariant **`strategy`** tier (now wired):

```zig
// case folding: .none / .simple (default) / .full (1→many, e.g. ß→ss)
_ = try gex.compileRuntime(gpa, "(?i)te:t://", &diag, .{ .case_fold = .simple }); // (?i) → [Tt] etc.
_ = try gex.compileRuntime(gpa, "(?i)abc",     &diag, .{ .case_fold = .none });   // (?i) ignored
_ = try gex.compileRuntime(gpa, "(?i)stra\u{00DF}e", &diag, .{ .case_fold = .full }); // also matches "strasse"

// Seed (?i)/(?m)/(?s) for the WHOLE pattern without writing the inline flag.
// Inline flags still compose; a scoped (?-i:…) group turns it back off locally.
_ = try gex.compileRuntime(gpa, "abc", &diag, .{ .case_insensitive = true });        // == "(?i)abc"
_ = try gex.compileRuntime(gpa, "^a$", &diag, .{ .multiline = true });               // == "(?m)^a$"
_ = try gex.compileRuntime(gpa, "a.b", &diag, .{ .dot_matches_newline = true });     // == "(?s)a.b"

// ASCII mode: \d \w \s use the classic ASCII sets (smaller automata). `.` and `\b`
// stay Unicode-aware. Default is unicode = true.
_ = try gex.compileRuntime(gpa, "\\w+", &diag, .{ .unicode = false });               // \w = [0-9A-Za-z_]

// max_repetition: ceiling on a {m,n} bound (default 100_000). A finite bound past it
// is rejected AT SCAN TIME with `error.InvalidPattern` (code `quantifier_exceeds_limit`)
// — a DoS guard, before any lowering. Lower it to harden against adversarial input.
_ = try gex.compileRuntime(gpa, "a{4000}", &diag, .{});                               // ok (< 100_000)
_ = gex.compileRuntime(gpa, "a{9}", &diag, .{ .max_repetition = 8 });                 // → error.InvalidPattern
// diag.code == .quantifier_exceeds_limit. (The hard u32 ceiling stays `quantifier_too_large`.)
// The same ceiling reaches the AST/scanner layers via Limits: gex.parseWith / gex.compileWith /
// gex.scanWith all take `gex.Limits{ .max_repetition = … }` (default `gex.default_max_repetition`).

// size_limit: ceiling on the EXPANDED pattern (gex.hir.expandedSize ≈ NFA instructions once {m,n}
// unrolls; default 1_000_000). max_repetition bounds each count; nested counts multiply, and this
// bounds the product. Over it: error.PatternTooComplex (diag.code = .pattern_too_complex) before
// anything is built. Lower it when compiling untrusted patterns.
_ = gex.compileRuntime(gpa, "(?:(?:a{1000}){1000}){1000}", &diag, .{}); // → error.PatternTooComplex (10^9 copies)
_ = try gex.compileRuntime(gpa, "a{40}", &diag, .{ .size_limit = 100 });  // ok (82 units)

// strategy tier — results-invariant: flipping any field changes only speed/memory,
// never which text matches.
//   byte_engine: .auto (default) ≡ .enabled → `auto` builds the byte DFA and uses it for
//                isMatch/find on an eligible pattern (most patterns — incl. $/\z, ASCII \b,
//                and non-prone (?m); only \X, a mixed $, a prone (?m)/\b stay on the Pike VM).
//                It PREFERS the eager DFA (a frozen table, O(n) find on every pattern),
//                falling back to the lazy DFA when the eager table overflows its state bound
//                (or for Unicode \b on non-ASCII input); captures come from `onepass` or the
//                Pike VM anchored at the DFA span, so the result is identical, just 5–10×
//                faster on a class scan. .disabled = compact NFA-only (minimal
//                memory; right for match-once / tiny inputs).
_ = try gex.compileRuntime(gpa, "\\w+", &diag, .{}); // DFA on by default — no flag needed
_ = try gex.compileRuntime(gpa, "\\w+", &diag, .{ .strategy = .{ .byte_engine = .disabled } });
//   prefilter (default true) → whole-run SIMD memmem start-skip + rarest-required-byte
//   fast-reject; set false to scan without probing. unicode_word_boundary_in_dfa stays reserved.
_ = try gex.compileRuntime(gpa, "abc", &diag, .{ .strategy = .{ .prefilter = false } });
//   simd: .auto (default) / .off → governs the SIMD literal accelerators: the two-byte memmem
//                for a SINGLE literal (Sherlock), Teddy for literal ALTERNATIONS (cat|dog|fish),
//                and auto's ≥2-byte prefix start-skip. .auto uses SIMD where the target supports
//                it (memmem is portable @Vector everywhere; Teddy needs x86 SSSE3/AVX2 or ARM
//                NEON), else a portable scalar scan; .off forces the scalar scan everywhere. A
//                PERMISSION, not a command — no way to force SIMD onto a target that lacks it.
_ = try gex.compileRuntime(gpa, "cat|dog|fish", &diag, .{ .strategy = .{ .simd = .off } });
```

> **The byte engine self-gates and stays compact.** `auto` builds the byte automaton only
> when it is *worth it*: `byteWorthLowering` keeps a
> pathologically large pattern (a big Unicode class repeated dozens of times, e.g.
> `\p{L}{60}`) on the code-point engine instead — still correct, just not DFA-accelerated.
> The automaton itself is kept small by UTF-8 suffix sharing and single-copy `x+`
> compilation (`\w+` is ~3.9 k instructions, down from ~11 k; ASCII patterns are
> unchanged). The default is the **eager** DFA — it freezes the whole DFA into a
> `states × byte_classes` table at build, but **builds only the tables it will use** (a
> non-prone `\w+` keeps just its forward table, ~141 KB, not the forward + `.*?`-prefix +
> reverse trio); if a pattern's full table overflows the state bound, `auto` falls back to
> the **lazy** DFA, which materializes only the states a given input visits (a handful over
> ordinary text), so it never pays for the whole state space. None of this changes a match
> — only which engine runs. (To bake a DFA into `ro_data` at comptime, see the **eager
> DFA** — `gex.backends.edfa` — above / in `architecture.md`.)

> **The SIMD prefilter (`simd`) accelerates literals, transparently.** A **single** literal
> (`Sherlock`, `Sherlock Holmes`) is scanned by a portable **`memmem`** (`engine/memmem.zig`):
> probe the *rarest* needle bytes, AND their `@Vector` equality masks across a 16/32-byte chunk, and
> verify only where they coincide — far fewer candidates than a one-byte memchr on a common lead
> byte. It scans four chunks per iteration (after a short single-chunk warm-up so dense matches
> return at once) and adds a third probe byte for short all-common needles like `the`. It is **fully
> portable** (SSE2 `pcmpeqb`/NEON via `@Vector`, no arch asm), so it runs everywhere. A
> literal **alternation** (`cat|dog|fish`, `foo|far|fizz`) is scanned by **Teddy** instead: one
> dynamic in-vector byte shuffle (`pshufb`/`vpshufb`/`tbl`) fingerprints the first 1–3 bytes of
> *all* branches across a 16-byte chunk at once, then verifies — far more selective than a
> per-branch scan when branches share a first byte. Teddy picks **fat** (16 buckets, AVX2) for
> large sets, else **slim** (≤8 buckets); its single piece of architecture-specific inline asm is
> quarantined in `engine/simd.zig`, and the comptime path / any target without a native shuffle
> uses the portable scalar scan. The same two-byte `memmem` also drives `auto`'s ≥2-byte prefix
> start-skip (`\bthe\b`, `the\s+\p{L}+`). `simd = .off` opts all of it out. Results-invariant —
> each finds exactly the match the scalar scan would.

> `(?x)` **verbose / extended mode** is a lex-time flag, so it has no `Options` field —
> set it inline (`(?x)…` globally, `(?x:…)` scoped). In verbose mode unescaped
> whitespace and `#`-to-end-of-line comments outside a class are insignificant; escape
> a literal space as `\ `.

---

## 4. Comptime & no-allocator usage

A pattern known at compile time can be baked into `ro_data` — **no allocator, no
`deinit`**. A bad pattern is a `@compileError` (you can't ship a binary with a broken
regex).

```zig
const re = comptime gex.compileComptime("\\d{3}-\\d{4}", .{});
```

There are then **two** ways to match:

### (a) Match *at* comptime — the result is a compile-time constant

```zig
const ok  = comptime re.isMatchComptime("call 555-1234");   // true (folded into the binary)
const hit = comptime re.findComptime("x 555-1234 y").?;     // Match{ .start = 2, .end = 10 }
const n   = comptime re.countComptime("1 22 333");          // (compile-time usize)
const c   = comptime re.capturesComptime("555-1234");       // ?Captures over ro_data
_ = .{ ok, hit, n, c };
```

These run the whole match in the compiler's const-evaluator. Great for compile-time
validation/lookup tables; bounded by the eval-branch quota (see the warning below).

> Under the default `auto`, a *tiny* pattern (small ASCII classes / alternations / counted
> reps, e.g. `\d{4}-\d{2}`) now matches at comptime on a **real frozen eager DFA** baked into
> `ro_data` — the genuine CTRE-lane — because the eager DFA freezes its table at build (the
> lazy DFA, whose cache mutates while matching, can't run at comptime at all). A big Unicode
> class (`\w`, `\p{L}`) or `.` is too memory-hungry to determinize in const-eval, so it stays
> on the Pike VM at comptime — but still gets the eager DFA at **runtime**. None of this
> changes the result, only which engine the const-evaluator runs.

### (b) Match at runtime with a **buffer** Scratch (still no allocator)

The backend's scratch exposes a buffer convention (`Buf` / `bufferLen` / `initBuffer`),
surfaced on the regex as `scratchBufferLen()` / `initScratchBuffer(buf)`, so you can back
the scratch with a stack/`ro_data` array instead of the heap:

```zig
const re = comptime gex.compileComptime("[a-z]+\\d+", .{});

var buf: [re.scratchBufferLen()]gex.Scratch.Buf = undefined; // exact size, no heap
var sc = try re.initScratchBuffer(&buf);
_ = re.find(&sc, "??abc12!!").?.slice("??abc12!!");          // "abc12"
```

This also works for a **runtime**-compiled regex when you want zero allocation during
matching — `initBuffer` over a fixed `[N]Buf` never allocates (unlike `init`).

> **⚠️ Comptime is bounded.** `compileComptime` lowers the whole pipeline in const-eval
> and bakes the program into the binary, including its class ranges (~6.3 KB per *distinct*
> `\w`; identical classes within a pattern are interned, so `\w{3,32}` costs one `\w`, not
> 35). Large/pathological patterns can blow the eval-branch quota or grow `ro_data`. For
> those, prefer `compileRuntime` (no ceiling). The shared Unicode *tables* are a fixed
> one-time cost, not per-pattern. The trade-off is yours to make — see
> [`architecture.md`](architecture.md) §3 and §3.1.

---

## 5. Using the stages from lexing up

You don't have to go through the front door. Each stage is independently usable. This is
the path when you want *only* a parser, *only* the Unicode-resolving HIR, or to drive a
chosen backend by hand. (`src/main.zig` is a runnable tour of this.)

### a) Lex + parse → `Ast`

`gex.parse` (heap, free with `ast.deinit`) returns the flat AST and fills a `Diagnostic`
on failure; `gex.compile` is the comptime twin (bad pattern → `@compileError`).

```zig
var diag: gex.Diagnostic = .{};
const ast = gex.parse(gpa, "a(b|c)*", &diag) catch {
    std.debug.print("{s}\n", .{diag.message()});
    return;
};
defer ast.deinit(gpa);

// The tree is three flat arrays — no heap pointers inside nodes:
//   ast.nodes[]       every node; ast.nodes[ast.root] is the ROOT (last-emitted, not 0)
//   ast.children[]    packed child-index lists for concat/alternation
//   ast.class_items[] packed members of each [...] class
std.debug.print("{d} groups, root = node {d}\n", .{ ast.capture_count, ast.root });
```

A traversal is a `switch` on `node.tag` (see `NodeTag` in `core/ast.zig`). The comptime
variant bakes the AST into `ro_data`:

```zig
const ct_ast = comptime gex.compile("\\d{3}-\\d{4}"); // no allocator, no deinit
_ = ct_ast.nodes.len;
```

### b) Lower → `Hir`

`gex.buildHir` (free with `gex.freeHir`) applies flags, folds case, and resolves all
Unicode to **sorted code-point ranges** — and hands you `h.analysis` for free. Reach for
it when you want the *resolved* form without building a `Program` (e.g. to read a
pattern's required bytes, or to feed your own matcher).

```zig
const ast = try gex.parse(gpa, "(?i)\\w+", &diag);
defer ast.deinit(gpa);
const h = try gex.buildHir(gpa, ast, .{ .case_fold = .simple }); // opts: gex.HirOptions
defer gex.freeHir(gpa, h);

// Everything is resolved now: `\w` is h.ranges[...], the `(?i)` flag is gone.
const an = h.analysis;
std.debug.print("min_len={d} anchored={}\n", .{ an.min_len, an.anchored_start });
```

Comptime variant returns an `Outcome` union you switch on:

```zig
const H = comptime switch (gex.buildHirComptime(gex.compile("\\d+"), .{})) {
    .ok => |x| x,
    .fail => @compileError("bad pattern"),
};
_ = H;
```

### c) Compile → `Program`, then match via `Engine`

Pick a backend, build its `Program` from the HIR, and call `Engine(Backend)` ops on a
bare `Program` + `Scratch` (no `Compiled` wrapper). The `Program` is **self-contained**,
so you may free the AST and HIR the moment it's built.

```zig
const input = "ping bob@example.com";
const PikeVM = gex.backends.pikevm;          // or .backtrack / .literal / .auto
const E = gex.Engine(PikeVM);                // the agnostic op layer for this backend

const ast = try gex.parse(gpa, "(\\w+)@(\\w+)", &diag);
defer ast.deinit(gpa);
const h = try gex.buildHir(gpa, ast, .{});
defer gex.freeHir(gpa, h);

var program = try PikeVM.buildAlloc(gpa, h, .{}); // safe to freeHir right after this
defer PikeVM.freeProgram(gpa, &program);
var scratch = try PikeVM.Scratch.init(gpa, &program);
defer scratch.deinit(gpa);
const meta = gex.engine.Meta{ .capture_count = h.capture_count };

_ = E.isMatch(&program, &scratch, input, .{});
if (E.find(&program, &scratch, input, .{})) |m| _ = m.slice(input);

var slots: [6]?usize = undefined; // 2 * (capture_count + 1)
var it = E.capturesAll(&program, &scratch, input, &slots, meta, .{});
while (it.next()) |c| _ = c.groupSlice(1);
```

### d) No allocator at all — storage-agnostic `scan`

The scanner never allocates: `gex.scan` fills buffers *you* provide, each sized by
`requiredSizes(pattern.len)`. The returned `Ast` sub-slices them, so keep them alive.
The same buffer trick provisions the HIR (`hir.measure`/`hir.build`) and the NFA program
— the `buildComptime` wrappers are just this with `ro_data` arrays.

```zig
const S = gex.scanner;
const pat = "a(b|c)*";
const n = comptime S.requiredSizes(pat.len);
var nodes:    [n.nodes]gex.ast.Node = undefined;
var children: [n.children]u32 = undefined;
var items:    [n.class_items]gex.ast.ClassItem = undefined;
var names:    [n.names][]const u8 = undefined;
var seq:      [n.seq]u32 = undefined;
var alt:      [n.alt]u32 = undefined;
var frames:   [n.frames]S.Frame = undefined;

var diag: gex.Diagnostic = .{};
const ast = try S.scan(pat, &diag, .{
    .nodes = &nodes, .children = &children, .class_items = &items,
    .names = &names, .seq = &seq, .alt = &alt, .frames = &frames,
});
_ = ast; // valid while the buffers above are in scope
```

---

## 6. Reading the HIR

The `Hir` is **fully desugared**: no flags, no `\d`, no Unicode lookups left. Walk it by
starting at `h.nodes[h.root]` and switching on `node.tag`; the tag names the active field
of the bare union `node.data`. Children/ranges/literals are referenced by `(start, len)`
index pairs into `h.children` / `h.ranges` / `h.literals`.

```zig
fn walk(h: gex.Hir, idx: u32) void {
    const node = h.nodes[idx];
    switch (node.tag) {
        .empty => {},
        .literal => {
            const r = node.data.run;                       // Node.Run{ start, len }
            for (h.literals[r.start..][0..r.len]) |cp| { _ = cp; }
        },
        .class => {
            const c = node.data.class;                     // Node.Class{ start, len }
            // len == 0 ⇒ matches NOTHING (a fully-negated set), not a wildcard.
            for (h.ranges[c.start..][0..c.len]) |rg| { _ = rg; } // [lo, hi]
        },
        .any => { _ = node.data.any.dot_all; },            // `.`  (dot_all ⇒ matches \n too)
        .grapheme => {},                                   // `\X` — opaque
        .anchor => { _ = node.data.anchor.kind; },         // AnchorKind (m already applied)
        .concat, .alternation => {
            const d = node.data.children;                  // Node.Children{ start, len }
            for (h.children[d.start..][0..d.len]) |ci| walk(h, ci);
        },
        .repetition => walk(h, node.data.repetition.child),
        .capture => walk(h, node.data.capture.child),
    }
}
```

### What resolution looks like (concrete)

`core/hir.zig` ships a compact s-expression dumper, `gex.hir.formatHir(h, writer)`,
handy for debugging. Here is what several patterns lower to (these are the engine's own
test expectations):

| Pattern | HIR s-expression | Note |
|---|---|---|
| `abc` | `(run a b c)` | adjacent literals coalesce into one run |
| `a(?:bc)d` | `(run a b c d)` | non-capturing group inlined, runs merged |
| `a(b\|c)d` | `(cat (run a) (cap 1 (alt (run b) (run c))) (run d))` | capture keeps its index |
| `a{2,4}?` | `(rep 2 4 l (run a))` | `{m,n}` stays compact; `l` = lazy |
| `^a$` | `(cat (anc text_start) (run a) (anc text_end))` | `$` is `\z` (end of input) |
| `(?m)^a$` | `(cat (anc line_start) (run a) (anc line_end))` | multiline resolves the anchors |
| `[c-ea-b]` | `(cls a-e)` | classes are sorted + merged |
| `[^0]` | `(cls U+0-/ 1-U+10FFFF)` | negation already applied (`/` is U+002F, `1` is U+0031) |
| `(?i)a` | `(cls A a)` | `(?i)` folded a letter into a tiny class |
| `.` / `(?s).` | `(any)` / `(any.)` | dot-all flag baked in |

The takeaway: a backend that consumes the HIR **never** sees a flag, a `\d`, or a
Script name — only literals, sorted positive ranges, anchors, and the tree structure.

---

## 7. The `Analysis` prefilter facts

`h.analysis` carries cheap, **sound** facts about *every* match — each holds for every
match, so a prefilter or length gate built on them never drops a real match. The `auto`
dispatcher consumes several to skip work; you can read them too (e.g. to pick a `memchr`
needle, or gate a search before calling the engine). Since **0.4.0** `auto` skips on the
*whole* `prefix_literal` run (a SIMD `memmem`-style leap — `\bthe\b` jumps "the"→"the",
not 't'→'t'), not just its first byte — a ≥2-byte run via the portable two-byte
`memmem.Finder` (probe the two rarest bytes, AND their `@Vector` masks).

```zig
const h = try gex.buildHir(gpa, try gex.parse(gpa, "abc[0-9]+xy$", &diag), .{});
defer gex.freeHir(gpa, h);
const an = h.analysis;

_ = an.anchored_start;   // false — no leading ^/\A
_ = an.anchored_end;     // true  — trailing $ (no multiline) ⇒ text_end
_ = an.min_len;          // 6     — a b c <digit> x y (code points)
_ = an.max_len;          // null  — the + is unbounded
_ = an.min_utf8_len;     // 6     — bytes; ≥ min_len (here all ASCII)
_ = an.prefix_literal;   // Node.Run for "abc" — every match starts with it
_ = an.required_literal; // Node.Run for "abc" — longest run every match must contain
_ = an.required_bytes;   // a 256-bit ByteSet: has 'a','b','c','x','y'; NOT '0'
// 0.4.0 prefilter facts (also one-sided bounds):
_ = an.prefix_set;          // leading literal of every branch of a top-level alternation (→ Teddy)
_ = an.inner_anchor;        // a required literal right after a leading class run ([\w.+-]+@…, \d{4}-…)
_ = an.inner_anchor.?.lead_fixed_cps; // 0.5.0: code-point length of the leading run when FIXED (\d{4}- → 4)
_ = an.leading_class_first; // first-byte set of a leading class with no fixed literal (\d+ → {0-9,…})
_ = an.line_anchored_start; // every match begins at a line start ((?m)^ / ^)
// 0.6.0 prefilter fact:
_ = an.required_literal_skip; // a required interior/suffix literal (\w+\s+Holmes, [a-zA-Z]+ing):
                              //   .run (the memmem needle), .lead_class (preceding alphabet),
                              //   .lead_fixed_cps (fixed cp-offset, e.g. [a-q][^u-z]{13}x → 14),
                              //   .is_suffix, and .pre/.pre_n (disjoint class-rep pre-atoms for the
                              //   structured reverse walk to the exact start)
```

Since **0.5.0** `auto` consumes three more facts (all results-invariant): a `\b`-wrapped pure
literal (`\bthe\b`, `the\b`) is confirmed by an **O(1) word-boundary check** rather than a
per-occurrence anchored automaton walk; a **fixed-length** leading run before an `inner_anchor`
(`\d{4}-…`, via `lead_fixed_cps`) lets the skip jump anchor-to-anchor and bounded-confirm at the
pinned start on ASCII input; and a `(?m)^…` pattern with no eager DFA (`line_anchored_start`)
attempts the match anchored at each **line start** for span and captures. `auto` also gates the
eager-DFA build attempt on byte-NFA size, so a big Unicode-class join (`\w+@\w+`, email) uses the
lazy DFA directly instead of a multi-hundred-ms determinization (email compile ~0.88 s → ~6 ms).

Since **0.6.0** `auto` consumes `required_literal_skip` (results-invariant): a pattern with no
leading literal but a selective literal in its **interior or suffix** (`\w+\s+Holmes`,
`[a-zA-Z]+ing`) leaps to that literal with `memmem`, then — when the atoms before it are **disjoint
class-repetitions** — does a **structured reverse walk** backward to the *exact* match start and
runs one anchored confirm per hit (the automaton runs only at real candidate starts, not over the
gaps; ASCII-exact, with a sound flat-scan fallback for non-ASCII windows). A bounded fixed-length
pattern with a **rare byte at a fixed code-point offset** (`[a-q][^u-z]{13}x`) instead `memchr`s the
byte and confirms at the pinned start.

A couple more, illustrating soundness:

```zig
// Top-level alternation: nothing is unconditionally required (but `prefix_set` holds each
// branch's leading literal — Holmes…|Watson… — for the multi-prefix Teddy skip).
//   "cat|dog" → prefix_literal == null, required_literal == null, required_bytes empty.

// Multi-byte bytes vs. code points:
//   "\bné\b" → min_len = 2 (code points), but min_utf8_len = 3 (é is 2 bytes),
//              has_word_boundary = true.

// Unbounded:
//   "a.*"   → max_len == null, max_utf8_len == null, min_utf8_len == 1.
```

Use them as **one-sided bounds** ("must hold for every match" → safe to prefilter on),
never as "this exact thing matches". Full field list: the `Analysis` doc comment in
`core/hir.zig`, and [`architecture.md`](architecture.md) §7.

---

## 8. Writing your own backend

A backend is a `type` (namespace) satisfying `engine/backend.zig`. Your job is narrow:
**turn a `Hir` into a `Program`, and locate a match / fill a `slots` array.** The
`Engine(Backend)` layer turns those two primitives into the *entire* user-facing API —
you write no iteration, capture views, or template expansion.

Below is a **complete, runnable** backend, built up in four steps. It handles only
patterns that reduce to a single literal run or a literal alternation (`abc`,
`cat|dog`) — it rejects everything else at build — and scans for them by bytes. It is a
trimmed teaching version of the real `engine/backends/literal.zig`; read that for the
production details (fast `indexOf`, priority handling).

### Step 1 — the mandatory surface

```zig
const std = @import("std");
const gex = @import("ezi_gex");
const Be = gex.Backend;        // engine/backend.zig: Caps, Match, SearchOptions, BuildError…
const Hir = gex.Hir;

pub const DemoLiteral = struct {
    // (1) Capabilities — the dispatcher/front door read these at comptime.
    //     We can report the whole match (group 0), and we keep no per-search state.
    pub const caps = Be.Caps{ .captures = true, .stateless = true };

    // (2) The compiled program — POD/slices ONLY, so it lives in ro_data or the heap.
    //     Each branch's UTF-8 bytes are concatenated; `bounds` delimits them.
    const Bound = struct { start: u32, len: u32 };
    pub const Program = struct {
        needles: []const u8,
        bounds: []const Bound,
    };

    // (3) Per-search state — none here. An empty struct WITH the standard lifecycle
    //     (all no-ops) so the front door treats it like a stateful backend, and the
    //     buffer convention (Buf/bufferLen/initBuffer) so comptime matching works.
    pub const Scratch = struct {
        pub const Buf = Be.Cell;                                   // buffer word type
        pub fn bufferLen(_: *const Program) usize { return 0; }    // we need 0 words
        pub fn init(_: std.mem.Allocator, _: *const Program) std.mem.Allocator.Error!Scratch { return .{}; }
        pub fn initBuffer(_: []Be.Cell, _: *const Program) Be.ScratchError!Scratch { return .{}; }
        pub fn reset(_: *Scratch) void {}
        pub fn deinit(_: *Scratch, _: std.mem.Allocator) void {}
    };

    pub const Options = struct {}; // HIR already applied flags/folding; nothing needed
    // …build + match methods follow in steps 2–3…
};
```

### Step 2 — build: `Hir → Program`

Use the library's **measure-then-emit** idiom (one body, two modes) so the *same* code
serves `buildAlloc` (heap) and `buildComptime` (ro_data). The HIR root is either a single
`literal`, an `empty`, or an `alternation` of those — anything else is `error.Unsupported`.

```zig
    const Sizes = struct { bytes: u32, bounds: u32 };
    const Mode = enum { count, emit };

    // One body, two modes: `.count` measures exact sizes, `.emit` fills the buffers.
    // Identical control flow ⇒ identical sizes, so the SAME code serves buildAlloc
    // (heap) and buildComptime (ro_data) — the library's measure-then-emit idiom.
    fn Builder(comptime mode: Mode) type {
        return struct {
            const Self = @This();
            const is_emit = mode == .emit;
            h: Hir,
            needles: if (is_emit) []u8 else void = if (is_emit) undefined else {},
            bounds: if (is_emit) []Bound else void = if (is_emit) undefined else {},
            byte_len: u32 = 0,
            bound_len: u32 = 0,

            // Append one literal run as bytes. ASCII-only for brevity — a real backend
            // UTF-8-encodes each code point (the HIR guarantees valid scalars); see
            // engine/backends/literal.zig, which uses ezi_code's encoder.
            fn addRun(self: *Self, lit: gex.hir.Node.Run) error{Unsupported}!void {
                const start = self.byte_len;
                for (self.h.literals[lit.start..][0..lit.len]) |cp| {
                    if (cp > 0x7F) return error.Unsupported; // ASCII demo: reject non-ASCII
                    if (is_emit) self.needles[self.byte_len] = @intCast(cp);
                    self.byte_len += 1;
                }
                if (is_emit) self.bounds[self.bound_len] = .{ .start = start, .len = self.byte_len - start };
                self.bound_len += 1;
            }

            fn run(self: *Self) error{Unsupported}!void {
                const root = self.h.nodes[self.h.root];
                switch (root.tag) {
                    .literal => try self.addRun(root.data.run),
                    .empty => try self.addRun(.{ .start = 0, .len = 0 }),
                    .alternation => {
                        const d = root.data.children;
                        for (self.h.children[d.start..][0..d.len]) |ci| switch (self.h.nodes[ci].tag) {
                            .literal => try self.addRun(self.h.nodes[ci].data.run),
                            .empty => try self.addRun(.{ .start = 0, .len = 0 }),
                            else => return error.Unsupported, // a branch that isn't a literal
                        };
                    },
                    else => return error.Unsupported, // not a literal / alternation pattern
                }
            }
        };
    }

    fn measure(h: Hir) error{Unsupported}!Sizes {
        var b = Builder(.count){ .h = h };
        try b.run();
        return .{ .bytes = b.byte_len, .bounds = b.bound_len };
    }
    fn emit(h: Hir, needles: []u8, bounds: []Bound) error{Unsupported}!Program {
        var b = Builder(.emit){ .h = h, .needles = needles, .bounds = bounds };
        try b.run();
        return .{ .needles = needles[0..b.byte_len], .bounds = bounds[0..b.bound_len] };
    }

    pub fn supports(h: Hir) bool { // a custom `auto` calls this to gate routing
        if (h.capture_count != 0 or h.analysis.has_grapheme) return false;
        _ = measure(h) catch return false;
        return true;
    }

    pub fn buildAlloc(gpa: std.mem.Allocator, h: Hir, _: Options) Be.BuildError!Program {
        const sizes = measure(h) catch return error.Unsupported;
        const needles = try gpa.alloc(u8, sizes.bytes);
        errdefer gpa.free(needles);
        const bounds = try gpa.alloc(Bound, sizes.bounds);
        errdefer gpa.free(bounds);
        return emit(h, needles, bounds) catch error.Unsupported;
    }
    pub fn freeProgram(gpa: std.mem.Allocator, p: *Program) void {
        gpa.free(p.needles);
        gpa.free(p.bounds);
    }

    pub fn buildComptime(comptime h: Hir, comptime _: Options) Program {
        @setEvalBranchQuota(20_000 + @as(u32, @intCast(h.literals.len)) * 100);
        const sizes = comptime (measure(h) catch @compileError("DemoLiteral: not a literal / alternation"));
        comptime var needles: [sizes.bytes]u8 = undefined;
        comptime var bounds: [sizes.bounds]Bound = undefined;
        const prog = emit(h, &needles, &bounds) catch unreachable; // measure already validated
        const final_needles = needles[0..prog.needles.len].*; // promote to ro_data
        const final_bounds = bounds[0..prog.bounds.len].*;
        return .{ .needles = &final_needles, .bounds = &final_bounds };
    }
```

### Step 3 — the match primitives

`search` locates the leftmost match (and honors `o.start` / `o.anchored`); `isMatch`
delegates; `searchCaptures` additionally writes group 0 into `slots[0..2]`. That's the
*whole* matching contract — `Engine` builds `findAll`/`split`/`replaceAll`/etc. on top.

```zig
    // First occurrence of `needle` in `input` at/after `start`, or null. Fast SIMD
    // substring search at runtime; a plain scan at comptime — `std.mem.indexOfPos`
    // pulls @Vector into const-eval, which the project keeps out of comptime paths, so
    // guard with @inComptime() if you want findComptime/isMatchComptime to work.
    fn firstAt(input: []const u8, start: usize, needle: []const u8) ?usize {
        if (needle.len == 0) return if (start <= input.len) start else null;
        if (start + needle.len > input.len) return null;
        if (@inComptime()) {
            var i = start;
            while (i + needle.len <= input.len) : (i += 1)
                if (std.mem.eql(u8, input[i..][0..needle.len], needle)) return i;
            return null;
        }
        return std.mem.indexOfPos(u8, input, start, needle); // SIMD memchr / BMH
    }

    pub fn search(p: *const Program, _: *Scratch, input: []const u8, o: Be.SearchOptions) ?Be.Match {
        if (o.start > input.len) return null;
        var best: ?usize = null;
        var best_len: usize = 0;
        for (p.bounds) |b| { // bounds are in alternation (priority) order
            const needle = p.needles[b.start..][0..b.len];
            const at = if (o.anchored)
                (if (o.start + needle.len <= input.len and std.mem.eql(u8, input[o.start..][0..needle.len], needle)) o.start else null)
            else
                firstAt(input, o.start, needle);
            if (at) |pos| if (best == null or pos < best.?) {
                best = pos;
                best_len = needle.len; // strictly-earlier wins; equal pos keeps the earlier branch
            };
        }
        return if (best) |pos| .{ .start = pos, .end = pos + best_len } else null;
    }
    pub fn isMatch(p: *const Program, s: *Scratch, input: []const u8, o: Be.SearchOptions) bool {
        return search(p, s, input, o) != null;
    }
    pub fn searchCaptures(p: *const Program, s: *Scratch, input: []const u8, slots: []?usize, o: Be.SearchOptions) ?Be.Match {
        const m = search(p, s, input, o) orelse return null;
        if (slots.len >= 2) { slots[0] = m.start; slots[1] = m.end; } // group 0 = whole match
        return m;
    }
};
```

### Step 4 — verify and use it

```zig
comptime gex.verifyBackend(DemoLiteral); // assert the contract; precise compile error if not

var diag: gex.Diagnostic = .{};
var re = try gex.compileRuntimeWith(DemoLiteral, gpa, "cat|dog", &diag, .{});
defer re.deinit();
var sc = try re.initScratch(gpa);
defer sc.deinit(gpa);

_ = re.find(&sc, "i have a dog").?.slice("i have a dog"); // "dog"
_ = re.count(&sc, "cat dog cat");                          // 3 — Engine built this for free
```

It also runs at **comptime**, because `Program` is POD and the `Scratch` exposes the
buffer convention:

```zig
const cre = comptime gex.compileComptimeWith(DemoLiteral, "bird|fish", .{});
const found = comptime cre.findComptime("a big bird").?;
_ = found; // resolved entirely in the compiler
```

### Going further

- **Real captures (beyond group 0):** keep `caps.captures = true` and write group slots
  in `searchCaptures` — group `g` lives at `slots[2*g]` / `slots[2*g + 1]`. A
  non-participating group must stay `null` (`Engine` pre-zeroes `slots`).
- **Stateful backends:** put per-search state in `Scratch`, reset it at the top of each
  `search` (the built-ins do this in O(1) via a generation stamp), and carve a buffer
  `Scratch` with `Be.Carver` — see the `Carver` doc comment and `engine/backends/pikevm.zig`.
- **Don't reimplement matching — reuse the shared NFA.** `engine/nfa.zig` compiles ANY
  HIR (Unicode classes, repetition, captures, anchors) into a flat `nfa.Program`:
  `var prog = try gex.engine.nfa.buildAlloc(gpa, h);`. Make that your backend's `Program`
  and write only a *traversal* of `prog.insts` (the code-point primitives `nfa.inRanges`,
  `nfa.decodeAt`, `nfa.assertionHolds` are provided). The `pikevm` (breadth-first) and
  `backtrack` (depth-first) backends are exactly this — two traversals of one shared
  program. That's how you add a new engine (e.g. a lazy DFA) without re-doing the frontend.
- **Make `auto` route to you:** `engine/backends/auto.zig` is just one assembly of
  backends. Copy it, add your `supports`/route logic, and use *your* dispatcher as the
  default — nothing in the contract is privileged.

See [`architecture.md`](architecture.md) §4 (the contract), §5 (this example, conceptual),
and §9 (the invariants your backend may rely on).

---

## 9. Thread-safety

The model is **share-nothing-mutable**, encoded in the signatures:
`search(program: *const Program, scratch: *Scratch, …)` — the `Program` is immutable, the
`Scratch` is the only mutable state.

**Compile once, share the `Compiled`/`Program` across threads, give each thread its own
`Scratch`.** No locks, no atomics (the `\p{}` tables are comptime `const`).

```zig
// shared, read-only, across N threads:
var re = try gex.compileRuntime(gpa, pattern, &diag, .{});
defer re.deinit();

// per thread:
var sc = try re.initScratch(thread_gpa);
defer sc.deinit(thread_gpa);
_ = re.find(&sc, input);
```

Fine print (see [`architecture.md`](architecture.md) §11 for the full treatment):

- The built-in `Scratch`es are **not** thread-safe — one per thread, never pooled.
- `backtrack`'s heap `Scratch` **allocates during a search** (it grows a visited bitset)
  through *your* allocator — so per-thread Scratch is necessary but not sufficient if they
  share a non-thread-safe allocator. Fixes: per-thread allocator, a thread-safe allocator,
  a **buffer** `Scratch` (`initBuffer`, never allocates), or the `pikevm` backend (ditto).
  Default `auto` + heap `Scratch` is therefore *not* strictly zero-allocation while matching.
- If that mid-search allocation **fails**, `auto` falls back to the Pike VM and returns the
  same answer. Driving `backtrack` or the lazy `dfa` directly, their plain `search`/`isMatch`
  panic instead (the search API has no error channel): call `backtrack.reserve` first, or use
  `dfa.trySearch`/`dfa.tryIsMatch`, to get `error.OutOfMemory` back.

---

## 10. Gotchas & semantics

Read these before trusting edge cases (full list in [`architecture.md`](architecture.md) §8):

- **Leftmost-first (Perl/JS), not POSIX leftmost-longest.** `a|ab` on `"ab"` is `"a"`.
  All built-in backends agree bit-for-bit (the NFA backends share one compiler).
- **`$` is `\z`.** Without `(?m)`, `$` matches **only** end-of-input — *not* before a
  trailing `\n`. `abc$` does not match `"abc\n"` (JS/Go/RE2/Rust semantics). `\Z` == `\z`.
  (`$`/`\z`, `(?m)` line anchors, and `\b`/`\B` are all now **DFA-handled** — anchored-end `$`
  on both byte DFAs, non-prone `(?m)` + ASCII `\b` on the eager DFA, Unicode `\b` on the lazy
  DFA. Only `\X`, a *mixed* `$`, a *prone* `(?m)`/`\b`, and `\b`+`$`/`(?m)` stay on the Pike VM;
  `auto` routes it all.)
- **`\X` (grapheme cluster) is `backtrack`-only** — it matches one whole UAX #29 cluster
  and compiles to a variable-width instruction the breadth-first `pikevm`/`literal`
  can't run, so `auto` routes any `\X` pattern to the backtracker (forcing `pikevm`
  via `*With` on a `\X` pattern fails at build).
- **No backreferences / lookaround / atomic / recursion / `\Q…\E`** — a Thompson NFA
  can't express them; each is rejected at parse with a precise diagnostic code.
- **`{m,n}` expands, uncapped** — a huge counted repeat makes a large program (bounded by
  allocation failure or the comptime quota, never UB).
- **Invalid UTF-8 input** is *dead-on-invalid*: a malformed byte matches nothing (no
  `U+FFFD` substitution — `.` won't match it), and the unanchored scan resyncs one byte
  past it, so a match never spans a bad byte. (Pattern bytes must be valid UTF-8 or
  `scan` rejects them at compile time.)
- **`case_fold = .full`** expands 1→many foldings for literals (`(?i)ß` also matches
  `ss`, `ﬀ` matches `ff`); character classes use simple folding (a class matches one
  code point). `Script_Extensions` falls back to plain `Script` ranges.

---

## 11. Unicode syntax reference

Every Unicode-aware construct ezi_gex accepts, with each accepted spelling. The data behind it
comes from the pinned `ezi_code` (`v0.5.0`, **Unicode 18.0.0**). Some rules apply throughout:

- **Names are exact and case-sensitive.** UAX #44 loose matching is not applied, so `\p{Letter}`
  works but `\p{letter}`, `\p{LETTER}` and `\p{Script=latin}` are rejected with
  `unknown_property`.
- **`\P{…}` negates any property**, e.g. `\P{L}`, `\P{Script=Greek}`, `\PL`.
- **Everything works inside a class**, alone or combined: `[\p{L}\p{Nd}_]`, `[^\p{sc=Grek}\s]`.
- **Scripts always need a prefix.** `\p{Script=Greek}` / `\p{sc=Grek}` work, but a bare
  `\p{Greek}` does not. Note that `\p{Sc}` (no `=`) is the *Currency_Symbol* category, not a
  script.
- `unicode = false` in `Options` only narrows `\d` `\w` `\s` to ASCII. `\p{…}`, `.`, `\b` and `\X`
  stay Unicode.

<details>
<summary><b>Escapes and shorthand classes</b>: <code>\d</code> <code>\w</code> <code>\s</code> <code>\b</code> <code>\X</code> <code>.</code> <code>\u{…}</code> <code>(?i)</code></summary>

| Syntax | Equivalent spellings | Matches |
|---|---|---|
| `\d` | `\p{Nd}` · `\p{Decimal_Number}` · `[\p{Nd}]` | any decimal digit: `7`, `٣`, `७`, `７`. With `unicode = false`: `[0-9]` |
| `\D` | `\P{Nd}` · `\P{Decimal_Number}` · `[^\d]` | anything that is not a decimal digit |
| `\w` | `[\p{Alphabetic}\p{M}\p{Nd}\p{Pc}\u{200C}\u{200D}]` | a word character (Alphabetic ∪ Mark ∪ Nd ∪ Connector_Punctuation ∪ Join_Control). With `unicode = false`: `[0-9A-Za-z_]` |
| `\W` | `[^\w]` | anything that is not a word character |
| `\s` | `[\t\n\v\f\r\x20\x{85}\xA0\u{1680}\u{2000}-\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}]` | White_Space (25 code points). With `unicode = false`: `[\t\n\v\f\r\x20]` |
| `\S` | `[^\s]` | anything that is not White_Space |
| `\b` | none | a Unicode word boundary (a `\w` on exactly one side). Inside a class, `[\b]` is backspace (U+0008) |
| `\B` | none | not a word boundary |
| `\X` | none | one extended grapheme cluster (UAX #29, Unicode 18 rules): `e\u{0301}`, `👨‍👩‍👧`, `\u{094D}\u{0915}`. Runs on `backtrack`/`auto` only. Inside a class, `[\X]` is a literal `X` |
| `.` | `[^\n]` · with `(?s)`: any code point | any code point except `\n`. `(?s)` or `dot_matches_newline = true` includes `\n` |
| `\u{H…}` | `\x{H…}` · `\uHHHH` (exactly 4 hex digits) · the character itself | one code point by hex value, e.g. `\u{1F600}` = `\x{1F600}` = `😀`; `\u00E9` = `é`. Surrogates are rejected |
| `\xHH` | `\x{HH}` · `\u00HH` | a code point up to U+00FF (0–2 hex digits; a bare `\x` is U+0000) |
| `(?i)` | `Options.case_insensitive = true` · scoped `(?i:…)` | Unicode case folding: `(?i)ω` matches `Ω`, `(?i)k` matches `K` and U+212A KELVIN SIGN. `case_fold = .full` also folds literals 1→many (`(?i)ß` matches `ss`); classes always use simple folding. A negated property folds **before** negating (Rust/Perl): `(?i)\p{Lu}` matches `a`, `(?i)\P{Ll}` matches no cased letter |

**Not supported:** POSIX classes (`[[:alpha:]]` is rejected with `unsupported_posix_class`),
`\N{NAME}`, `\p{Any}` / `\p{ASCII}` / `\p{Assigned}`, and binary properties outside the
table below (`White_Space`, `Emoji`, `Block=…`, `Age=…`, …). For those, use the shorthand or write
the class out.

</details>

<details>
<summary><b>General categories</b>: 8 groups and 30 categories, e.g. <code>\p{L}</code> <code>\p{Lu}</code> <code>\pN</code></summary>

The short and long names are interchangeable, and one-letter names also take the brace-free form
`\pL`. Every row below also works negated (`\P{…}` / `\PL`).

**Groups**

| Short | Long | All spellings | Covers |
|---|---|---|---|
| `L` | `Letter` | `\p{L}` · `\pL` · `\p{Letter}` | Lu Ll Lt Lm Lo |
| `LC` | `Cased_Letter` | `\p{LC}` · `\p{Cased_Letter}` | Lu Ll Lt |
| `M` | `Mark` | `\p{M}` · `\pM` · `\p{Mark}` | Mn Mc Me |
| `N` | `Number` | `\p{N}` · `\pN` · `\p{Number}` | Nd Nl No |
| `P` | `Punctuation` | `\p{P}` · `\pP` · `\p{Punctuation}` | Pc Pd Ps Pe Pi Pf Po |
| `S` | `Symbol` | `\p{S}` · `\pS` · `\p{Symbol}` | Sm Sc Sk So |
| `Z` | `Separator` | `\p{Z}` · `\pZ` · `\p{Separator}` | Zs Zl Zp |
| `C` | `Other` | `\p{C}` · `\pC` · `\p{Other}` | Cc Cf Cs Co Cn |

**Single categories**

| Short | Long | All spellings | Examples |
|---|---|---|---|
| `Lu` | `Uppercase_Letter` | `\p{Lu}` · `\p{Uppercase_Letter}` | `A` `Ж` `Ω` |
| `Ll` | `Lowercase_Letter` | `\p{Ll}` · `\p{Lowercase_Letter}` | `a` `ж` `ω` |
| `Lt` | `Titlecase_Letter` | `\p{Lt}` · `\p{Titlecase_Letter}` | `ǅ` `ᾈ` |
| `Lm` | `Modifier_Letter` | `\p{Lm}` · `\p{Modifier_Letter}` | `ʰ` `ー` |
| `Lo` | `Other_Letter` | `\p{Lo}` · `\p{Other_Letter}` | `中` `א` `ก` |
| `Mn` | `Nonspacing_Mark` | `\p{Mn}` · `\p{Nonspacing_Mark}` | U+0301 (◌́) |
| `Mc` | `Spacing_Mark` | `\p{Mc}` · `\p{Spacing_Mark}` | U+0903 (◌ः) |
| `Me` | `Enclosing_Mark` | `\p{Me}` · `\p{Enclosing_Mark}` | U+20DD (◌⃝) |
| `Nd` | `Decimal_Number` | `\p{Nd}` · `\p{Decimal_Number}` | `7` `٣` `७` |
| `Nl` | `Letter_Number` | `\p{Nl}` · `\p{Letter_Number}` | `Ⅻ` `〇` |
| `No` | `Other_Number` | `\p{No}` · `\p{Other_Number}` | `½` `²` `①` |
| `Pc` | `Connector_Punctuation` | `\p{Pc}` · `\p{Connector_Punctuation}` | `_` `‿` |
| `Pd` | `Dash_Punctuation` | `\p{Pd}` · `\p{Dash_Punctuation}` | `-` `–` `—` |
| `Ps` | `Open_Punctuation` | `\p{Ps}` · `\p{Open_Punctuation}` | `(` `[` `「` |
| `Pe` | `Close_Punctuation` | `\p{Pe}` · `\p{Close_Punctuation}` | `)` `]` `」` |
| `Pi` | `Initial_Punctuation` | `\p{Pi}` · `\p{Initial_Punctuation}` | `«` `“` |
| `Pf` | `Final_Punctuation` | `\p{Pf}` · `\p{Final_Punctuation}` | `»` `”` |
| `Po` | `Other_Punctuation` | `\p{Po}` · `\p{Other_Punctuation}` | `!` `,` `。` |
| `Sm` | `Math_Symbol` | `\p{Sm}` · `\p{Math_Symbol}` | `+` `=` `∑` |
| `Sc` | `Currency_Symbol` | `\p{Sc}` · `\p{Currency_Symbol}` | `$` `€` `₹` |
| `Sk` | `Modifier_Symbol` | `\p{Sk}` · `\p{Modifier_Symbol}` | `^` `` ` `` `˘` |
| `So` | `Other_Symbol` | `\p{So}` · `\p{Other_Symbol}` | `©` `°` `😀` |
| `Zs` | `Space_Separator` | `\p{Zs}` · `\p{Space_Separator}` | U+0020, U+00A0, U+3000 |
| `Zl` | `Line_Separator` | `\p{Zl}` · `\p{Line_Separator}` | U+2028 |
| `Zp` | `Paragraph_Separator` | `\p{Zp}` · `\p{Paragraph_Separator}` | U+2029 |
| `Cc` | `Control` | `\p{Cc}` · `\p{Control}` | U+0000–U+001F, U+007F–U+009F |
| `Cf` | `Format` | `\p{Cf}` · `\p{Format}` | U+200B, U+200D, U+FEFF |
| `Cs` | `Surrogate` | `\p{Cs}` · `\p{Surrogate}` | U+D800–U+DFFF (never in valid UTF-8) |
| `Co` | `Private_Use` | `\p{Co}` · `\p{Private_Use}` | U+E000–U+F8FF, planes 15–16 |
| `Cn` | `Unassigned` | `\p{Cn}` · `\p{Unassigned}` | any code point not assigned in Unicode 18.0 |

</details>

<details>
<summary><b>Derived core properties</b>: 19 binary properties, e.g. <code>\p{Alphabetic}</code> <code>\p{ID_Start}</code></summary>

Only the long names below are accepted; the UCD short aliases (`Alpha`, `Lower`, `IDS`, …) are
not. Each also works negated (`\P{Alphabetic}`).

| Syntax | Matches |
|---|---|
| `\p{Math}` | mathematical symbols and letters (`+`, `∑`, `𝐀`) |
| `\p{Alphabetic}` | letters, letter numbers and alphabetic marks |
| `\p{Lowercase}` | lowercase characters (a superset of `Ll`) |
| `\p{Uppercase}` | uppercase characters (a superset of `Lu`) |
| `\p{Cased}` | characters with case (`Lowercase` ∪ `Uppercase` ∪ `Lt`) |
| `\p{Case_Ignorable}` | characters ignored when determining case context (e.g. `'`, U+0301) |
| `\p{Changes_When_Lowercased}` | changes under lowercase mapping |
| `\p{Changes_When_Uppercased}` | changes under uppercase mapping |
| `\p{Changes_When_Titlecased}` | changes under titlecase mapping |
| `\p{Changes_When_Casefolded}` | changes under case folding |
| `\p{Changes_When_Casemapped}` | changes under any case mapping |
| `\p{ID_Start}` | can start an identifier (UAX #31) |
| `\p{ID_Continue}` | can continue an identifier (UAX #31) |
| `\p{XID_Start}` | `ID_Start`, closed under NFKC |
| `\p{XID_Continue}` | `ID_Continue`, closed under NFKC |
| `\p{Default_Ignorable_Code_Point}` | invisible by default (e.g. U+200B, U+00AD, variation selectors) |
| `\p{Grapheme_Extend}` | extends a grapheme cluster (combining marks, ZWNJ, …) |
| `\p{Grapheme_Base}` | can be the base of a grapheme cluster |
| `\p{Grapheme_Link}` | virama-like characters that link clusters (e.g. U+094D) |

</details>

<details>
<summary><b>Scripts</b>: all 179 Unicode 18.0 scripts, via <code>Script=</code> / <code>sc=</code> / <code>Script_Extensions=</code> / <code>scx=</code></summary>

Each script can be named by its long name or its 4-letter ISO 15924 code, after any of four
prefixes. For Greek, these are all the same:

| Prefix | Long name | Code |
|---|---|---|
| `Script=` | `\p{Script=Greek}` | `\p{Script=Grek}` |
| `sc=` | `\p{sc=Greek}` | `\p{sc=Grek}` |
| `Script_Extensions=` | `\p{Script_Extensions=Greek}` | `\p{Script_Extensions=Grek}` |
| `scx=` | `\p{scx=Greek}` | `\p{scx=Grek}` |

`Script_Extensions=` / `scx=` are accepted, but they currently match the same ranges as `Script=`
(see [Gotchas](#10-gotchas--semantics)). Long names use underscores exactly as listed
(`Old_Italic`, not `Old Italic` or `OldItalic`). The "Short spellings" column shows the `sc=` forms;
the `Script=`, `Script_Extensions=` and `scx=` prefixes take the same names.

| Script | Long name | Code | Short spellings | Note |
|---|---|---|---|---|
| Adlam | `Adlam` | `Adlm` | `sc=Adlam` · `sc=Adlm` |  |
| Ahom | `Ahom` | `Ahom` | `sc=Ahom` |  |
| Anatolian Hieroglyphs | `Anatolian_Hieroglyphs` | `Hluw` | `sc=Anatolian_Hieroglyphs` · `sc=Hluw` |  |
| Arabic | `Arabic` | `Arab` | `sc=Arabic` · `sc=Arab` |  |
| Armenian | `Armenian` | `Armn` | `sc=Armenian` · `sc=Armn` |  |
| Avestan | `Avestan` | `Avst` | `sc=Avestan` · `sc=Avst` |  |
| Balinese | `Balinese` | `Bali` | `sc=Balinese` · `sc=Bali` |  |
| Bamum | `Bamum` | `Bamu` | `sc=Bamum` · `sc=Bamu` |  |
| Bassa Vah | `Bassa_Vah` | `Bass` | `sc=Bassa_Vah` · `sc=Bass` |  |
| Batak | `Batak` | `Batk` | `sc=Batak` · `sc=Batk` |  |
| Bengali | `Bengali` | `Beng` | `sc=Bengali` · `sc=Beng` |  |
| Beria Erfe | `Beria_Erfe` | `Berf` | `sc=Beria_Erfe` · `sc=Berf` |  |
| Bhaiksuki | `Bhaiksuki` | `Bhks` | `sc=Bhaiksuki` · `sc=Bhks` |  |
| Bopomofo | `Bopomofo` | `Bopo` | `sc=Bopomofo` · `sc=Bopo` |  |
| Brahmi | `Brahmi` | `Brah` | `sc=Brahmi` · `sc=Brah` |  |
| Braille | `Braille` | `Brai` | `sc=Braille` · `sc=Brai` |  |
| Buginese | `Buginese` | `Bugi` | `sc=Buginese` · `sc=Bugi` |  |
| Buhid | `Buhid` | `Buhd` | `sc=Buhid` · `sc=Buhd` |  |
| Canadian Aboriginal | `Canadian_Aboriginal` | `Cans` | `sc=Canadian_Aboriginal` · `sc=Cans` |  |
| Carian | `Carian` | `Cari` | `sc=Carian` · `sc=Cari` |  |
| Caucasian Albanian | `Caucasian_Albanian` | `Aghb` | `sc=Caucasian_Albanian` · `sc=Aghb` |  |
| Chakma | `Chakma` | `Cakm` | `sc=Chakma` · `sc=Cakm` |  |
| Cham | `Cham` | `Cham` | `sc=Cham` |  |
| Cherokee | `Cherokee` | `Cher` | `sc=Cherokee` · `sc=Cher` |  |
| Chorasmian | `Chorasmian` | `Chrs` | `sc=Chorasmian` · `sc=Chrs` |  |
| Common | `Common` | `Zyyy` | `sc=Common` · `sc=Zyyy` | characters shared by several scripts (digits, punctuation, …) |
| Coptic | `Coptic` | `Copt` | `sc=Coptic` · `sc=Copt` |  |
| Cuneiform | `Cuneiform` | `Xsux` | `sc=Cuneiform` · `sc=Xsux` |  |
| Cypriot | `Cypriot` | `Cprt` | `sc=Cypriot` · `sc=Cprt` |  |
| Cypro Minoan | `Cypro_Minoan` | `Cpmn` | `sc=Cypro_Minoan` · `sc=Cpmn` |  |
| Cyrillic | `Cyrillic` | `Cyrl` | `sc=Cyrillic` · `sc=Cyrl` |  |
| Deseret | `Deseret` | `Dsrt` | `sc=Deseret` · `sc=Dsrt` |  |
| Devanagari | `Devanagari` | `Deva` | `sc=Devanagari` · `sc=Deva` |  |
| Dives Akuru | `Dives_Akuru` | `Diak` | `sc=Dives_Akuru` · `sc=Diak` |  |
| Dogra | `Dogra` | `Dogr` | `sc=Dogra` · `sc=Dogr` |  |
| Duployan | `Duployan` | `Dupl` | `sc=Duployan` · `sc=Dupl` |  |
| Egyptian Hieroglyphs | `Egyptian_Hieroglyphs` | `Egyp` | `sc=Egyptian_Hieroglyphs` · `sc=Egyp` |  |
| Elbasan | `Elbasan` | `Elba` | `sc=Elbasan` · `sc=Elba` |  |
| Elymaic | `Elymaic` | `Elym` | `sc=Elymaic` · `sc=Elym` |  |
| Ethiopic | `Ethiopic` | `Ethi` | `sc=Ethiopic` · `sc=Ethi` |  |
| Garay | `Garay` | `Gara` | `sc=Garay` · `sc=Gara` |  |
| Georgian | `Georgian` | `Geor` | `sc=Georgian` · `sc=Geor` |  |
| Glagolitic | `Glagolitic` | `Glag` | `sc=Glagolitic` · `sc=Glag` |  |
| Gothic | `Gothic` | `Goth` | `sc=Gothic` · `sc=Goth` |  |
| Grantha | `Grantha` | `Gran` | `sc=Grantha` · `sc=Gran` |  |
| Greek | `Greek` | `Grek` | `sc=Greek` · `sc=Grek` |  |
| Gujarati | `Gujarati` | `Gujr` | `sc=Gujarati` · `sc=Gujr` |  |
| Gunjala Gondi | `Gunjala_Gondi` | `Gong` | `sc=Gunjala_Gondi` · `sc=Gong` |  |
| Gurmukhi | `Gurmukhi` | `Guru` | `sc=Gurmukhi` · `sc=Guru` |  |
| Gurung Khema | `Gurung_Khema` | `Gukh` | `sc=Gurung_Khema` · `sc=Gukh` |  |
| Han | `Han` | `Hani` | `sc=Han` · `sc=Hani` |  |
| Hangul | `Hangul` | `Hang` | `sc=Hangul` · `sc=Hang` |  |
| Hanifi Rohingya | `Hanifi_Rohingya` | `Rohg` | `sc=Hanifi_Rohingya` · `sc=Rohg` |  |
| Hanunoo | `Hanunoo` | `Hano` | `sc=Hanunoo` · `sc=Hano` |  |
| Hatran | `Hatran` | `Hatr` | `sc=Hatran` · `sc=Hatr` |  |
| Hebrew | `Hebrew` | `Hebr` | `sc=Hebrew` · `sc=Hebr` |  |
| Hiragana | `Hiragana` | `Hira` | `sc=Hiragana` · `sc=Hira` |  |
| Imperial Aramaic | `Imperial_Aramaic` | `Armi` | `sc=Imperial_Aramaic` · `sc=Armi` |  |
| Inherited | `Inherited` | `Zinh` | `sc=Inherited` · `sc=Zinh` | combining marks that inherit their base's script |
| Inscriptional Pahlavi | `Inscriptional_Pahlavi` | `Phli` | `sc=Inscriptional_Pahlavi` · `sc=Phli` |  |
| Inscriptional Parthian | `Inscriptional_Parthian` | `Prti` | `sc=Inscriptional_Parthian` · `sc=Prti` |  |
| Javanese | `Javanese` | `Java` | `sc=Javanese` · `sc=Java` |  |
| Jurchen | `Jurchen` | `Jurc` | `sc=Jurchen` · `sc=Jurc` | **new in Unicode 18.0** |
| Kaithi | `Kaithi` | `Kthi` | `sc=Kaithi` · `sc=Kthi` |  |
| Kannada | `Kannada` | `Knda` | `sc=Kannada` · `sc=Knda` |  |
| Katakana | `Katakana` | `Kana` | `sc=Katakana` · `sc=Kana` |  |
| Katakana Or Hiragana | `Katakana_Or_Hiragana` | `Hrkt` | `sc=Katakana_Or_Hiragana` · `sc=Hrkt` | alias value only: no code point has this Script (use `Hira` / `Kana`) |
| Kawi | `Kawi` | `Kawi` | `sc=Kawi` |  |
| Kayah Li | `Kayah_Li` | `Kali` | `sc=Kayah_Li` · `sc=Kali` |  |
| Kharoshthi | `Kharoshthi` | `Khar` | `sc=Kharoshthi` · `sc=Khar` |  |
| Khitan Small Script | `Khitan_Small_Script` | `Kits` | `sc=Khitan_Small_Script` · `sc=Kits` |  |
| Khmer | `Khmer` | `Khmr` | `sc=Khmer` · `sc=Khmr` |  |
| Khojki | `Khojki` | `Khoj` | `sc=Khojki` · `sc=Khoj` |  |
| Khudawadi | `Khudawadi` | `Sind` | `sc=Khudawadi` · `sc=Sind` |  |
| Kirat Rai | `Kirat_Rai` | `Krai` | `sc=Kirat_Rai` · `sc=Krai` |  |
| Lao | `Lao` | `Laoo` | `sc=Lao` · `sc=Laoo` |  |
| Latin | `Latin` | `Latn` | `sc=Latin` · `sc=Latn` |  |
| Lepcha | `Lepcha` | `Lepc` | `sc=Lepcha` · `sc=Lepc` |  |
| Limbu | `Limbu` | `Limb` | `sc=Limbu` · `sc=Limb` |  |
| Linear A | `Linear_A` | `Lina` | `sc=Linear_A` · `sc=Lina` |  |
| Linear B | `Linear_B` | `Linb` | `sc=Linear_B` · `sc=Linb` |  |
| Lisu | `Lisu` | `Lisu` | `sc=Lisu` |  |
| Lycian | `Lycian` | `Lyci` | `sc=Lycian` · `sc=Lyci` |  |
| Lydian | `Lydian` | `Lydi` | `sc=Lydian` · `sc=Lydi` |  |
| Mahajani | `Mahajani` | `Mahj` | `sc=Mahajani` · `sc=Mahj` |  |
| Makasar | `Makasar` | `Maka` | `sc=Makasar` · `sc=Maka` |  |
| Malayalam | `Malayalam` | `Mlym` | `sc=Malayalam` · `sc=Mlym` |  |
| Mandaic | `Mandaic` | `Mand` | `sc=Mandaic` · `sc=Mand` |  |
| Manichaean | `Manichaean` | `Mani` | `sc=Manichaean` · `sc=Mani` |  |
| Marchen | `Marchen` | `Marc` | `sc=Marchen` · `sc=Marc` |  |
| Masaram Gondi | `Masaram_Gondi` | `Gonm` | `sc=Masaram_Gondi` · `sc=Gonm` |  |
| Medefaidrin | `Medefaidrin` | `Medf` | `sc=Medefaidrin` · `sc=Medf` |  |
| Meetei Mayek | `Meetei_Mayek` | `Mtei` | `sc=Meetei_Mayek` · `sc=Mtei` |  |
| Mende Kikakui | `Mende_Kikakui` | `Mend` | `sc=Mende_Kikakui` · `sc=Mend` |  |
| Meroitic Cursive | `Meroitic_Cursive` | `Merc` | `sc=Meroitic_Cursive` · `sc=Merc` |  |
| Meroitic Hieroglyphs | `Meroitic_Hieroglyphs` | `Mero` | `sc=Meroitic_Hieroglyphs` · `sc=Mero` |  |
| Miao | `Miao` | `Plrd` | `sc=Miao` · `sc=Plrd` |  |
| Modi | `Modi` | `Modi` | `sc=Modi` |  |
| Mongolian | `Mongolian` | `Mong` | `sc=Mongolian` · `sc=Mong` |  |
| Mro | `Mro` | `Mroo` | `sc=Mro` · `sc=Mroo` |  |
| Multani | `Multani` | `Mult` | `sc=Multani` · `sc=Mult` |  |
| Myanmar | `Myanmar` | `Mymr` | `sc=Myanmar` · `sc=Mymr` |  |
| Nabataean | `Nabataean` | `Nbat` | `sc=Nabataean` · `sc=Nbat` |  |
| Nag Mundari | `Nag_Mundari` | `Nagm` | `sc=Nag_Mundari` · `sc=Nagm` |  |
| Nandinagari | `Nandinagari` | `Nand` | `sc=Nandinagari` · `sc=Nand` |  |
| New Tai Lue | `New_Tai_Lue` | `Talu` | `sc=New_Tai_Lue` · `sc=Talu` |  |
| Newa | `Newa` | `Newa` | `sc=Newa` |  |
| Nko | `Nko` | `Nkoo` | `sc=Nko` · `sc=Nkoo` |  |
| Nushu | `Nushu` | `Nshu` | `sc=Nushu` · `sc=Nshu` |  |
| Nyiakeng Puachue Hmong | `Nyiakeng_Puachue_Hmong` | `Hmnp` | `sc=Nyiakeng_Puachue_Hmong` · `sc=Hmnp` |  |
| Ogham | `Ogham` | `Ogam` | `sc=Ogham` · `sc=Ogam` |  |
| Ol Chiki | `Ol_Chiki` | `Olck` | `sc=Ol_Chiki` · `sc=Olck` |  |
| Ol Onal | `Ol_Onal` | `Onao` | `sc=Ol_Onal` · `sc=Onao` |  |
| Old Hungarian | `Old_Hungarian` | `Hung` | `sc=Old_Hungarian` · `sc=Hung` |  |
| Old Italic | `Old_Italic` | `Ital` | `sc=Old_Italic` · `sc=Ital` |  |
| Old North Arabian | `Old_North_Arabian` | `Narb` | `sc=Old_North_Arabian` · `sc=Narb` |  |
| Old Permic | `Old_Permic` | `Perm` | `sc=Old_Permic` · `sc=Perm` |  |
| Old Persian | `Old_Persian` | `Xpeo` | `sc=Old_Persian` · `sc=Xpeo` |  |
| Old Sogdian | `Old_Sogdian` | `Sogo` | `sc=Old_Sogdian` · `sc=Sogo` |  |
| Old South Arabian | `Old_South_Arabian` | `Sarb` | `sc=Old_South_Arabian` · `sc=Sarb` |  |
| Old Turkic | `Old_Turkic` | `Orkh` | `sc=Old_Turkic` · `sc=Orkh` |  |
| Old Uyghur | `Old_Uyghur` | `Ougr` | `sc=Old_Uyghur` · `sc=Ougr` |  |
| Oriya | `Oriya` | `Orya` | `sc=Oriya` · `sc=Orya` |  |
| Osage | `Osage` | `Osge` | `sc=Osage` · `sc=Osge` |  |
| Osmanya | `Osmanya` | `Osma` | `sc=Osmanya` · `sc=Osma` |  |
| Pahawh Hmong | `Pahawh_Hmong` | `Hmng` | `sc=Pahawh_Hmong` · `sc=Hmng` |  |
| Palmyrene | `Palmyrene` | `Palm` | `sc=Palmyrene` · `sc=Palm` |  |
| Pau Cin Hau | `Pau_Cin_Hau` | `Pauc` | `sc=Pau_Cin_Hau` · `sc=Pauc` |  |
| Phags Pa | `Phags_Pa` | `Phag` | `sc=Phags_Pa` · `sc=Phag` |  |
| Phoenician | `Phoenician` | `Phnx` | `sc=Phoenician` · `sc=Phnx` |  |
| Proto Cuneiform | `Proto_Cuneiform` | `Pcun` | `sc=Proto_Cuneiform` · `sc=Pcun` | **new in Unicode 18.0** |
| Psalter Pahlavi | `Psalter_Pahlavi` | `Phlp` | `sc=Psalter_Pahlavi` · `sc=Phlp` |  |
| Rejang | `Rejang` | `Rjng` | `sc=Rejang` · `sc=Rjng` |  |
| Runic | `Runic` | `Runr` | `sc=Runic` · `sc=Runr` |  |
| Samaritan | `Samaritan` | `Samr` | `sc=Samaritan` · `sc=Samr` |  |
| Saurashtra | `Saurashtra` | `Saur` | `sc=Saurashtra` · `sc=Saur` |  |
| Seal | `Seal` | `Seal` | `sc=Seal` | **new in Unicode 18.0** |
| Sharada | `Sharada` | `Shrd` | `sc=Sharada` · `sc=Shrd` |  |
| Shavian | `Shavian` | `Shaw` | `sc=Shavian` · `sc=Shaw` |  |
| Siddham | `Siddham` | `Sidd` | `sc=Siddham` · `sc=Sidd` |  |
| Sidetic | `Sidetic` | `Sidt` | `sc=Sidetic` · `sc=Sidt` |  |
| SignWriting | `SignWriting` | `Sgnw` | `sc=SignWriting` · `sc=Sgnw` |  |
| Sinhala | `Sinhala` | `Sinh` | `sc=Sinhala` · `sc=Sinh` |  |
| Sogdian | `Sogdian` | `Sogd` | `sc=Sogdian` · `sc=Sogd` |  |
| Sora Sompeng | `Sora_Sompeng` | `Sora` | `sc=Sora_Sompeng` · `sc=Sora` |  |
| Soyombo | `Soyombo` | `Soyo` | `sc=Soyombo` · `sc=Soyo` |  |
| Sundanese | `Sundanese` | `Sund` | `sc=Sundanese` · `sc=Sund` |  |
| Sunuwar | `Sunuwar` | `Sunu` | `sc=Sunuwar` · `sc=Sunu` |  |
| Syloti Nagri | `Syloti_Nagri` | `Sylo` | `sc=Syloti_Nagri` · `sc=Sylo` |  |
| Syriac | `Syriac` | `Syrc` | `sc=Syriac` · `sc=Syrc` |  |
| Tagalog | `Tagalog` | `Tglg` | `sc=Tagalog` · `sc=Tglg` |  |
| Tagbanwa | `Tagbanwa` | `Tagb` | `sc=Tagbanwa` · `sc=Tagb` |  |
| Tai Le | `Tai_Le` | `Tale` | `sc=Tai_Le` · `sc=Tale` |  |
| Tai Tham | `Tai_Tham` | `Lana` | `sc=Tai_Tham` · `sc=Lana` |  |
| Tai Viet | `Tai_Viet` | `Tavt` | `sc=Tai_Viet` · `sc=Tavt` |  |
| Tai Yo | `Tai_Yo` | `Tayo` | `sc=Tai_Yo` · `sc=Tayo` |  |
| Takri | `Takri` | `Takr` | `sc=Takri` · `sc=Takr` |  |
| Tamil | `Tamil` | `Taml` | `sc=Tamil` · `sc=Taml` |  |
| Tangsa | `Tangsa` | `Tnsa` | `sc=Tangsa` · `sc=Tnsa` |  |
| Tangut | `Tangut` | `Tang` | `sc=Tangut` · `sc=Tang` |  |
| Telugu | `Telugu` | `Telu` | `sc=Telugu` · `sc=Telu` |  |
| Thaana | `Thaana` | `Thaa` | `sc=Thaana` · `sc=Thaa` |  |
| Thai | `Thai` | `Thai` | `sc=Thai` |  |
| Tibetan | `Tibetan` | `Tibt` | `sc=Tibetan` · `sc=Tibt` |  |
| Tifinagh | `Tifinagh` | `Tfng` | `sc=Tifinagh` · `sc=Tfng` |  |
| Tirhuta | `Tirhuta` | `Tirh` | `sc=Tirhuta` · `sc=Tirh` |  |
| Todhri | `Todhri` | `Todr` | `sc=Todhri` · `sc=Todr` |  |
| Tolong Siki | `Tolong_Siki` | `Tols` | `sc=Tolong_Siki` · `sc=Tols` |  |
| Toto | `Toto` | `Toto` | `sc=Toto` |  |
| Tulu Tigalari | `Tulu_Tigalari` | `Tutg` | `sc=Tulu_Tigalari` · `sc=Tutg` |  |
| Ugaritic | `Ugaritic` | `Ugar` | `sc=Ugaritic` · `sc=Ugar` |  |
| Unknown | `Unknown` | `Zzzz` | `sc=Unknown` · `sc=Zzzz` | unassigned code points |
| Vai | `Vai` | `Vaii` | `sc=Vai` · `sc=Vaii` |  |
| Vithkuqi | `Vithkuqi` | `Vith` | `sc=Vithkuqi` · `sc=Vith` |  |
| Wancho | `Wancho` | `Wcho` | `sc=Wancho` · `sc=Wcho` |  |
| Warang Citi | `Warang_Citi` | `Wara` | `sc=Warang_Citi` · `sc=Wara` |  |
| Yezidi | `Yezidi` | `Yezi` | `sc=Yezidi` · `sc=Yezi` |  |
| Yi | `Yi` | `Yiii` | `sc=Yi` · `sc=Yiii` |  |
| Zanabazar Square | `Zanabazar_Square` | `Zanb` | `sc=Zanabazar_Square` · `sc=Zanb` |  |

</details>

---

### See also

- [`architecture.md`](architecture.md) — design, the contract's fine print, performance roadmap.
- [`../README.md`](../README.md) — the one-screen overview.
- `src/core/hir.zig`, `src/engine/backend.zig`, `src/engine/regex.zig` — the same guidance
  inline, as doc comments, on the actual types.
- `src/engine/backends/literal.zig` — the production version of [§8](#8-writing-your-own-backend)'s example.
