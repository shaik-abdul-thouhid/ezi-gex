//! Deterministic UTF-8 corpora used as match targets.

const std = @import("std");
const framework = @import("framework.zig");
const Corpus = framework.Corpus;

/// Default working-set size (per corpus). Smaller than ezicode's because the
/// Pike VM does real per-codepoint work per match — 256 KiB × 3 corpora keeps a
/// full run to a few seconds while staying well past L2.
pub const default_size: usize = 256 * 1024;

/// Deterministic 4 KiB ASCII tile (printable range), with spaces so word/
/// token patterns find realistic boundaries.
pub const ascii_tile: [4096]u8 = blk: {
    @setEvalBranchQuota(20_000);
    var b: [4096]u8 = undefined;
    for (0..4096) |i| {
        // Cycle through printable ASCII; inject a space every 8th byte.
        b[i] = if (i % 8 == 7) ' ' else @truncate(0x21 + @mod(i, 94));
    }
    break :blk b;
};

pub const multilingual_chunks = [_][]const u8{
    "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. ",
    "Contact alice@example.com or bob@test.org for 2026-06-07 details, ref #4821. ",
    "τὸ γὰρ αὐτὸ νοεῖν ἐστίν τε καὶ εἶναι· Heraclitus fragment. ",
    "В чащах юга жил бы цитрус? Да, но фальшивый экземпляр! ",
    "한글 키보드 타자연습에 좋은 문장입니다. ",
    "口內漢字簡繁體區分與通用規範在文件與網頁上都很重要。 ",
    "naïve café résumé coördinate — Þú ert hér í dag. ",
    "العربية مع أرقام ١٢٣ والنصوص المختلطة. ",
    "ภาษาไทย สำหรับ ข้อความ ทั่วไป 12345 ",
    "Mixed: She said, \"It works!\" Then they walked on. Another? Yes! ",
};

pub const pathological_chunks = [_][]const u8{
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab ", // long runs that stress greedy quantifiers
    "abababababababababababababab ",
    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx ",
    "\u{007F}\u{0080}\u{07FF}\u{0800}\u{FFFF}\u{1F600} ",
    "word_with_many_underscores_and_digits_0123456789 ",
    "                                  ", // whitespace runs
    "no-matches-here-!!!@@@###$$$%%% ",
    "CamelCaseIdentifiersMixedWithUPPER and lower ",
};

/// Tile `chunks` into `buffer` without splitting a chunk; tail padded with spaces.
pub fn fillFromChunks(buffer: []u8, chunks: []const []const u8) []const u8 {
    var off: usize = 0;
    var i: usize = 0;
    while (off < buffer.len) {
        const chunk = chunks[i % chunks.len];
        i += 1;
        if (chunk.len > buffer.len - off) {
            while (off < buffer.len) : (off += 1) buffer[off] = ' ';
            break;
        }
        @memcpy(buffer[off..][0..chunk.len], chunk);
        off += chunk.len;
    }
    return buffer;
}

pub fn fillAsciiOnly(buffer: []u8) []const u8 {
    var off: usize = 0;
    while (off < buffer.len) {
        const rem = buffer.len - off;
        const n = @min(ascii_tile.len, rem);
        @memcpy(buffer[off..][0..n], ascii_tile[0..n]);
        off += n;
    }
    return buffer;
}

/// Owns three backing buffers — one per corpus. Free with `deinit`.
pub const CorpusSet = struct {
    allocator: std.mem.Allocator,
    ascii_buf: []u8,
    multilingual_buf: []u8,
    pathological_buf: []u8,
    corpora: [3]Corpus,

    pub fn init(allocator: std.mem.Allocator, size: usize) !CorpusSet {
        const a = try allocator.alloc(u8, size);
        errdefer allocator.free(a);
        const m = try allocator.alloc(u8, size);
        errdefer allocator.free(m);
        const p = try allocator.alloc(u8, size);
        errdefer allocator.free(p);

        const ascii = fillAsciiOnly(a);
        const multi = fillFromChunks(m, &multilingual_chunks);
        const patho = fillFromChunks(p, &pathological_chunks);

        return .{
            .allocator = allocator,
            .ascii_buf = a,
            .multilingual_buf = m,
            .pathological_buf = p,
            .corpora = .{
                .{ .name = "ASCII", .bytes = ascii },
                .{ .name = "Multilingual", .bytes = multi },
                .{ .name = "Pathological", .bytes = patho },
            },
        };
    }

    pub fn deinit(self: *CorpusSet) void {
        self.allocator.free(self.ascii_buf);
        self.allocator.free(self.multilingual_buf);
        self.allocator.free(self.pathological_buf);
    }
};
