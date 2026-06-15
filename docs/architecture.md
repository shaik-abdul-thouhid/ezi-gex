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
        │  literal · pikevm · backtrack · onepass · bytepike · dfa · edfa · auto · <yours> │
        │     each: build(Hir)→Program · Scratch · isMatch / search / searchCaptures│
        └───────────────────────────────────────────────────────────┬───────────────┘
                                                                    ▼
              regex.compileRuntime/Comptime → Compiled(Backend)
              re.find / captures / replaceAll → Engine(Backend).<op>(program, scratch, …)
```

- **Fixed (library-owned):** the scanner, AST, and the **HIR builder** — all the
  Unicode/flag/fold resolution and analysis. You consume the HIR; you don't change it.
- **Pluggable:** anything implementing the backend contract — the seven built-ins
  (`literal`, `pikevm`, `backtrack`, `onepass`, `bytepike`, `dfa`, `edfa`), the `auto`
  dispatcher, and your own backend.
- **Dependency rule:** `engine/ → core/`, one way. `core/` never imports `engine/`.
  No backend imports another (except `auto`, which composes them).

The contract is **duck-typed at comptime — no vtable, no indirect call.** The
backend is always chosen at comptime, so every `Engine(Backend)` call monomorphizes
and inlines. The abstraction costs **nothing** in the match loop; it exists purely
to let runtime-only speed (the lazy DFA) and comptime-pure matching (the eager DFA,
the Pike VM) coexist in one library.

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
contract** — its knobs (`byte_engine`, the byte-DFA selector on by default, and
`prefilter`, the literal/required-byte prefilter on by default) may change only
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

- **Class matching uses range tables; assertions use property tables (~385 KB total,
  linked once).** Class *matching* is delegated to `ezi_code`'s *enumerable range tables*
  — `category_runs`, `derived_runs`, `script_runs` — which the HIR resolves every class
  from (matched by a range check, no per-character lookup). The Unicode **assertions** are
  the exception and pull the larger tables: match-time `\b`/`\B` (Unicode) tests word-ness
  via `properties.isWord` (the **DerivedCoreProperties** table, ~161 KB — the single
  biggest contributor; see `engine/nfa.zig`), `\X` via the **grapheme-break** table, and
  full `(?i)` folding via the **case-fold** tables. Measured in the bundled demo (which
  exercises `\p{L}`, scripts, classes, captures): **≈ 385 KB**, the same whether the
  program compiles one regex or ten thousand.
- **It is a fixed cost, not a growing one** — and a program that uses *no* Unicode
  assertions and only ASCII classes pulls far less (`ezi_gex` still links none of
  `ezi_code`'s per-code-point *General_Category* trie; only the tables the engine's
  features actually reach are pulled in).
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

> **As of 0.1.0 the `auto` dispatcher consumes the prefilter facts on its NFA *and* DFA
> arms:** `min_utf8_len` (a length gate — reject inputs too short to match), `anchored_start`
> (a `^`/`\A` start short-circuit — only try offset 0), and `prefix_literal`. **Since 0.4.0 the
> *whole* `prefix_literal` run (not just its first byte) drives the start-skip:** a SIMD
> `memmem`-style leap to the next occurrence of the entire run (`\bthe\b` jumps "the"→"the", not
> 't'→'t'), each hit confirmed by an *anchored* run. **Since 0.4.0 a ≥2-byte run uses a
> portable two-byte SIMD `memmem`** (`engine/memmem.zig`, via `auto.memmemFrom`): probe the run's
> two **rarest** bytes, AND their `@Vector` equality masks across a 16/32-byte chunk, verify only
> where both coincide — far fewer candidates than the single-rarest-byte memchr it replaced, and
> deliberately **not** `std.mem.indexOfPos`, whose multi-byte path is a *non-SIMD* linear scan for
> needles ≤ 4 bytes (`std.mem.findPos`), the common "the"/"http" sizes.
> The `literal` backend likewise scans a **single literal** with the same two-byte SIMD `memmem`
> (`memmem.Finder`, a `literal.Program.mem` arm built for a ≥2-byte needle under `simd != .off`;
> 1-byte needles stay on the SIMD `memchr`). **Since 0.3.0 the rarest byte of `required_bytes` also drives a sound `memchr`
> fast-reject** — a byte every match must contain, absent from the input, means no match
> (no `@` ⇒ no `\w+@\w+`). **Since 0.4.0 a literal *alternation* is scanned with the SIMD
> **Teddy** prefilter** (`engine/teddy.zig`): a dynamic in-vector byte shuffle fingerprints
> the first 1–3 bytes of every branch across a 16-byte chunk at once, then verifies — slim
> (≤8 buckets, 128-bit `pshufb`/`tbl`) or **fat** (16 buckets, AVX2 256-bit `vpshufb`); the
> one arch-specific op is quarantined in `engine/simd.zig` with a portable scalar fallback,
> and the `strategy.simd` flag governs it. The **one-pass capture path now exists**
> (`backends.onepass`, since 0.4.0 — `auto` uses it for the anchored capture fill after a DFA
> locates the span), though it proves one-pass-ness itself rather than reading the
> `is_one_pass` flag. **Since 0.4.0 the multi-prefix Teddy is wired on the NFA/DFA arm**
> (`auto.Program.prefix_teddy`): it serves both a top-level alternation's leading-literal set
> (`prefix_set` — `(foo|bar)\d+`, `near`) and a synthesised **case-variant set** for a small-class
> / `(?i)` lead (`(?i)the` → `{THE…the}`), and a selective digit/number lead drives the
> **leading-class SIMD scan** (`engine/classscan.zig`, `Analysis.leading_class_first`). The plain
> `required_literal` (longest *interior* required run) and `is_one_pass` remain unconsumed *as
> Analysis fields* — any backend is free to read them today. Toggle the whole prefilter with
> `strategy.prefilter`.
>
> **Since 0.5.0 three more facts are consumed** (all results-invariant, pinned to the Pike VM):
> (1) when the whole pattern is a literal in word-boundary assertions (`\bthe\b`, `the\b`), a
> `memmem` hit is confirmed by an **O(1) word-boundary check** rather than a per-occurrence anchored
> automaton walk (`Filter.lit_wb_confirm`; ASCII boundary on the eager arm, Unicode
> `nfa.assertionHolds` on the lazy arm); (2) when the leading run before an `inner_anchor` is
> **fixed-length** (`InnerAnchor.lead_fixed_cps`, `\d{4}-…` → 4) and the input is ASCII, the skip
> jumps anchor-to-anchor and **bounded-confirms at the pinned start `anchor − off`**
> (`Filter.inner_fixed_off`) — one confirm per occurrence on a dash-dense haystack; and (3) a
> `(?m)^…` pattern with no eager DFA (`line_anchored_start`) **attempts the match anchored at each
> line start** for span *and* captures (`Filter.line_anchored`), skipping the lazy DFA's reverse and
> capture-fill passes. Separately, `auto` now gates the **eager-DFA build attempt** on byte-NFA size
> (`EAGER_BYTE_INST_MAX`) so a big Unicode-class join (`\w+@\w+`, email) goes straight to the lazy
> DFA instead of a multi-hundred-ms determinization that often only declines (email compile
> ~0.88 s → ~6 ms).

---

## 8. Caveats & semantics (read before trusting edge cases)

- **Leftmost-first (Perl/JS), not POSIX leftmost-longest.** `a|ab` on `"ab"` is `"a"`.
  All built-in backends agree bit-for-bit because the NFA backends share one compiler.
- **`$` is `\z`.** Without `(?m)`, `$` matches **only** end-of-input — *not* before a
  trailing newline. `abc$` does **not** match `"abc\n"`. This is JS/Go/RE2/Rust
  semantics, not Perl/Python/PCRE. `\Z` is treated as `\z`. (`$`/`\z` is now
  **DFA-eligible** on **both** byte DFAs — anchored-end `$` via a reverse-DFA-from-end
  pass; see §10. So are `(?m)` line anchors and `\b`/`\B`: the **eager** DFA bakes in
  non-prone `(?m)` and **ASCII** `\b`, the **lazy** DFA carries **Unicode** `\b` on
  non-ASCII input **and (since 0.4.0) a single leading `(?m)^`** including the *prone*
  newline-crossing shapes the eager DFA declines (`log_line`). Only **`\X`**, a *prone* `\b`,
  `(?m)$`/interior `(?m)^`, a *mixed* `$`, and `\b` combined with `$`/`(?m)` stay on the
  code-point Pike VM — `auto` routes all of this transparently.)
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
| 1 ✅ *(0.1.0)* | literal `eql` → `std.mem.indexOf`; `prefix_literal` first byte → `memchr` start-skip in `auto` (+ length/anchor gates); **0.3.0:** literal *alternation* skips with a single SIMD `indexOfAny` pass (was a Θ(n²) per-branch `indexOfPos`); **0.4.0:** the start-skip uses the **whole `prefix_literal` run** (`\bthe\b` jumps "the"→"the" not 't'→'t'), via the two-byte `memmem.Finder` (next row) | done | ~20× on memchr-friendly literals and prefixed NFA patterns; `foo\|bar\|baz\|qux` 7.5 → ~460 MiB/s (no longer quadratic) |
| 1+ ✅ *(0.4.0)* | **Two-byte SIMD `memmem`** (`engine/memmem.zig`) — a portable single-substring search: probe the two **rarest** needle bytes, AND their `@Vector` equality masks across a 16/32-byte chunk, verify only where both coincide. **No arch asm** (SSE2 `pcmpeqb`/NEON via portable `@Vector`; `simd.zig` stays the only arch-specific file). Wired into both the `literal` backend's single-literal scan (`literal.Program.mem`) and `auto`'s ≥2-byte prefix start-skip (`auto.memmemFrom`); governed by `strategy.simd` | done | `Sherlock` 233.67 → 13.54 µs (**17×, 40.9 GiB/s — faster than Rust**); `the` 504.75 → 62.88 µs (8×); `\bthe\b` on logs 144.96 → 23.75 µs (6×); `the\s+\p{L}+` 837 → 670 µs |
| 3a ✅ *(0.2.0, compacted 0.3.0)* | **byte-NFA lowering + `ByteMap`** (`engine/byte.zig`) — UTF-8 `utf8-ranges`, a `byte_range` Thompson NFA, byte equivalence classes; executed by the `bytepike` reference VM. **0.3.0:** UTF-8 suffix sharing (`(lo,hi,next)` cache) + single-copy `x+` shrink the NFA ~1.5–2.9×; `byteWorthLowering` cost-gate | done | the substrate for the DFAs below; smaller NFA ⇒ faster determinization |
| 3c ✅ *(0.3.0)* — **the default span engine** | **eager DFA** (`backends/edfa.zig`) — fully determinizes the byte NFA into a frozen `states × byte_classes` table; **stateless** matcher (a bare table walk, zero decode), comptime *and* runtime, span-only. **`find` is O(input) on every pattern** via the build-time `program.prone` strategy: non-prone → anchored restart, prone → the reverse-DFA two-pass (`utrans` forward-end + a frozen reverse table for the start). Supports `text_start` **and `text_end`** (`$`/`\z`). **Builds only the tables it uses** (a non-prone `\w+` keeps just its `trans`, ~141 KB, not + `utrans` + reverse — ~1 MB for a prone pattern like `\w+@\w+`) | done | class scans (`\w+`, `\d+`, `[A-Za-z]+`, `\p{L}+`) at **Rust parity** (~1.1–1.3×); the email `\w+@\w+` Θ(n²) stays fixed; tiny + bakeable for literal/ASCII (`abc` 5 states / 100 B) |
| 3b ✅ *(0.3.0)* — **the fallback** | **lazy DFA** over the **byte** automaton (`engine/backends/dfa.zig`) — caches `(state, class)` transitions; span-only, runtime-only, leftmost-first via priority + cut-on-match determinization; with an **O(n) reverse-DFA `find`**. Now the fallback when the eager DFA overflows its `max_states` bound. **0.3.0 hot-loop pass:** cached raw table pointers refreshed only after a cold transition (`\w+` ~336 → ~517 MiB/s). **0.4.0:** also matches anchored-end `$`/`\z` (reverse-from-end) and carries **Unicode `\b`** (decode-hybrid) | done | one DFA state per byte (cached); serves patterns whose full eager table is too large |
| line anchors `(?m)` & `\b`/`\B` in the DFA ✅ *(0.4.0)* | **eager** DFA bakes in **ASCII** `\b`/`\B` (word-context byte classes + one-byte word-lookahead) and non-prone `(?m)` line anchors (anchored restart with line context, `\n` isolated); the **lazy** DFA carries **Unicode** `\b` via the decode-hybrid; `auto` routes ASCII→eager, non-ASCII→lazy, declined→Pike VM | done | `\b\w+\b` 37 → 244 MiB/s (~6.6×, now ≈ plain `\w+`); `\bthe\b` 89 MiB/s → multi-GiB/s |
| one-pass NFA capture path ✅ *(0.4.0)* | **`backends.onepass`** — a single deterministic thread fills `slots` in O(input) for provably one-pass patterns; `auto` uses it for the anchored capture fill after a DFA locates the span (else the Pike VM) | done | `(\w+)` capture extraction ASCII 64 → 206 MiB/s (~3.2×) |
| DFA minimization ✅ *(0.4.0)* | **Hopcroft/Moore** partition-refinement of the eager DFA tables (results-invariant; dense layout kept) | done | `\w+@\w+` reverse DFA ~3251 → ~1047 states (~3×) |
| 3c+ | **sparse-encode** the (already minimized) eager DFA tables | weeks | shrinks the kept Unicode-class eager tables (the `\w+` ~141 KB dense → far smaller) — was paired with Hopcroft, which has landed |
| 1+ ✅ *(0.4.0)* | **Teddy SIMD multi-literal prefilter** (`engine/teddy.zig` + `engine/simd.zig`) — a dynamic in-vector byte shuffle (`pshufb`/`vpshufb`/`tbl`) fingerprints the first 1–3 bytes of every literal-alternation branch across a 16-byte chunk at once, then verifies; **slim** (≤8 buckets, 128-bit) + **fat** (16 buckets, AVX2 256-bit). The one arch-specific op is quarantined in `simd.zig` (portable scalar fallback at comptime / on other targets); gated by `strategy.simd`. Wired into the `literal` backend's alternation scan | done | closes the `foo\|bar\|baz\|qux` multi-substring gap (the single biggest one vs. Rust); validated by execution on NEON, SSSE3, and AVX2 |
| ✅ *(0.4.0)* | **Inner-literal prefilter** — for a required literal that is *interior*, not a prefix (`[\w.+-]+@…`): `auto` memchr's the anchor (`@`, via `Analysis.inner_anchor`), reverse-scans the lead class to the earliest start, then dispatches once. Gated on the anchor being rare enough (`byteRarity`) | done | `email` ~411 MiB/s → ~4.5 GiB/s |
| ✅ *(0.4.0)* | **Case-insensitive / small-class literals → case-variant Teddy** — `auto` synthesises a bounded case-variant set from a small-class / `(?i)` lead (`(?i)the` → `{THE…the}`) and drives the multi-prefix **Teddy** skip with it (`prefix_teddy`) | done | `(?i)the` ~4.6×, `(?i)sherlock holmes` ~17×, `(?i)что` ~15× |
| ✅ *(0.4.0)* + ongoing | **Unicode-class throughput** — a **leading-class SIMD scan** (`engine/classscan.zig`) skips the inter-match gaps for a selective digit/number lead (`\d+`, `\p{N}+`). The raw determinized table walk on dense Unicode classes still lags Rust (`\p{L}+`, `\d{4}-\d{2}-\d{2}`) — a faster inner loop / structural prefilter is the next step | partial | `\d+`/`\p{N}+` on sparse corpora ~33–37× (now **faster than Rust**); `date_iso`/dense letter cells still behind |
| ✅ *(0.4.0)* | **Teddy on the NFA/DFA arm** — the multi-prefix Teddy (`Program.prefix_teddy`) now serves any `prefix_set` ≥ 2 needles: a top-level alternation's leading literals (`near`'s `Holmes…\|Watson…`) AND the synthesised case-variant set above | done | `near` ~1.6× (3.4 → 5.4 GiB/s) |
| ✅ *(0.4.0)* | **`(?m)^` line anchors on the lazy DFA** — a single leading `(?m)^` runs O(input) on the lazy DFA (line-gated forward re-seed + reverse line-accept), no anchored restart, so a *prone* / newline-crossing line pattern (`log_line`) is no longer stuck on the Pike VM | done | `log_line` ~1.3× (a 7-capture, complement-class, 2-pass-`find` pattern — the DFA per-byte win is largely offset by the forward+reverse passes; still ~6× behind Rust) |
| ✅ *(0.5.0)* | **`\b`-wrapped pure-literal O(1) confirm** (`Filter.lit_wb_confirm`) — when the whole pattern is a literal in word-boundary assertions (`\bthe\b`, `the\b`), a `memmem` hit is confirmed by two O(1) boundary checks, not a per-occurrence anchored DFA walk (ASCII boundary on the eager arm; Unicode `nfa.assertionHolds` on the lazy arm, so accented prose is fast). The `memmem.Finder` is also hoisted out of the per-occurrence loop (it was rebuilt per "the" substring) | done | `\bthe\b` over prose ~490 MiB/s → **~3.7 GiB/s (≈8×)** |
| ✅ *(0.5.0)* | **Fixed-offset interior anchor** (`Filter.inner_fixed_off`, `InnerAnchor.lead_fixed_cps`) — when the leading run before the anchor is fixed-length (`\d{4}-…` → 4) and the input is ASCII, jump anchor-to-anchor and **bounded-confirm at `q − off`** (one confirm per occurrence) instead of a reverse-scan + native find that crawls a dash-dense haystack (nginx `- -`). Non-ASCII / variable-run keeps the reverse-scan path | done | `date_iso` ~610 MiB/s → **~9.8 GiB/s (≈16×)** |
| ✅ *(0.5.0)* | **Line-anchored capture/span dispatch** (`Filter.line_anchored`) — a `(?m)^…` pattern with no eager DFA attempts the match anchored at each line start (`memchr` the next `\n`) for **both** span (`count`/`find`) and captures, dropping the lazy DFA's reverse pass and the separate capture-fill pass | done | `log_line` span ~230 MiB/s → **~1.1 GiB/s (≈4.7×)** |
| ✅ *(0.5.0)* | **Eager-DFA determinization budget** (`auto.EAGER_BYTE_INST_MAX`) — `auto` only attempts the eager DFA when the byte NFA is small enough to determinize cheaply; a big Unicode-class join (`\w+@\w+`, `[\w.+-]+@…`) goes straight to the lazy DFA. The email pattern's eager DFA overflowed `max_states` and declined anyway after burning ~0.9 s | done | **email compile ~0.88 s → ~6 ms (≈140×)**, runtime unchanged (already lazy) |

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

> **Size — and why it is bounded.** A byte program is still *larger* than the code-point
> program for Unicode classes (the class table is baked into the automaton's *structure*
> rather than a flat side array), but two passes keep it in check, and determinization
> erases the rest:
>
> - **UTF-8 suffix sharing.** A class's byte sequences are built back-to-front through a
>   `(lo, hi, next)` suffix cache (RE2 / `regex-automata`'s technique), so the
>   continuation-byte tails (`[0x80, 0xBF]`) shared across hundreds of a class's
>   sequences are emitted **once** and converged on. `\w`: **3930** insts (was 5691);
>   `\p{L}`: **3337** (was 4777); `\d`: **252** (was 391). This needs `byte_range` to
>   carry an explicit `next` (a plain chain still sets `pc + 1`).
> - **Single-copy `x+`.** An unbounded `x{min,}` with a capture-free body compiles to one
>   looped body, not a duplicated one: `\w+` **3931** (was 11381), `\w+@\w+` **7860** (was
>   22760 — ~94 KB vs ~273 KB), `\d+` **253** (was 781). ASCII patterns are unchanged.
>
> The deeper point: the byte NFA is a **build-time scaffold**, not the per-search cost.
> The default span engine, the **eager DFA**, freezes the whole DFA at build (but only the
> tables it will use — see below); when its full table is too large, the **lazy DFA**
> (the fallback) materializes only the states an input actually *visits* — a handful
> over ordinary text (`\w+` touches ~10), regardless of the NFA's ~3.9 k instructions —
> so the NFA's bulk never becomes per-search memory; it determinizes lazily and caches.
> `byteWorthLowering(hir)` caps the pathological tail at build time: a big class
> repeated many times (`\p{L}{60}`) declines the byte path and stays on the compact
> code-point engine. This memory is paid only when the byte path is used (`bytepike`, the
> eager DFA, the lazy DFA, or a comptime byte program); the default code-point engines
> are unaffected.

The `bytepike` backend executes this byte program (byte-stepping Pike VM, captures,
comptime + runtime) and is the **reference executor** that proves the lowering correct
(`conformance.zig`). It is not `auto`'s default — per-byte stepping is not a throughput
win over the code-point VM; the DFA (tier 3b) is what the substrate exists for.

### The lazy DFA (tier 3b, landed — `backends/dfa.zig`) — the fallback

The lazy DFA was the default span engine; as of 0.3.0 it is the **fallback** —
reached through `auto` only when the **eager DFA** (tier 3c, below, now the default) declines
a pattern because its full state space overflows the eager `max_states` bound. It also took a
**hot-loop perf pass**: the cached raw `[*]const u32`/`[*]const bool` table pointers are
refreshed only after a *cold* (realloc-capable) transition, and the per-byte cache-budget
check moved out of the warm loop into the cold path (`\w+` ~336 → ~517 MiB/s). Everything
below about *how* it determinizes still holds.

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
- It is **span-only** (`caps.captures = false`): the DFA finds `[start, end)`. Through
  `auto`, the DFA serves the span ops (`isMatch`/`search`) and captures are filled
  **anchored at the DFA-found span start** by `onepass` (for one-pass patterns) or the Pike
  VM (the capture handoff, for both DFA arms — see *The eager DFA* below and
  `auto.searchCaptures`), turning an O(input)
  capture search into O(match).
- **`isMatch` is one-pass O(n)** (an unanchored automaton with an implicit `.*?`
  prefix); **`find` is O(n) via the reverse DFA** — a forward pass locates the leftmost
  match **end** (re-seed until the first match, then extend it anchored), then a
  **reverse DFA**, anchored at that end and scanning backward over the reversed automaton
  (`ReverseAdj`), locates the leftmost **start** (the smallest `s` with `[s, end)` a full
  match). This replaces the old **anchored restart**, killing its Θ(n²) worst case on the
  begins-everywhere-but-completes-rarely class (`\w+@\w+` on a long word run, `[ab]*c`):
  two linear passes. The reverse transitions are a plain subset construction — no priority
  or cut, just reachability of the forward start — cached like the forward ones, and
  results pinned leftmost-first to the Pike VM. The DFA also reuses `auto`'s sound
  prefilter (length gate, `^`/`\A` short-circuit, leading-literal **whole-run SIMD `memmem`**
  start-skip, rarest-required-byte fast-reject). A pattern with an *interior* `text_start` (rare, not
  fully `anchored_start`) keeps anchored restart so the cached reverse transitions stay
  position-independent. It supports `\A` / non-multiline `^`, anchored-end `$`, **isolated
  `\b`/`\B`** (Unicode word boundaries via the **decode-hybrid** — consumption stays the cached
  byte walk, boundary positions decode the adjacent code points), and **a single leading `(?m)^`**
  (line-gated forward re-seed at line starts + a reverse line-accept check — O(input), no anchored
  restart, so a *prone* newline-crossing line pattern like `log_line` runs here instead of the Pike
  VM, the quadratic-immune complement to the eager DFA's anchored-restart line support). It declines
  `\X`, `(?m)$` / interior `(?m)^`, and `\b`+`$` (those route to the code-point engines).

The **byte DFA is on by default** (`Options.strategy.byte_engine = .auto`, which means *build
and use the byte DFA* on an eligible pattern; `.disabled` opts back to the compact NFA-only
program) — but `auto` now **prefers the eager DFA** and reaches this lazy one only as the
overflow fallback. Through `auto` the chosen DFA serves `isMatch`/`find`, and
`searchCaptures` runs `onepass` (one-pass patterns) or the Pike VM **anchored at the DFA
span** (the capture handoff) so captures are correct and bounded to the match.
Results-invariant (`conformance.zig` pins the span and captures to the Pike VM and fuzzes the
strategy knobs). That is the whole point of the backend abstraction: a runtime speed demon
and a comptime-pure matcher in one library, no fork. (As of 0.4.0 the lazy DFA **also models
anchored-end `$`/`\z`** — a reverse-DFA-from-end pass, mirroring the eager DFA — so a `$`
pattern too large for the eager table falls to the lazy DFA, not all the way to the NFA. A
*mixed* `$` still routes to the Pike VM.)

### The eager DFA (tier 3c, landed — `backends/edfa.zig`) — the default span engine

Where the lazy DFA determinizes on demand and caches into a `Scratch`, the eager DFA
**fully determinizes at build time** and freezes the result into an immutable
`states × byte_classes` transition table. Because the table is complete, the matcher is a
bare `state = trans[state][class]` table walk that needs **no per-search state at all** —
so, unlike the lazy DFA, this backend has an **empty `Scratch`** (`caps.stateless = true`)
and **builds at comptime** (`buildComptime`, into `ro_data`) as well as runtime. That empty
scratch is the load-bearing difference: the lazy DFA's cache mutates at match time, which a
const-evaluator cannot do, so it is runtime-only; the eager DFA's table is finished before
matching starts, so the matcher is comptime-pure. It is **`auto`'s preferred byte engine**
(the lazy DFA is the overflow fallback). It otherwise shares the lazy DFA's contract —
span-only (`caps.captures = false`), leftmost-first by the same priority + cut-on-match
determinization (`conformance.zig` pins its span to the Pike VM's), dead-on-invalid.

**`find` is O(input) on every pattern — a *static, build-time* strategy choice, not
per-search probing.** `computeProne` detects, while building the program, whether the
anchored DFA has a **non-accepting cycle reachable from a start** — a configuration that can
consume an unbounded run *without ever accepting* (the classic Θ(n²) hazard for an anchored
restart). The program records the answer in `program.prone`, and `find` takes the matching
arm:

- **Non-prone** (`\w+`, `\d+`, `[A-Za-z]+` — their consuming loop is *itself* accepting) →
  **anchored restart**: one greedy frozen-table walk per match. It is O(input) here precisely
  because no start can scan far without hitting an accepting state, so the restarts never
  compound (~1.1 GiB/s on the frozen table).
- **Prone** → the **reverse-DFA two-pass**, which replaces the old Θ(n²) anchored restart on
  the begins-everywhere-but-completes-rarely class (`\w+@\w+`'s pre-`@` word run, `[ab]*c`):
  a forward one-pass over a frozen `.*?`-prefix table (`utrans`) locates the match **end**,
  then a frozen **reverse** transition table — determinized via `RDet` at comptime *and*
  runtime — anchored at that end and scanning backward, locates the leftmost **start**. Two
  linear passes, O(input).

Three properties are specific to determinizing *eagerly*:

- **`text_end` (`$`/`\z`) is supported — the eager DFA is broader than the lazy one.** The
  determinizer's closure records a pending `text_end` pc as a state member and computes
  `accept_eoi` (does the state reach `match` at end of input, via a `computeEndReaches`
  epsilon-fixpoint with `text_end` passable); the matcher checks `accept_eoi` when the scan
  reaches `input.len`. A **trailing-`$`** pattern (every match ends at input end —
  `anchored_end`) is matched in **O(input)** by a single **reverse-DFA pass from `input.len`**:
  the end is pinned, so the reverse DFA — which now models `$` via a passable `text_end` reverse
  edge — finds the leftmost start in one backward scan, no anchored restart, no Θ(n²). A
  **mixed** `$` (text_end in only some branches, e.g. `a$|b`) has no pinned end and is
  **declined** (it routes to the linear Pike VM). So `edfa.supports` accepts `text_start`
  (`\A`/`^`), `anchored_end` `text_end` (`$`/`\z`), **non-prone `(?m)` line anchors**
  (`line_start`/`line_end`, matched by *anchored restart with line context* — `\n` isolated into
  its own byte class, the start state chosen per position by the preceding byte, `line_end` a
  one-byte `\n`-lookahead), and **isolated `\b`/`\B`** (as **ASCII** word boundaries — the lazy
  `dfa` complements it with the *Unicode* boundary on non-ASCII input). It **declines** `\X`, a
  **mixed** `$`, a **prone** `(?m)` (`(?m)\w+$`) or **prone** `\b` (declined at *build*), a
  *chained* `\b\b`, and `\b` combined with `$`/`(?m)`. A **prone leading `(?m)^`** (`log_line`)
  the eager DFA declines now routes to the **lazy DFA** (its single-pass line support is
  quadratic-immune), not the Pike VM; everything else declined here routes to the code-point
  engines (correct + linear there).
- **It builds only the tables it will use, and minimizes them.** `utrans` and the reverse
  table are built **only for prone patterns**; a non-prone `\w+` stores just its forward `trans`
  table (~141 KB) instead of the full `trans` + `utrans` + reverse trio (which for a prone pattern like `\w+@\w+` totals ~1 MB). The kept tables are then
  **Hopcroft/Moore minimized** (since 0.4.0, results-invariant, dense layout preserved — a prone
  `\w+@\w+`'s reverse DFA shrinks ~3251 → ~1047 states). A **sparse** transition encoding remains
  a noted follow-up — tier 3c+ — for the tables that *are* kept.
- **It is bounded.** Eager determinization writes into fixed storage (so the identical code
  runs at comptime, where there is no allocator), so a pattern whose **full** DFA exceeds
  `max_states` is **declined**: `error.Unsupported` at runtime (`auto` falls back to the lazy
  DFA), a `@compileError` at comptime. The per-build buffers are sized to the pattern
  (`min(instruction_count + 256, max_states)`), so small patterns stay cheap. Size is honest:
  `abc` is 5 states / 100 B, `[a-z]+` is 3 states, a `\d{4}-\d{2}-\d{2}` date ~200 states /
  ~63 KB; a Unicode class is a few **hundred** states (`\w+` ~322 / ~141 KB **dense**,
  `\w+@\w+` ~643) — larger than the byte NFA, since a dense `states × classes` table over a
  ~100-class alphabet is big and most transitions go to the dead state. The follow-up
  minimization (3c+) shrinks the kept tables; until then a class pattern too large for the
  eager bound is served by the runtime lazy DFA.

`isMatch` is **one-pass unanchored O(n)** for prone patterns (via the same `utrans`
`.*?`-prefix table); non-prone patterns use the earliest-exit form of the anchored-restart
scan.

**At comptime `auto` gives *tiny* patterns a real frozen DFA — the genuine CTRE-lane.**
Because the eager DFA's table is finished before matching, `auto.buildComptime` can bake one
into `ro_data` and match it in const-eval — but only for a pattern small enough to
determinize in the compiler's evaluator. A cheap HIR-only check, `tinyForComptimeEdfa`, gates
it: small ASCII classes / alternations / counted reps qualify (`abc`, `\d{4}-\d{2}-\d{2}`,
`foo|bar`); a big Unicode class (`\w`, `\p{L}`) or `.` does **not** — determinizing a few
hundred states in the const-evaluator is too memory-hungry, so at comptime such a pattern
stays on the Pike VM (which the eager DFA's frozen table makes unnecessary at **runtime**,
where it gets the eager DFA regardless). This is the asymmetry the empty `Scratch` buys: the
lazy DFA **cannot** run at comptime at all (its cache mutates while matching); the eager DFA
freezes everything at build, so a tiny pattern's whole match folds into the binary — `ctre`'s
trick, with full Unicode, decided per-pattern.

**Build-time cost — determinization is ~O(states) (hash-interned).** The forward and reverse
determinizers intern DFA states through an open-addressing hash index, so building a big
Unicode-class DFA is ~linear in its state count. (This was an O(states²) linear scan — `\w+@\w+`,
`\w+@\w+$`, `\p{L}+$` took ~seconds to *compile*; now milliseconds.) Determinizing a large Unicode
class is still the dominant build cost, but it is a one-time cost — **match time stays O(input),
unaffected**; ASCII-class and literal patterns build instantly.

**Limitation — *mixed* `$` is declined (run on the Pike VM), not run quadratically.** The
reverse-from-end arm (§The eager DFA's `find`) needs the match end pinned at `input.len`
(`anchored_end`): a plain trailing `$`, or an alternation where **every** branch ends at `$`
(`foo$|bar$` — `endsAnchored` proves it). A **mixed** `$`, where `text_end` is in only *some*
branches (`a$|b`, `[ab]*c$|x`), leaves the end un-pinned, so neither the forward end-find nor the
reverse-from-end applies. Rather than fall back to the Θ(n²) anchored restart, `edfa.supports`
**declines** it and `auto` routes it to the **Pike VM** — correct and linear (O(input × program)),
just not DFA-accelerated. A two-seed reverse DFA (a `text_end`-passable seed for matches ending at
EOI, a plain seed for matches ending mid-input) could keep it on the DFA, but the shape is rare
and already linear, so it is intentionally deferred.

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
  is free to implement a `Scratch` safe to share. **The built-ins do not:** their
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
  sharing. The built-ins don't.
