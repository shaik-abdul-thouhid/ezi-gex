# ezi_gex — architecture & backend guide

This is the document for two readers:

1. Someone who wants to **understand how ezi_gex works** end to end.
2. Someone who wants to **write their own backend** — a matcher tuned to their
   needs — and plug it into the same front door.

If you only want to *use* the library, the [README](../README.md) is enough, and
[`usage-guide.md`](usage-guide.md) is its hands-on companion — copy-paste recipes for
every op, the pipeline driven from lexing, and a runnable, step-by-step "write your own
backend" walkthrough. This document goes a layer down: the *why* behind that *how*.

---

## 1. The shape: fixed frontend, pluggable backends

```
            ┌──────────── FIXED FRONTEND (core/, library-owned) ────────────┐
 pattern ─▶ scanner ─▶ AST ─▶ hir.build(opts) ─▶ Hir + Analysis             │
            └─────────────────────────────────────────────────────┬─────────┘
                                                                  │  ← the contract
        ┌──────────────── PLUGGABLE BACKENDS (engine/) ───────────┼─────────────────┐
        │  a Backend = a comptime `type` satisfying engine/backend.zig              │
        │     literal     pikevm     backtrack     auto(dispatcher)     <yours>     │
        │     each: build(Hir)→Program · Scratch · isMatch / search / searchCaptures│
        └───────────────────────────────────────────────────────────┬───────────────┘
                                                                    ▼
              regex.compileRuntime/Comptime → Compiled(Backend)
              re.find / captures / replaceAll → Engine(Backend).<op>(program, scratch, …)
```

- **Fixed (library-owned):** the scanner, AST, and the **HIR builder** — all the
  Unicode/flag/fold resolution and analysis. You consume the HIR; you don't change it.
- **Pluggable:** anything implementing the backend contract — the four built-ins,
  the `auto` dispatcher, and your own backend.
- **Dependency rule:** `engine/ → core/`, one way. `core/` never imports `engine/`.
  No backend imports another (except `auto`, which composes them).

The contract is **duck-typed at comptime — no vtable, no indirect call.** The
backend is always chosen at comptime, so every `Engine(Backend)` call monomorphizes
and inlines. The abstraction costs **nothing** in the match loop; it exists purely
to let runtime-only speed (a future lazy DFA) and comptime-pure matching coexist in
one library.

---

## 2. The three forms: AST → HIR → Program

| Form | What it is | Produced by | Mutable? |
|---|---|---|---|
| **AST** | faithful syntax tree, flat SoA arrays, no heap pointers | `core/scanner.zig` | no |
| **HIR** | desugared, Unicode-resolved, flags applied, folded, simplified + `Analysis` | `core/hir.zig` | no |
| **Program** | a *backend's* executable form (NFA insts, literal set, DFA tables…) | each backend | no |

The **HIR is the stable contract** between frontend and backends. A backend never
sees flags, never sees a `\d`, never does a Unicode lookup for a class — by the time
it gets the HIR, `\w` is already a sorted list of code-point ranges, `(?i)a` is
already `[Aa]`, `(?m)^` is already `line_start`.

### What the HIR builder does (driven by comptime-known `Options`)

`Options` has two tiers. The **semantic** tier changes what matches: `case_fold`
(`.none`/`.simple`/`.full`); `case_insensitive`/`multiline`/`dot_matches_newline`,
which *seed* the `(?i)`/`(?m)`/`(?s)` flag state for the whole pattern (inline `(?…)`
flags OR-merge on top of the seed); and `unicode`, which toggles ASCII vs. Unicode
`\d\w\s`. The **strategy** tier (`Options.strategy`) is **results-invariant by
contract** — reserved for the byte engine, it may change only
speed/memory, never which text matches. (See `usage-guide.md` §Options for recipes.)

- **Applies & drops flags.** `(?i)`/`(?m)`/`(?s)` and scoped `(?flags:…)` disappear:
  `m` picks the anchor kind, `s` sets dot-all on `.`, `i` folds literals/classes.
- **Resolves all Unicode to ranges.** `\d \w \s`, `\p{…}`/`\P{…}`, scripts, and
  `[...]` collapse into **one normalized, sorted, merged, non-overlapping** code-point
  range set, **with negation already applied** (`[^…]`, `\D`, `\P`). Match-time
  membership is then "is cp in some range" — nothing more. With `Options.unicode =
  false` the shorthands `\d`/`\w`/`\s` resolve to their classic ASCII sets instead
  (smaller automata); `.` and `\b` stay Unicode-aware.
