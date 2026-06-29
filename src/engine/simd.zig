//! `simd` — the **quarantined** architecture-specific SIMD primitives.
//!
//! This is the *only* file in `ezi_gex` that emits target-specific inline assembly.
//! Everything else stays portable `@Vector`/`@reduce`/`@select` (the project SIMD
//! rule). The one primitive that cannot be expressed portably — a **dynamic in-vector
//! byte shuffle** (a table lookup whose indices come from a runtime vector, not a
//! comptime mask) — lives here, behind a comptime arch+feature gate, with a portable
//! scalar fallback that is *always* correct.
//!
//! The dynamic shuffle is the engine of **Teddy** (the multi-literal SIMD prefilter,
//! `teddy.zig`): Teddy uses it as a nibble-indexed fingerprint lookup. There is no
//! `@shuffle` equivalent because `@shuffle`'s mask must be comptime-known; this is the
//! runtime-mask case.
//!
//! ## Backends
//!
//!   * **x86-64 + SSSE3** → `pshufb` (128-bit). `has_pshufb`.
//!   * **x86-64 + AVX2**  → `vpshufb` (256-bit, **per-128-bit-lane** — see `shuffle32`).
//!     `has_vpshufb`.
//!   * **aarch64**        → `tbl` (128-bit). NEON is mandatory in ARMv8-A, so the bare
//!     arch gate suffices. `has_tbl`.
//!   * **everything else** (wasm, riscv, 32-bit arm w/o NEON, baseline x86-64) → the
//!     portable scalar fallback. Correct, just not vectorised.
//!
//! ## Two hard invariants
//!
//!   1. **No comptime asm.** Inline asm cannot run in the const evaluator, so every
//!      entry point routes a `@inComptime()` call to the scalar fallback. A Teddy
//!      prefilter is therefore a *runtime-only* accelerator; the comptime regex path
//!      keeps the existing scalar prefilter.
//!   2. **Index domain is the low nibble, 0..15.** Teddy only ever feeds indices in
//!      `0..15`. The native backends DISAGREE outside that range (x86 `pshufb` inspects
//!      only the index's low nibble + high bit; NEON `tbl` tests the whole byte `< 16`),
//!      so the contract is: callers pass indices in `0..15` and any out-of-range index
//!      yields 0 on every backend. Never feed `16..127`.
//!
//! @stable-since: v0.4.0

const std = @import("std");
const builtin = @import("builtin");

const arch = builtin.cpu.arch;

/// User-facing SIMD policy (front-door `Options.strategy.simd`, projected to the backends).
/// A **permission, not a command**: `auto` uses the native dynamic shuffle (Teddy) when the
/// build target supports it and falls back to scalar otherwise; `off` forces the scalar /
/// portable path everywhere. There is deliberately no "force on" — an arch without a native
/// shuffle resolves to scalar regardless, so no setting can produce a broken binary.
///
/// @stable-since: v0.4.0
pub const SimdMode = enum { auto, off };

// ── Comptime arch+feature gate ───────────────────────────────────────────────────

/// x86-64 with SSSE3 (the `pshufb` instruction). SSSE3 is x86-64-**v2**; the baseline
/// `x86_64` target (v1) does NOT have it, so gate on the **feature set**, not the arch
/// name, or a baseline build SIGILLs on the rare pre-2008 CPU.
///
/// @stable-since: v0.4.0
pub const has_pshufb = arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3);

/// x86-64 with AVX2 (the 256-bit `vpshufb`). AVX2 is x86-64-**v3**. Enables **fat**
/// Teddy (the 16-bucket variant, `shuffle32`).
///
/// @stable-since: v0.4.0
pub const has_vpshufb = arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

/// aarch64 (the `tbl` instruction). NEON/AdvSIMD is mandatory in ARMv8-A, so the arch
/// gate is sufficient — no feature probe needed. NEON is 128-bit only, so there is no
/// native fat Teddy here (`shuffle32` falls to scalar on aarch64).
///
/// @stable-since: v0.4.0
pub const has_tbl = arch == .aarch64;

/// Whether the 128-bit dynamic shuffle (`shuffle16`) has a native (non-scalar) lowering
/// on this build target. Slim Teddy runs whenever this is true.
///
/// @stable-since: v0.4.0
pub const has_native_shuffle16 = has_pshufb or has_tbl;

/// Whether the 256-bit dynamic shuffle (`shuffle32`) has a native lowering — i.e. AVX2.
/// **Fat** Teddy runs only when this is true.
///
/// @stable-since: v0.4.0
pub const has_native_shuffle32 = has_vpshufb;

