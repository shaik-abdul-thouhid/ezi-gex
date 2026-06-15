# ezi_gex — usage guide (hands-on)

A copy-paste tutorial for **using** ezi_gex, end to end:

1. [Quick start](#1-quick-start) — match something in 30 seconds.
2. [The pipeline at a glance](#2-the-pipeline-at-a-glance) — `pattern → AST → HIR → Program → match`.
3. [Front-door recipes](#3-front-door-recipes) — `isMatch` / `find` / captures / `findAll` / `split` / `replaceAll`.
4. [Comptime & no-allocator usage](#4-comptime--no-allocator-usage).
5. [Using the stages from lexing up](#5-using-the-stages-from-lexing-up) — drive the scanner, HIR, and a backend by hand.
6. [Reading the HIR](#6-reading-the-hir) — what the resolved IR looks like, with concrete output.
7. [The `Analysis` prefilter facts](#7-the-analysis-prefilter-facts).
8. [Writing your own backend](#8-writing-your-own-backend) — a complete, runnable example, built up step by step.
9. [Thread-safety](#9-thread-safety).
10. [Gotchas](#10-gotchas--semantics).

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

// The caller OWNS the per-search scratch and makes it off the regex's Scratch type.
var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
defer sc.deinit(gpa);

std.debug.print("{}\n", .{re.isMatch(&sc, "abc123")});          // true
if (re.find(&sc, "abc123")) |m|
    std.debug.print("{s}\n", .{m.slice("abc123")});             // 123
```

Two things to internalize, because they recur everywhere:

- **`re` is immutable and shareable; `sc` is the mutable per-search state.** You build
  `sc` *directly* off `@TypeOf(re).Scratch` (not through a method on `re`) and pass
  `&sc` to every call. One `sc` per thread (see [§9](#9-thread-safety)).
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
var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
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
var ssc = try @TypeOf(sep).Scratch.init(gpa, &sep.program);
defer ssc.deinit(gpa);

var parts = sep.split(&ssc, "the  quick fox");
while (parts.next()) |p| std.debug.print("[{s}]", .{p}); // [the][quick][fox]
```

### replaceAll (with a `$`-template)

`replaceAll` writes to any `std.Io.Writer`. The template references captures: `$0`/`$1`/…
by number, `${name}` by name (`${0}`/`${12}` to disambiguate), and `$$` for a literal `$`.

```zig
var re = try gex.compileRuntime(gpa, "(\\w+)@(\\w+)", &diag, .{});
defer re.deinit();
var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
defer sc.deinit(gpa);
const slots = try gpa.alloc(?usize, re.slotCount());
defer gpa.free(slots);

var buf: [128]u8 = undefined;
var w = std.Io.Writer.fixed(&buf);
try re.replaceAll(&sc, "from a@b to c@d", "$2.$1", slots, &w);
std.debug.print("{s}\n", .{w.buffered()});   // from b.a to d.c
```

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
> with `$`/`(?m)` (those route to the code-point engines / the lazy DFA). It is **bounded**: a
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
> it; use `auto`/`pikevm`). It runs `\A`/`^` (`text_start`), anchored-end `$`/`\z`, and
> **Unicode `\b`/`\B`** (via the *decode-hybrid* — it decodes the adjacent code points only at
> boundary positions), and only at runtime (no `compileComptimeWith(dfa, …)`, because its cache
> mutates while matching). It declines `\X` and `(?m)` line anchors (the eager DFA covers those).
> Through `auto` it is the arm reached when the eager `edfa` overflows its `max_states` bound, or
> for **Unicode** `\b` on non-ASCII input; you rarely pin it. When you *do* pin it, its
> determinization cache is bounded by a `ScratchOptions`: plain `Scratch.init` uses the default
> (`max_bytes = 1 MiB`, `on_full = .reset` — clear the cache and continue), and
> `Scratch.initOptions(gpa, &re.program, .{ .max_bytes = …, .on_full = … })` overrides it
> (`on_full`: `.reset` / `.give_up` (fail the search; `auto` then routes to the NFA) / `.grow`).
> Only the lazy `dfa` has a growable cache; every other backend's `Scratch.init` takes no options.

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

// strategy tier — results-invariant: flipping any field changes only speed/memory,
// never which text matches.
//   byte_engine: .auto (default) ≡ .enabled → `auto` builds the byte DFA and uses it for
//                isMatch/find on an eligible pattern (most patterns — incl. $/\z, ASCII \b,
//                and non-prone (?m); only \X, a mixed $, a prone (?m)/\b stay on the Pike VM).
//                It PREFERS the eager DFA (a frozen table, O(n) find on every pattern),
//                falling back to the lazy DFA when the eager table overflows its state bound
//                (or for Unicode \b on non-ASCII input); captures come from `onepass` or the
//                Pike VM anchored at the DFA span, so the result is identical, just 5–10×
//                faster on a class scan (Rust parity). .disabled = compact NFA-only (minimal
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
> (`Sherlock`, `Sherlock Holmes`) is scanned by a portable two-byte **`memmem`**
> (`engine/memmem.zig`): probe the two *rarest* needle bytes, AND their `@Vector` equality masks
> across a 16/32-byte chunk, and verify only where both coincide — far fewer candidates than a
> one-byte memchr on a common lead byte. It is **fully portable** (SSE2 `pcmpeqb`/NEON via
> `@Vector`, no arch asm), so it runs everywhere; on Sherlock it edges out Rust (~41 GiB/s). A
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

The backend's `Scratch` exposes a buffer convention (`Buf` / `bufferLen` / `initBuffer`)
so you can back the scratch with a stack/`ro_data` array instead of the heap:

```zig
const re = comptime gex.compileComptime("[a-z]+\\d+", .{});
const Scratch = @TypeOf(re).Scratch;

var buf: [Scratch.bufferLen(&re.program)]Scratch.Buf = undefined; // exact size, no heap
var sc = try Scratch.initBuffer(&buf, &re.program);
_ = re.find(&sc, "??abc12!!").?.slice("??abc12!!");               // "abc12"
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
```

A couple more, illustrating soundness:

```zig
// Top-level alternation: nothing is unconditionally required.
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
var sc = try @TypeOf(re).Scratch.init(gpa, &re.program);
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
var sc = try @TypeOf(re).Scratch.init(thread_gpa, &re.program);
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

### See also

- [`architecture.md`](architecture.md) — design, the contract's fine print, performance roadmap.
- [`../README.md`](../README.md) — the one-screen overview.
- `src/core/hir.zig`, `src/engine/backend.zig`, `src/engine/regex.zig` — the same guidance
  inline, as doc comments, on the actual types.
- `src/engine/backends/literal.zig` — the production version of [§8](#8-writing-your-own-backend)'s example.
