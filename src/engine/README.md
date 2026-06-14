# engine/ — the contract, the backends, the front door

`Hir → Program → match`. Depends on `core/` (one way). This is where matching lives.

| File | Role |
|---|---|
| `backend.zig` | the **backend contract** + shared types (`Caps`, `Match`, `SearchOptions`, `Meta`, `Captures`, the `Cell`/`Carver` scratch helpers), `verifyBackend`, and **`Engine(Backend)`** — the agnostic op layer that implements `find`/`findAll`/`captures`/`split`/`replaceAll`/`count` once, for any backend |
| `nfa.zig` | the **shared** Thompson-NFA: instruction set, the HIR→program compiler, and the code-point primitives (`inRanges`, `decodeAt`, `assertionHolds`). **Not a backend** — pikevm and backtrack both execute it |
| `byte.zig` | the **byte-NFA substrate** (also not a backend): UTF-8 `utf8-ranges` lowering, a `byte_range` Thompson NFA (zero-decode), and `ByteMap` byte equivalence classes. The substrate the eager DFA (`backends/edfa.zig`, the default span engine) and lazy DFA (`backends/dfa.zig`) determinize and `bytepike` executes. Gated by `byteLowerable(hir)` (no `\X`; `\b`/`\B` **do** lower — as ASCII word boundaries, evaluated by `assertionHolds`) |
| `backends/` | the built-in backends (see [`backends/README.md`](backends/README.md)) — incl. `edfa`/`dfa`, the eager + lazy DFAs over `byte.zig` |
| `conformance.zig` | cross-backend tests: every backend agrees, runtime + comptime |
| `regex.zig` | the **front door** — `compileRuntime`/`compileComptime`(`With`) → `Compiled(Backend)`, the user-facing API |
| `root.zig` | re-exports; `default_backend = auto` |

## How a match happens

1. `regex.compile*` runs `core` (pattern → AST → HIR), then `Backend.build*`
   (HIR → `Program`), and stores the `Program` + capture `Meta`.
2. The caller makes a `Scratch` of the backend's `Scratch` type and hands it to the
   search ops — that is all the engine requires; it dictates no representation. *How*
   the `Scratch` is built is the backend's design, so the caller builds it **directly
   off `@TypeOf(re).Scratch`**, not through any front-door method — `Compiled` holds the
   `Scratch` type and forwards `&sc`, nothing more. The built-in backends offer two
   conventions: `@TypeOf(re).Scratch.init(gpa, &re.program)` (heap) and
   `@TypeOf(re).Scratch.initBuffer(buf, &re.program)` over a
   `@TypeOf(re).Scratch.bufferLen(&re.program)`-sized `@TypeOf(re).Scratch.Buf` buffer
   (no allocator). A backend with a different protocol is built however it specifies (a
   stateless one is just `.{}`). The caller owns it; the built-ins' `Scratch` is one per
   thread (a backend may instead implement a thread-safe one).
3. `re.find(&sc, input)` forwards to `Engine(Backend).find`, which calls the
   backend's `search` primitive. The backend only locates a match and fills slots;
   `Engine` does all iteration/captures/replace.

## Writing your own backend

A backend is a `type` satisfying `backend.zig`. The mandatory surface is just
`caps`, `Program`, `Scratch`, `isMatch`, and one of `buildAlloc`/`buildComptime`;
everything else is optional and gated by `@hasDecl`. Sketch:

```zig
pub const MyBackend = struct {
    pub const caps = gex.Backend.Caps{ .captures = true, .stateless = true };
    pub const Program = struct { /* POD / slices only */ };
    pub const Scratch = struct { /* per-search state, or empty */ };
    pub const Options = struct {};

    pub fn buildAlloc(gpa, h: gex.Hir, _: Options) gex.Backend.BuildError!Program { … }
    pub fn isMatch(p: *const Program, s: *Scratch, in: []const u8, o: gex.SearchOptions) bool { … }
    pub fn search(p: *const Program, s: *Scratch, in: []const u8, o: gex.SearchOptions) ?gex.Match { … }
    pub fn searchCaptures(p, s, in, slots: []?usize, o) ?gex.Match { … } // if caps.captures
};

// then:
var re = try gex.compileRuntimeWith(MyBackend, gpa, pattern, &diag, .{});
```

A **complete, runnable ~40-line example** (with the build step, the search loop, and
how to add comptime support) is in
[`../../docs/architecture.md`](../../docs/architecture.md) §5; a longer, built-up-in-
four-steps version (validated, with comptime support and notes on reusing the shared
NFA) is in [`../../docs/usage-guide.md`](../../docs/usage-guide.md) §8. Read §9 in
architecture.md for the implicit assumptions a backend may rely on (HIR ranges are
sorted/positive, the program is self-contained, the Program is immutable + the Scratch
is caller-owned, etc.).