- **Case folding.** `simple` widens ranges to their fold closure (`a`↔`A`,
  `σ`↔`Σ`). `full` adds the 1→many expansions for literals (`ß`→`ss`, `ﬀ`→`ff`),
  lowering them to an alternation; character classes stay simple.
- **Simplifies.** Merges adjacent literals into runs, flattens nested concat/alt,
  inlines non-capturing groups (keeping capture numbering), drops `{1}` wrappers.
- **Keeps `{m,n}` compact** — each backend lowers it its own way.
- **Attaches `Analysis`** — sound prefilter/length facts (see §7).

---

## 3. The flow, end to end

```
pattern  ──scan──▶  AST  ──hir.build──▶  Hir  ──Backend.build──▶  Program
                                                                     │
                                       Scratch (caller-owned) ───────┤
                                                                     ▼
                                                          Engine(Backend).find / captures / …
```

1. **`scan`** (`core/scanner.zig`) — one O(n) pass, explicit stack (no recursion),
   produces the flat `Ast`. Malformed → `error.InvalidPattern` + a `Diagnostic`.
2. **`hir.build`** (`core/hir.zig`) — lowers the AST to the `Hir` (see §2).
3. **`Backend.buildAlloc` / `buildComptime`** — compiles the `Hir` into the backend's
   `Program`. The program is **self-contained**: it copies out what it needs, so the
   HIR (and AST) can be freed immediately after.
4. **Match** — `Engine(Backend).<op>(program, scratch, input, …)`.

### Comptime vs runtime is only *where storage lives*

Every stage runs identically at comptime and runtime; the only difference is whether
its output arrays live in `ro_data` (comptime) or on the heap (runtime). This is the
**storage-agnostic** pattern, used in three places (`scanner`, `hir`, `nfa`):

- A `measure` pass runs the exact lowering in count-only mode to get exact sizes.
- An `emit` pass fills caller-provided buffers and returns slices into them.
- Thin wrappers (`buildAlloc` heap / `buildComptime` ro_data) provision those buffers.

`measure` and `emit` share one `Builder(comptime mode)` body, so they can't drift.

> **⚠️ Comptime is bounded — prefer `compileRuntime` for big patterns.** `compileComptime`
> lowers the whole pipeline in the compiler's const-evaluator and bakes the program into
> `ro_data`. It only works until the eval-branch quota / compiler memory runs out, so a
> large or pathological pattern can fail to build or make the build slow and heavy — use
> `compileRuntime` there (no ceiling). Each embedded comptime program adds *its own*
> ranges to `ro_data` (~6.3 KB per distinct `\w`, ~5.3 KB per `\p{L}`, ≤0.5 KB for ASCII
> classes), but identical classes within a program are **interned** (so `\w{3,32}` costs
> one `\w`, not 35 — see §3.1), and `compileRuntime` adds nothing to the binary at all.
> **This trade-off is the user's to make.**

### 3.1 Binary footprint — the Unicode tables are a *fixed* cost

A recurring worry is that resolving Unicode classes "pulls in huge tables." It does
pull in tables, but the size is **bounded and constant**, not proportional to how many
or how complex your patterns are:

- **Range tables, linked once (~135 KB total).** All Unicode work is delegated to
  `ezi_code`'s *enumerable range tables* — `category_runs`, `derived_runs`,
  `script_runs`, and the simple case-fold table. The HIR resolves every class from
  them, and `\b`/`isWord` and the scanner's group-name validation go through their
  range-backed predicates too. These tables are a one-time link cost: **the same ~135 KB
  whether the program compiles one regex or ten thousand.**
- **No per-code-point page tries.** ezi_gex deliberately uses only the *range* tables,
  never `ezi_code`'s two-level per-code-point page tries (General_Category + Derived­Core­Properties),
  which alone are ~220 KB. They are not linked.
- **Program interning.** When `nfa` compiles the HIR it **interns identical class
  range-blocks** in the `Program` (`engine/nfa.zig`, `addRanges`): two class instructions
  with the same resolved ranges share one block. So a class repeated within a pattern —
  by concatenation, capture groups, or a counted repeat like `\w{3,32}` — is stored
  **once**. This shrinks both the heap program and, for `compileComptime`, the `ro_data`.
