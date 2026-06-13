# bench/ — benchmarks

Throughput and allocation measurements for the engine, built in `ReleaseFast`.

```sh
zig build bench                         # run (ReleaseFast by default)
zig build bench -Dbench-optimize=ReleaseSafe
```

| File | Role |
|---|---|
| `main.zig` | entry point; wires the modules and prints the report |
| `framework.zig` | timing harness (warmup + N samples, mean ± stddev) |
| `corpus.zig` | the three input corpora: ASCII / Multilingual / Pathological |
| `modules/search.zig` | `count()` over a pattern set — throughput = bytes scanned/sec |
| `modules/captures.zig` | `capturesAll()` + `replaceAll()` |
| `modules/compile.zig` | `compileRuntime()` over a pattern set |
| `report.zig`, `timer.zig`, `track_allocator.zig` | formatting, timing, allocation tracking |

## Reading the numbers

`search` reports **bytes scanned / sec** (the compile is cached and not counted).
As of `0.3.0-dev` all three optimizations these benchmarks were built to make
measurable have **landed**:

- the `literal` backend scans with `std.mem.indexOf` (SIMD `memchr` / Boyer–Moore–
  Horspool), and a literal *alternation* skips with a single SIMD `indexOfAny` pass;
- `auto` wires the HIR `Analysis` into a prefilter — a leading-literal `memchr`
  start-skip, a `^`/`\A` short-circuit, a `min_utf8_len` length gate, and a
  rarest-`required_bytes` fast-reject;
- the **byte DFA is on by default** — `auto` prefers the **eager DFA**
  (`engine/backends/edfa.zig`, a frozen `states × byte_classes` table) for the span scan,
  falling back to the **lazy DFA** (`engine/backends/dfa.zig`) when the eager table
  overflows its state bound.

The result: the character-class family (`\w+`, `\d+`, `[A-Za-z]+`, `\p{L}+`) now runs at
**Rust-`regex` parity** (~1.1–1.3×, was ~1.6–2.3×), and the default is ≥ the code-point
Pike VM in every cell (5–10× on class scans). `zig build bench` measures the engine in
isolation. The biggest remaining gap is a Teddy / Aho-Corasick multi-substring prefilter
for literal
alternations (Rust's Teddy is still well ahead there).

See [`../docs/architecture.md`](../docs/architecture.md) §10 for the tier roadmap (what
is done vs still open). The `count()`-per-match shape of the search bench is also why an
interleaved SIMD decode-ahead window was tried and **reverted** — `run` is called once
per match, so a fixed window over-decodes on short matches.