/// Whether `@bitCast`-ing an N-lane `@Vector(N, bool)` to an N-bit movemask integer lowers
/// to a single cheap instruction on this target.
///
/// **x86-64** has `pmovmskb`/`vpmovmskb` — one instruction, ~3-cycle latency — so a SIMD
/// scan loop can compute the movemask unconditionally and branch on it. **aarch64 NEON has
/// no movemask**: LLVM emulates the bool-vector→integer bitcast with a shift-narrow-reduce
/// sequence (several instructions) that it pays on *every* chunk. On such targets a scan
/// that only needs "is there a hit, and where?" should first ask the cheap question — "did
/// **any** lane match?" via `@reduce(.Or, …)` (one `umaxv`) — and pay the emulated movemask
/// only on the rare chunk that actually hit. For a sparse needle (most chunks empty) that
/// turns a per-chunk emulated movemask into a per-chunk `umaxv`, a multiple-x speedup.
///
/// Speed-only: every surviving candidate is still fully verified, so this never changes
/// which matches are found — it only steers *how* a hot loop locates them per target.
///
/// @stable-since: v0.6.2
pub const cheap_movemask = arch == .x86_64;

// ── 128-bit dynamic byte shuffle (slim Teddy's engine) ────────────────────────────

/// Dynamic 16-byte in-vector shuffle: `out[i] = (idx[i] < 16) ? table[idx[i]] : 0`.
///
/// Native: `tbl` (aarch64) / `pshufb` (x86 SSSE3); scalar fallback elsewhere and at
/// comptime. See the module doc for the **0..15 index-domain** contract — out-of-range
/// indices yield 0 on every backend but are otherwise undefined across them.
///
/// `inline` so the comptime gate collapses at the call site (the dead arch arms are not
/// analysed, so the `tbl` asm never reaches an x86 build and vice-versa).
///
/// @stable-since: v0.4.0
pub inline fn shuffle16(table: @Vector(16, u8), idx: @Vector(16, u8)) @Vector(16, u8) {
    if (@inComptime()) return shuffle16Scalar(table, idx);
    if (comptime has_tbl) {
        return asm (
            \\tbl %[out].16b, {%[tab].16b}, %[idx].16b
            : [out] "=w" (-> @Vector(16, u8)),
            : [tab] "w" (table),
              [idx] "w" (idx),
        );
    } else if (comptime has_pshufb) {
        // AT&T order: `pshufb src, dst` ⇒ dst = shuffle(dst, src). `dst` is the table
        // (in/out, tied to output 0 via "0"); `src` is the index vector.
        return asm (
            \\pshufb %[idx], %[out]
            : [out] "=x" (-> @Vector(16, u8)),
            : [_] "0" (table),
              [idx] "x" (idx),
        );
    } else {
        return shuffle16Scalar(table, idx);
    }
}

/// Portable reference / fallback for `shuffle16`. Always correct; the native paths must
/// agree with it on the `0..15` index domain (pinned by the tests below, validated
/// cross-arch under QEMU).
fn shuffle16Scalar(table: @Vector(16, u8), idx: @Vector(16, u8)) @Vector(16, u8) {
    const t: [16]u8 = table;
    const ix: [16]u8 = idx;
    var out: [16]u8 = undefined;
    for (0..16) |i| out[i] = if (ix[i] < 16) t[ix[i]] else 0;
    return out;
}

// ── 256-bit dynamic byte shuffle (fat Teddy's engine — AVX2 only) ─────────────────

/// Dynamic 32-byte shuffle with **per-128-bit-lane** semantics (AVX2 `vpshufb`): each
/// 16-byte lane indexes ONLY its own half of the table; the index's high bit → 0, the
/// low nibble selects within the lane. i.e. for lane `L ∈ {0,1}` and `i ∈ 0..15`:
/// `out[L*16+i] = (idx[L*16+i] & 0x80) ? 0 : table[L*16 + (idx[L*16+i] & 0x0F)]`.
///
/// This lane-split is exactly what **fat** Teddy exploits to do two 8-bucket lookups in
/// one instruction (low buckets in lane 0, high buckets in lane 1). It is AVX2-only:
/// NEON has no 256-bit register, so on aarch64 this is the scalar fallback (fat Teddy is
/// simply not selected there).
///
/// @stable-since: v0.4.0
pub inline fn shuffle32(table: @Vector(32, u8), idx: @Vector(32, u8)) @Vector(32, u8) {
    if (@inComptime()) return shuffle32Scalar(table, idx);
    if (comptime has_vpshufb) {
        // AT&T 3-operand: `vpshufb idx, tab, dst` ⇒ dst = shuffle(tab, idx), per lane.
        return asm (
            \\vpshufb %[idx], %[tab], %[out]
            : [out] "=x" (-> @Vector(32, u8)),
            : [tab] "x" (table),
              [idx] "x" (idx),
        );
    } else {
        return shuffle32Scalar(table, idx);
    }
}