- **Where size *does* scale:** only the `ro_data` of the `compileComptime` programs you
  choose to bake in, by one block per *distinct* class per pattern. Runtime-compiled
  regexes live on the heap and add nothing to the binary beyond the shared tables.

---

## 4. The backend contract

A backend is a `type` (namespace). `engine/backend.zig` defines the shared vocabulary
and `verifyBackend(B)` checks the mandatory shape.

### Mandatory (checked by `verifyBackend`)

```zig
pub const caps: Caps;            // comptime capabilities (captures? stateless? grapheme?)
pub const Program: type;         // the executable form — slices/POD only (ro_data- or heap-able)
pub const Scratch: type;         // per-search companion TYPE (use `struct{}` if stateless)
pub fn isMatch(program: *const Program, scratch: *Scratch, input: []const u8, o: SearchOptions) bool;
// …and AT LEAST ONE of:
pub fn buildAlloc(allocator, hir: Hir, opts) BuildError!Program;     // → heap
pub fn buildComptime(comptime hir: Hir, comptime opts) Program;      // → ro_data
```

### Optional (used only behind `@hasDecl` — a hard error only when actually called)

```zig
pub fn search(program, scratch, input, o) ?Match;                    // needed by find/findAll/split/replace
pub fn searchCaptures(program, scratch, input, slots: []?usize, o) ?Match; // needed if caps.captures
pub fn freeProgram(allocator, program) void;                         // needed if you buildAlloc
// Scratch lifecycle (the caller constructs the Scratch, ArrayList-style):
pub fn Scratch.init(allocator, program) ScratchError!Scratch;
pub fn Scratch.initBuffer(buf: []Buf, program) ScratchError!Scratch; // fixed buffer → comptime-able
pub fn Scratch.reset(self) void;
pub fn Scratch.deinit(self, allocator) void;
```

`Engine(Backend)` implements **everything else once, generically** on top of
`search`/`searchCaptures`: `find`, `findAll`, `captures`, `capturesAll`, `count`,
`split`, `replaceAll`. A backend never writes iteration, capture views, or template
expansion.

### The split of responsibilities

- The backend **locates a match and fills a `slots` array**. That's it.
- `Engine` turns those two primitives into the whole user-facing API.
- The front door (`Compiled`) stores `Program` + `Meta` + allocator and forwards.

---

## 5. Writing a backend — a complete tiny example

Here is a real, complete backend in ~40 lines. It only handles patterns that are a
single literal run (`abc`, `héllo`) — anything else it rejects at build — and scans
for it by bytes. It is stateless, so its `Scratch` is empty. It shows **every**
moving part of the contract.

```zig
const std = @import("std");
const gex = @import("ezi_gex");
const Be = gex.Backend;        // engine/backend.zig: Caps, Match, SearchOptions, BuildError…
const Hir = gex.Hir;

pub const WholeLiteral = struct {
    // 1) Capabilities. The dispatcher/front door read these.
    pub const caps = Be.Caps{ .captures = true, .stateless = true };

    // 2) The compiled program: POD/slices only, so it works in ro_data or on the heap.
    pub const Program = struct { needle: []const u8 };

    // 3) Per-search state. None here → an empty struct with no-op lifecycle, so the
    //    front door can treat it uniformly with stateful backends.
    pub const Scratch = struct {
        pub fn init(_: std.mem.Allocator, _: *const Program) !Scratch { return .{}; }
        pub fn deinit(_: *Scratch, _: std.mem.Allocator) void {}
    };

    pub const Options = struct {};

    // 4) Build: HIR → Program. We accept only a single literal run (ASCII here, for
    //    brevity; a real backend would UTF-8-encode each code point via ezi_code).
    pub fn buildAlloc(gpa: std.mem.Allocator, h: Hir, _: Options) Be.BuildError!Program {
        const root = h.nodes[h.root];
        if (root.tag != .literal) return error.Unsupported; // not a pure-literal pattern
        const run = root.data.run;
        const needle = try gpa.alloc(u8, run.len);
        errdefer gpa.free(needle);
        for (h.literals[run.start..][0..run.len], 0..) |cp, i| {
            if (cp > 0x7F) return error.Unsupported;        // ASCII-only demo
            needle[i] = @intCast(cp);
        }
        return .{ .needle = needle };
    }
    pub fn freeProgram(gpa: std.mem.Allocator, p: *Program) void { gpa.free(p.needle); }

    // 5) The primitives. `search` is leftmost-first by construction (left→right scan).
    pub fn search(p: *const Program, _: *Scratch, input: []const u8, o: Be.SearchOptions) ?Be.Match {
        var i = o.start;
        while (i + p.needle.len <= input.len) : (i += 1) {
            if (std.mem.eql(u8, input[i..][0..p.needle.len], p.needle))
                return .{ .start = i, .end = i + p.needle.len };
            if (o.anchored) break; // anchored: only the start position
        }
        return null;
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

Use it through the normal front door — no special path:

```zig
comptime gex.verifyBackend(WholeLiteral); // assert the contract at compile time

