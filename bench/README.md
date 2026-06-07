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
The headline today is honest: throughput is in the tens-to-low-hundreds of MiB/s —
**well below RE2/Rust**, because the engine is NFA-simulation only with no prefilter
and no lazy DFA yet. The benchmarks exist to make the next optimizations *measurable*:

- wiring the HIR's `required_bytes`/`prefix_literal` into a `memchr` start-skip,
- swapping the `literal` backend's naive `eql` scan for `std.mem.indexOf`,
- adding a lazy-DFA backend.

See [`../docs/architecture.md`](../docs/architecture.md) §10 for the planned tiers.
The `count()`-per-match shape of the search bench is also why an interleaved
SIMD decode-ahead window was tried and reverted — `run` is called once per match, so
a fixed window over-decodes on short matches.
