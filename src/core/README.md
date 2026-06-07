# core/ — the fixed frontend

`pattern → AST → HIR`. Everything here is library-owned and backend-agnostic.
**`core/` never imports `engine/`** — it is a self-contained parsing + lowering
library you could use on its own (e.g. to build a different engine).

| File | Role |
|---|---|
| `token.zig` | token types; every escape/`\p{…}` name fully resolved here (no ambiguity leaves the lexer) |
| `error.zig` | the diagnostic catalogue — `ErrorCode`, `Span`, `Diagnostic` (code + byte span + message + caret renderer). Comptime-evaluable |
| `ast.zig` | the flat AST: three parallel arrays (`nodes`/`children`/`class_items`), no heap pointers, root is the *last*-emitted node |
| `scanner.zig` | the lexer + single-pass parser. **Storage-agnostic** (`scan` fills caller `Buffers`); explicit stack, no recursion |
| `compile.zig` | the comptime/runtime storage wrappers over `scan`: `parse` (heap), `parseComptime`/`compile` (ro_data) |
| `hir.zig` | **AST → HIR**: applies/drops flags, resolves all Unicode to sorted/merged code-point ranges, simple folding, simplification, and the prefilter `Analysis` |
| `root.zig` | re-exports the above |

## Two ideas that recur

- **Storage-agnostic core.** `scanner.scan` and `hir.build` never allocate — they
  fill caller-provided buffers and return slices into them. The caller decides
  whether that storage is `ro_data` (comptime) or the heap (runtime). The
  comptime/runtime split lives *only* in the thin wrappers, so one body serves both.
- **`measure` then `emit`.** Because a resolved class's range count is data-dependent
  (a single `\p{L}` is hundreds of ranges), `hir.measure` runs the identical lowering
  in count-only mode to get exact output sizes, so comptime arrays stay exact, not
  wildly over-provisioned. The same `Builder(comptime mode)` body runs both passes.

## The HIR is the contract

The `Hir` handed to backends is fully desugared: no flags, no `\d`, no Unicode
lookups left. `\w` is already sorted ranges; `(?i)a` is already `[Aa]`; `[^x]` is
already complemented. See [`../../docs/architecture.md`](../../docs/architecture.md) §2.