var diag: gex.Diagnostic = .{};
var re = try gex.compileRuntimeWith(WholeLiteral, gpa, "abc", &diag, .{});
defer re.deinit();
var sc = try @TypeOf(re).Scratch.init(gpa, &re.program); // construct off the Scratch type
defer sc.deinit(gpa);

const m = re.find(&sc, "xxabcyy").?;     // "abc"  — and findAll/count/split/replaceAll
_ = m;                                    // all work, implemented once by Engine(WholeLiteral)
```

### To go further

- **Want captures beyond the whole match?** Set `caps.captures = true` (already) and
  write real group slots in `searchCaptures` (indices `2*g` / `2*g+1` for group `g`).
- **Want comptime matching** (`findComptime`, etc.)? Provide the buffer convention so
  the caller can declare a `[N]Buf` scratch and the matcher runs in const-eval:
  ```zig
  pub const Buf = Be.Cell;                       // the buffer word type
  pub fn bufferLen(program) usize { … }          // how many Buf words you need
  pub fn initBuffer(buf: []Buf, program) Be.ScratchError!Scratch { … } // carve by plain SLICING
  ```
  Carve `buf` with `Be.Carver` (pure slicing — no `@ptrCast`, which is why it runs at
  comptime). A `[]u8` arena **cannot** be carved at comptime; a typed `[]Cell` can.
  See `engine/backends/pikevm.zig` for the full pattern.
- **Want `auto` to route to you?** `auto` is just one assembly of backends
  (`engine/backends/auto.zig`); copy it, add your backend to its `supports`/route
  logic, and use *your* dispatcher as the default backend. Nothing in the contract is
  privileged — your dispatcher drops in exactly like `auto`.

---

## 6. Using the stages on their own (lexer, HIR, NFA)

You don't have to go through the front door. Each stage is a usable building block,
re-exported from the root module — reach for them when you want *only* a parser,
*only* the Unicode-resolving HIR, or want to drive a chosen backend by hand.
`src/main.zig` is a runnable tour of exactly this; the snippets below are distilled
from it.

### a) Parse only — pattern → AST

`gex.parse` (heap) returns an owned `Ast` and fills a `Diagnostic` on failure;
`gex.compile` does the same at comptime (a bad pattern becomes a `@compileError`).
Walk the flat tree from `ast.root`.

```zig
const gex = @import("ezi_gex");

var diag: gex.Diagnostic = .{};
const ast = gex.parse(gpa, "(\\w+)@(\\w+)", &diag) catch {
    std.debug.print("{s} at \"{s}\"\n", .{ diag.message(), diag.faultySlice("(\\w+)@(\\w+)") });
    return;
};
defer ast.deinit(gpa);

std.debug.print("{d} capture groups, root = node {d}\n", .{ ast.capture_count, ast.root });
// Three flat arrays form the tree: ast.nodes[], ast.children[], ast.class_items[].
// A composite node's children are ast.children[d.start .. d.start + d.len].

// comptime: the AST is baked into ro_data — no allocator, no deinit.
const phone = comptime gex.compile("\\d{3}-\\d{4}");
_ = phone.nodes.len;
```

A traversal is just a `switch` on `node.tag` — see `countLiterals` in `src/main.zig`
for a worked depth-first walk.

### b) Resolve to HIR — AST → Hir

`gex.buildHir` (free with `gex.freeHir`) applies flags, folds case, and resolves all
Unicode to sorted code-point ranges — and hands you `Hir.analysis` for free. Reach for
this when you want the *resolved* form (e.g. to read a pattern's required bytes, or to
feed your own matcher) without building a `Program`.

```zig
const ast = try gex.parse(gpa, "(?i)\\w+", &diag);
defer ast.deinit(gpa);
const h = try gex.buildHir(gpa, ast, .{ .case_fold = .simple }); // opts: gex.HirOptions
defer gex.freeHir(gpa, h);