/// Portable reference / fallback for `shuffle32` — models AVX2 `vpshufb`'s per-128-bit-
/// lane semantics exactly (high bit → 0, low nibble selects within the lane).
fn shuffle32Scalar(table: @Vector(32, u8), idx: @Vector(32, u8)) @Vector(32, u8) {
    const t: [32]u8 = table;
    const ix: [32]u8 = idx;
    var out: [32]u8 = undefined;
    for (0..2) |lane| {
        const base = lane * 16;
        for (0..16) |i| {
            const b = ix[base + i];
            out[base + i] = if (b & 0x80 != 0) 0 else t[base + (b & 0x0F)];
        }
    }
    return out;
}

// ════════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════════

const testing = std.testing;

fn expectVecEq16(expected: @Vector(16, u8), got: @Vector(16, u8)) !void {
    const e: [16]u8 = expected;
    const g: [16]u8 = got;
    try testing.expectEqualSlices(u8, &e, &g);
}

fn expectVecEq32(expected: @Vector(32, u8), got: @Vector(32, u8)) !void {
    const e: [32]u8 = expected;
    const g: [32]u8 = got;
    try testing.expectEqualSlices(u8, &e, &g);
}

// A distinctive table so a misrouted lane shows up immediately.
const tbl16: @Vector(16, u8) = .{ 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF };

test "shuffle16: native path agrees with the scalar reference (0..15 domain)" {
    // Identity index → table unchanged.
    const id: @Vector(16, u8) = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    try expectVecEq16(tbl16, shuffle16(tbl16, id));

    // A spread of in-domain index patterns; native must match the scalar reference.
    const patterns = [_]@Vector(16, u8){
        .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 }, // reverse
        @as(@Vector(16, u8), @splat(3)), // broadcast lane 3
        .{ 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7 }, // pairs
        .{ 9, 2, 14, 5, 0, 11, 7, 7, 1, 15, 3, 8, 12, 4, 10, 6 }, // scattered
    };
    for (patterns) |p| try expectVecEq16(shuffle16Scalar(tbl16, p), shuffle16(tbl16, p));
}

test "shuffle16: out-of-range index yields 0 on every backend" {
    // Contract: idx >= 16 → 0 (true of tbl, pshufb-with-high-bit, and the scalar ref).
    const oor: @Vector(16, u8) = @splat(0x80); // high bit set ⇒ 0 on pshufb; >=16 ⇒ 0 on tbl
    try expectVecEq16(@splat(0), shuffle16(tbl16, oor));
}

test "shuffle16: comptime evaluates via the scalar fallback (no asm in const-eval)" {
    const rev: @Vector(16, u8) = .{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 };
    const got = comptime shuffle16(tbl16, rev);
    const want = comptime shuffle16Scalar(tbl16, rev);
    try comptime expectVecEq16(want, got);
}

test "shuffle32: per-128-bit-lane semantics (index stays within its own lane)" {
    // Lane 0 = 0xB0..0xBF, lane 1 = 0xC0..0xCF — so a cross-lane bug is obvious.
    const t: @Vector(32, u8) = .{
        0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF,
        0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF,
    };
    // Index 0 in BOTH lanes selects each lane's OWN byte 0 → 0xB0 in lane 0, 0xC0 in lane 1.
    const zero_idx: @Vector(32, u8) = @splat(0);
    const want_zero: @Vector(32, u8) = .{
        0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0,
        0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0, 0xC0,
    };
    try expectVecEq32(want_zero, shuffle32(t, zero_idx));

    // Scattered in-domain pattern: native (or scalar fallback) must match the reference.
    const scat: @Vector(32, u8) = .{
        15, 0, 7, 3, 9, 1, 14, 2, 6, 11, 4, 8, 13, 5, 10, 12,
        2, 14, 0, 9, 5, 15, 3, 7, 1, 12, 6, 11, 8, 4, 10, 13,
    };
    try expectVecEq32(shuffle32Scalar(t, scat), shuffle32(t, scat));
}