// Everything is resolved now: `\w` is h.ranges[...], the `(?i)` flag is gone.
const an = h.analysis;
std.debug.print("min_len={d}, anchored_start={}\n", .{ an.min_len, an.anchored_start });
// an.required_bytes is a 256-bit set — a sound memchr prefilter (pick the rarest byte).

// comptime variant returns an Outcome union you switch on:
const H = comptime switch (gex.buildHirComptime(gex.compile("\\d+"), .{})) {
    .ok => |x| x,
    .fail => @compileError("bad pattern"),
};
_ = H;
```

### c) Hand-wire the pipeline — pick a backend, drive `Engine` directly

The front door is just parse → HIR → `Backend.build` → wrap. Do it yourself when you
want a specific backend, or want to call the `Engine` ops on a bare `Program` +
`Scratch` without the `Compiled` wrapper. The `Program` is self-contained, so the AST
and HIR can be freed as soon as it is built.

```zig
const input = "ping bob@example.com";
const PikeVM = gex.engine.backends.pikevm;       // or .backtrack / .literal / .auto
const E = gex.engine.Engine(PikeVM);             // the agnostic op layer for this backend

const ast = try gex.parse(gpa, "(\\w+)@(\\w+)", &diag);
defer ast.deinit(gpa);
const h = try gex.buildHir(gpa, ast, .{});
defer gex.freeHir(gpa, h);

var program = try PikeVM.buildAlloc(gpa, h, .{}); // safe to freeHir right here too
defer PikeVM.freeProgram(gpa, &program);
var scratch = try PikeVM.Scratch.init(gpa, &program);
defer scratch.deinit(gpa);
const meta = gex.engine.Meta{ .capture_count = h.capture_count };

// any Engine op now works on (program, scratch):
_ = E.isMatch(&program, &scratch, input, .{});
if (E.find(&program, &scratch, input, .{})) |m| { _ = m.slice(input); }

var slots: [8]?usize = undefined;                 // 2 * (capture_count + 1)
var it = E.capturesAll(&program, &scratch, input, &slots, meta, .{});
while (it.next()) |c| { _ = c.groupSlice(1); }
```

This is the level a *backend author* tests at, and the level to use when you want one
specific backend instead of the `auto` dispatcher.

### d) No allocator at all — storage-agnostic `scan`

The scanner never allocates: `gex.scanner.scan` fills buffers *you* provide (stack,
`ro_data`, or an arena), each sized by `requiredSizes(pattern.len)`. The returned
`Ast` sub-slices those buffers, so keep them alive as long as you use it. This is the
path for parsing in a freestanding / no-heap context.

```zig
const S = gex.scanner;
const pat = "a(b|c)*";
const n = comptime S.requiredSizes(pat.len);
var nodes: [n.nodes]gex.ast.Node = undefined;
var children: [n.children]u32 = undefined;
var items: [n.class_items]gex.ast.ClassItem = undefined;
var names: [n.names][]const u8 = undefined;
var seq: [n.seq]u32 = undefined;
var alt: [n.alt]u32 = undefined;
var frames: [n.frames]S.Frame = undefined;

var diag: gex.Diagnostic = .{};
const ast = try S.scan(pat, &diag, .{
    .nodes = &nodes, .children = &children, .class_items = &items,
    .names = &names, .seq = &seq, .alt = &alt, .frames = &frames,
});
_ = ast; // valid while the buffers above are in scope
```

The same buffer trick provisions the HIR (`hir.measure` / `hir.build`) and the NFA
program — the `buildComptime` wrappers in `hir.zig` and `nfa.zig` are just this with
`ro_data` arrays.

---

## 7. The `Analysis` (prefilter/feasibility facts)

`hir.build` attaches an `Analysis` with **sound** facts — each holds for *every*
match, so a prefilter or length gate built on them never yields a false negative:

- `anchored_start` / `anchored_end` — pinned to input start/end.
- `min_len` / `max_len` (code points), `min_utf8_len` / `max_utf8_len` (bytes).
- `prefix_literal` — a literal run every match must begin with (or null).
- `required_literal` — the longest literal run every match must contain (the best
  `memmem` needle), and `required_bytes` — a 256-bit set of bytes every match must
  contain (pick the rarest for a `memchr` prefilter).
- `has_grapheme`, `has_word_boundary`, `is_whole_literal`, `is_one_pass`.

> **As of 0.1.0 the `auto` dispatcher consumes the prefilter facts on its NFA arm:**
> `min_utf8_len` (a length gate — reject inputs too short to match), `anchored_start`
> (a `^`/`\A` start short-circuit — only try offset 0), and `prefix_literal` (its first
> UTF-8 byte seeds a `memchr` start-skip, each hit confirmed by an *anchored* NFA run).
> The `literal` backend likewise scans with `std.mem.indexOf` (memchr / Boyer–Moore–
> Horspool). `required_bytes` / `required_literal` / `is_one_pass` remain unconsumed —
> scaffolding for a future one-pass / DFA path; any backend is free to read them.

---

## 8. Caveats & semantics (read before trusting edge cases)

- **Leftmost-first (Perl/JS), not POSIX leftmost-longest.** `a|ab` on `"ab"` is `"a"`.
  All built-in backends agree bit-for-bit because the NFA backends share one compiler.
- **`$` is `\z`.** Without `(?m)`, `$` matches **only** end-of-input — *not* before a
  trailing newline. `abc$` does **not** match `"abc\n"`. This is JS/Go/RE2/Rust
  semantics, not Perl/Python/PCRE. `\Z` is treated as `\z`.
- **`\X` (grapheme cluster) is `backtrack`-only.** `\X` matches one whole UAX #29
  extended grapheme cluster; it compiles to a variable-width `grapheme` NFA
  instruction. `backtrack` and `auto` set `caps.grapheme = true`; the breadth-first
  `pikevm` and the `literal` backend cannot consume a variable number of code points
  per step (`caps.grapheme = false`) and reject such a program at build, so `auto`
  routes any `\X` pattern to the backtracker (whose memo bounds `\X` over very large
  inputs).
- **No backreferences / lookaround / atomic / conditional / recursion / `\Q…\E`.**
  A Thompson NFA can't express them; each is rejected at parse with a precise code.
- **`{m,n}` expands, uncapped.** The NFA compiler emits `n` copies; a huge counted
  repeat makes a large program (bounded by allocation failure or the comptime branch
  quota — never UB, but there is no `size_limit` yet).
- **Invalid UTF-8 in input** is *dead-on-invalid* — a malformed byte matches nothing
  (no `U+FFFD` substitution) and the unanchored scan resyncs one byte past it, so a
  match never spans a bad byte. (Pattern bytes, by contrast, must be valid UTF-8 or
  `scan` rejects them.)
- **`case_fold = .full`** expands 1→many foldings for literals (`ß`→`ss`); character
  classes use simple folding. `Script_Extensions` falls back to the plain `Script`
  ranges.

---

## 9. Implicit assumptions (the contract's fine print)

Backends — including yours — may rely on all of these; the frontend guarantees them.

1. **`CodePoint` is a contract.** HIR literals and range bounds are valid scalars
   (≤ `U+10FFFF`, not a surrogate). You may `encodeCodePointUnchecked` them.
2. **HIR ranges are sorted, merged, non-overlapping, and positive.** Negation
   (`[^…]`, `\D`, `\P`) is **already applied**. Membership is just "cp ∈ some range";
   a linear or binary scan both work (`nfa.inRanges` does linear).
3. **A `class` with `len == 0` is unmatchable** (a fully-negated total set), not a
   wildcard.
4. **The `Program` is self-contained after build.** It copies every range/literal it
   needs out of the HIR, so the caller frees the AST and HIR immediately. Don't retain
   HIR slices in your `Program`.
5. **`Program` is immutable and shareable across threads** (incl. `ro_data`). **All**
   mutable per-search state lives in the caller-owned `Scratch`. Thread-safety is the
   caller's lock-free choice: share one `Program`, one `Scratch` per thread.
6. **No stale state across searches.** `Engine` zeroes capture `slots` to `null` before
   each search, and your `search`/`isMatch` must reset its own `Scratch` up front
   (the built-ins do it in O(1) via generation stamping). A non-participating group
   must read back `null`.
7. **`slots` length is `2 * (capture_count + 1)`** — two offsets per group plus the
   whole match at index 0. `Meta.slotLen()` computes it; write only what fits.
8. **Capture-group names borrow the pattern string** through the AST/HIR. The front
   door (`Compiled`) dupes them so the compiled regex outlives the pattern; a raw HIR
   consumer must keep the pattern alive.
9. **Comptime matching needs the buffer convention** (`Buf` / `bufferLen` /
   `initBuffer`) and a carve that uses **plain slicing only** — `@ptrCast` /
   `@intFromPtr` are runtime-only and will fail in const-eval.
10. **`Analysis` facts are sound one-sided bounds.** Treat them as "must hold for every
    match" (safe to prefilter on); never as "this exact thing matches".
11. **`SearchOptions.span_end` is enforced by `Engine`, not the backend.** The agnostic
    ops clamp the haystack to `[start, span_end)` before calling your `search`, so a
    backend never sees `span_end`; returned offsets still index the full `input`.
    `earliest` is advisory — a no-op for the leftmost-first built-ins (reserved for a
    future earliest-match engine).
12. **`Match.pattern` is reserved** — a defaulted `u32`, always `0` today (single
    pattern), threaded through `Match` for a future multi-pattern / set API. Leave it
    `0`; `Match{ .start, .end }` literals keep compiling unchanged.

---

## 10. Where performance goes from here (planned, additive)

The contract is the seam that makes these drop-in:

| Tier | Work | Effort | Lands at |
|---|---|---|---|
| 1 ✅ *(0.1.0)* | literal `eql` → `std.mem.indexOf`; `prefix_literal` first byte → `memchr` start-skip in `auto` (+ length/anchor gates) | done | ~20× on memchr-friendly literals and prefixed NFA patterns |
| 3a ✅ *(0.2.0)* | **byte-NFA lowering + `ByteMap`** (`engine/byte.zig`) — UTF-8 `utf8-ranges`, a `byte_range` Thompson NFA, byte equivalence classes; executed by the `bytepike` reference VM | done | the substrate for the lazy DFA below |
| 3b ✅ *(0.3.0)* | **lazy DFA** over the **byte** automaton (`engine/backends/dfa.zig`) — caches `(state, class)` transitions; span-only, runtime-only, leftmost-first via priority + cut-on-match determinization; opt-in with `byte_engine = .enabled` | done | one DFA state per byte (cached); the byte-class alphabet keeps the table tiny |
| 2 | one-pass NFA fast capture path | weeks | kills the captures penalty on common patterns |

### The byte substrate (tier 3a, landed)

`engine/byte.zig` lowers the code-point HIR to a **byte-grained** Thompson NFA: each
consuming instruction is a `byte_range [lo, hi]` test, and a Unicode class is lowered
to UTF-8 byte-range sequences (`enumerate`, the Cox/RE2 `utf8-ranges` algorithm), so a
class like `\p{Greek}` matches exactly the same code points **with zero decode**. This
is the LLVM "one IR, multiple ISAs" pattern: the HIR stays the
code-point source of truth; bytes are a second lowering target, gated by
`byteLowerable(hir)` (false for `\X` and `\b`/`\B`). `byteClasses(program)` compresses
the 256 input bytes into a handful of equivalence classes (sound + contiguous) — the
alphabet a DFA keys transitions on.

> **Size:** a byte program is *larger* than the code-point program for Unicode classes
> (a single `\w+` expands ~21×, ~137 KB; ASCII patterns are unchanged) — inherent to a
> byte NFA, which is exactly why matching throughput comes from determinizing it to a
> DFA, not from running the NFA. The huge NFA still collapses to ~100 byte classes, so
> the DFA's alphabet stays tiny. This memory is only paid when the byte path is used
> (`bytepike` or a comptime byte program); the default code-point engines are
> unaffected.

The `bytepike` backend executes this byte program (byte-stepping Pike VM, captures,
comptime + runtime) and is the **reference executor** that proves the lowering correct
(`conformance.zig`). It is not `auto`'s default — per-byte stepping is not a throughput
win over the code-point VM; the DFA (tier 3b) is what the substrate exists for.

### The lazy DFA (tier 3b, landed — `backends/dfa.zig`)

The lazy DFA **determinizes** the byte automaton at match time: a DFA state is the set
of byte-NFA program counters reachable so far, and one input byte advances one DFA
state through a cached `(state, class)` transition table (the alphabet is the program's
`ByteClasses`, a handful of classes even for a large Unicode program). Each edge is
computed once — an epsilon-closure of the successors — then memoized; every later visit
is a single array lookup. Determinization keeps the NFA states in **priority order** and
**cuts on match**, which is exactly the Pike VM's "cut lower-priority threads on match"
rule lifted into the DFA state, so the result is **leftmost-first** and its span never
disagrees with the Pike VM (`conformance.zig` and a differential corpus check it).

Three design choices follow from the contract:

- It mutates/caches state at match time, so it is **runtime-only** (`buildAlloc` +
  `search`, no `buildComptime`) — which the contract already allows (`verifyBackend`
  requires *one of* the two build paths). The cache lives in the caller-owned `Scratch`
  (never on the immutable `Program`), bounded by `ScratchOptions{ max_bytes, on_full }`
  (its first real consumer). The comptime path stays on the Pike VM.
- It is **span-only** (`caps.captures = false`): the DFA finds `[start, end)`; the
  code-point Pike VM fills captures and evaluates Unicode `\b` over that span. `auto`
  wires the two together — DFA for the span scan, Pike VM for `searchCaptures`.
- It finds the leftmost **start** by an **anchored restart** (no reverse DFA yet): it
  runs anchored at each candidate position, sharing the cache, and the first position
  that accepts is the leftmost match. It declines `\b`/`\X` and zero-width anchors for
  now (those route to the code-point engines, as they already do).

It is **opt-in** via `Options.strategy.byte_engine = .enabled` (the default `.auto`
leaves it off). That is the whole point of the backend abstraction: a runtime speed
demon and a comptime-pure matcher in one library, no fork.

---

## 11. Thread-safety

The model is **share-nothing-mutable**, encoded directly in the primitive signatures —
`search(program: *const Program, scratch: *Scratch, …)`: the `Program` is `*const`
(compiler-enforced immutable during a search), and the `Scratch` is the only mutable state.

**Safe pattern:** compile once, share the immutable `Compiled` / `Program` across threads,
give **each thread its own `Scratch`**. No locks, no atomics, no global mutable state (the
`\p{}` lookup tables are comptime `const`), so the engine is fully reentrant.

```zig
// shared, read-only, across N threads:
const re = try gex.compileRuntime(gpa, pattern, &diag, .{});
// per thread:
var sc = try @TypeOf(re).Scratch.init(thread_gpa, &re.program);
_ = re.find(&sc, input);
```

### Caveats (the fine print)

- **A `Scratch`'s concurrency model is the backend's choice.** The contract only requires
  that a search takes `*Scratch`; whether that type is thread-safe is up to the backend — one
  is free to implement a `Scratch` safe to share. **The four built-ins do not:** their
  `Scratch` is mutated on every search, so sharing one across threads concurrently is a data
  race. For them: one per thread — never pool one across them.
- **The built-in `backtrack` backend allocates *during* a search** — but through the
  allocator *you* gave it, not a hidden internal one (the front door allocates nothing while
  matching). Its heap `Scratch` grows the `(pc, sp)` visited bitset on demand through the
  allocator passed to `Scratch.init`, and `auto` routes inputs ≤ 4096 bytes to backtrack. So a
  per-thread `Scratch` is **necessary but not sufficient** — if every thread's Scratch shares
  one *non-thread-safe* allocator, two threads growing their visited sets at once race **inside
  the allocator**. Pick one:
  - give each thread its own allocator / arena (cleanest), **or**
  - use a thread-safe allocator (std `GeneralPurposeAllocator` defaults to thread-safe;
    `page_allocator` is), **or**
  - use a **buffer-backed `Scratch`** (`initBuffer`) — it never allocates during a search, **or**
  - use the `pikevm` backend directly — it never allocates during a search either.
- **Corollary:** the default `auto` + heap `Scratch` is therefore **not** strictly
  zero-allocation during matching. A buffer-backed `Scratch` (or `pikevm`) is, if you need that.
- **Compilation allocates.** `compileRuntime` (parse → HIR → program) uses its allocator;
  concurrent compiles on a single shared allocator need it to be thread-safe (standard).
- **The contract documents immutability but `verifyBackend` does not enforce it.** The
  `*const Program` signature blocks honest mutation, but a third-party backend that
  `@constCast`s or hides interior-mutable state inside its `Program` would break cross-thread
  sharing. The four built-ins don't.
