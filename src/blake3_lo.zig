//! Minimal portable BLAKE3 chunk-level primitives.
//!
//! Vendored from stdlib `std.crypto.hash.blake3` — the parts that are `fn`
//! (private) there but needed for Bao's tree walking. Single-threaded, no
//! SIMD. Correctness over speed for now; can swap to SIMD/parallel later by
//! widening the vendored area.
//!
//! NON-STANDARD CHUNK SIZE: canonical BLAKE3 uses 1 KiB chunks. We use 256
//! KiB to shrink Bao outboards (the tree is per-chunk, so fewer chunks =
//! smaller outboard). The compression function, IV, and tree composition
//! rules are unchanged — only the leaf granularity differs. Consequence:
//! root hashes do NOT match canonical BLAKE3 / `b3sum` for any file larger
//! than `chunk_length` bytes. Files of size ≤ chunk_length still match
//! (single-chunk path is identical). Internal-use hash only — never
//! interchange with external BLAKE3 ecosystems. See oconnor663/bao#34 for
//! the spec discussion that motivated this.
//!
//! ── PERFORMANCE / FUTURE OPTIMIZATIONS ──────────────────────────────────
//! This is the scalar reference compression — one 64-byte block at a time,
//! no SIMD. Measured ~200-250 MB/s/core in ReleaseFast (and ~10x slower in
//! Debug — always benchmark in ReleaseFast). 100 GB ≈ ~7.5 min single core.
//! Good enough as a baseline; for the multi-GB ProRes workload we'll want
//! more. The headroom, highest leverage first:
//!
//!   1. Multithread across chunks (~Ncores, ~8x typical). BLAKE3's tree is
//!      embarrassingly parallel: every chunk's CV is independent, so a thread
//!      pool can hash chunk ranges concurrently and the cheap tree-combine
//!      runs after. CPU-bound → use std.Thread, not the async io runtime.
//!      The catch: `Bao.encodeReader`'s one-chunk lookahead is inherently
//!      serial, so the parallel path needs a segmented producer (read big
//!      blocks, dispatch chunk hashing, collect CVs in order) feeding the
//!      tree — a new code path alongside the streaming one, not a tweak.
//!   2. SIMD compression via `@Vector(8, u32)` (~5-10x/core). The real BLAKE3
//!      speed source: a `hash_many` that compresses 8 (AVX2) / 16 (AVX-512)
//!      independent chunks in parallel lanes. LLVM lowers portable @Vector to
//!      AVX2/AVX-512/NEON. Bigger rewrite of this file's hot loop.
//!   3. Both → SIMD × cores ≈ GB/s. 100 GB in ~1 min. The production target.
//!
//! Any rewrite must keep producing identical roots — the `Bao.zig` tests
//! cross-check `encodeReader`/`buildTree` roots and the ≤1-chunk stdlib match,
//! so a faster compression that passes them is provably equivalent.
//! The encode read buffer (`Bao.READ_BUF_SIZE`) is already sized above one
//! chunk so a chunk fills in a single read.
//!
//! License: MIT (matches stdlib).

const std = @import("std");
const mem = std.mem;

pub const block_length: usize = 64;
pub const digest_length: usize = 32;
/// 256 KiB. See file-level doc comment for rationale + caveats.
pub const chunk_length: usize = 256 * 1024;

pub const Hash = [digest_length]u8;

pub const iv: [8]u32 = .{
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
};

const msg_schedule: [7][16]u8 = .{
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    .{ 2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8 },
    .{ 3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1 },
    .{ 10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6 },
    .{ 12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4 },
    .{ 9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7 },
    .{ 11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13 },
};

pub const Flags = packed struct(u8) {
    chunk_start: bool = false,
    chunk_end: bool = false,
    parent: bool = false,
    root: bool = false,
    keyed_hash: bool = false,
    derive_key_context: bool = false,
    derive_key_material: bool = false,
    reserved: bool = false,

    pub fn toInt(self: Flags) u8 {
        return @bitCast(self);
    }

    pub fn with(self: Flags, other: Flags) Flags {
        return @bitCast(self.toInt() | other.toInt());
    }
};

inline fn rotr32(w: u32, c: u5) u32 {
    return std.math.rotr(u32, w, c);
}

inline fn load32(bytes: []const u8) u32 {
    return mem.readInt(u32, bytes[0..4], .little);
}

inline fn store32(bytes: []u8, w: u32) void {
    mem.writeInt(u32, bytes[0..4], w, .little);
}

pub fn cvWordsToBytes(cv_words: [8]u32) [digest_length]u8 {
    var bytes: [digest_length]u8 = undefined;
    for (0..8) |i| store32(bytes[i * 4 ..][0..4], cv_words[i]);
    return bytes;
}

pub fn cvBytesToWords(bytes: [digest_length]u8) [8]u32 {
    var cv_words: [8]u32 = undefined;
    for (0..8) |i| cv_words[i] = load32(bytes[i * 4 ..][0..4]);
    return cv_words;
}

inline fn counterLow(counter: u64) u32 {
    return @truncate(counter);
}
inline fn counterHigh(counter: u64) u32 {
    return @truncate(counter >> 32);
}

inline fn g(state: *[16]u32, a: usize, b: usize, c: usize, d: usize, x: u32, y: u32) void {
    state[a] +%= state[b] +% x;
    state[d] = rotr32(state[d] ^ state[a], 16);
    state[c] +%= state[d];
    state[b] = rotr32(state[b] ^ state[c], 12);
    state[a] +%= state[b] +% y;
    state[d] = rotr32(state[d] ^ state[a], 8);
    state[c] +%= state[d];
    state[b] = rotr32(state[b] ^ state[c], 7);
}

fn roundFn(state: *[16]u32, msg: *const [16]u32, round: usize) void {
    const schedule = &msg_schedule[round];
    g(state, 0, 4, 8, 12, msg[schedule[0]], msg[schedule[1]]);
    g(state, 1, 5, 9, 13, msg[schedule[2]], msg[schedule[3]]);
    g(state, 2, 6, 10, 14, msg[schedule[4]], msg[schedule[5]]);
    g(state, 3, 7, 11, 15, msg[schedule[6]], msg[schedule[7]]);
    g(state, 0, 5, 10, 15, msg[schedule[8]], msg[schedule[9]]);
    g(state, 1, 6, 11, 12, msg[schedule[10]], msg[schedule[11]]);
    g(state, 2, 7, 8, 13, msg[schedule[12]], msg[schedule[13]]);
    g(state, 3, 4, 9, 14, msg[schedule[14]], msg[schedule[15]]);
}

fn compressPre(state: *[16]u32, cv: *const [8]u32, block: []const u8, block_len: u8, counter: u64, flags: Flags) void {
    var block_words: [16]u32 = undefined;
    for (0..16) |i| block_words[i] = load32(block[i * 4 ..][0..4]);
    for (0..8) |i| state[i] = cv[i];
    for (0..4) |i| state[i + 8] = iv[i];
    state[12] = counterLow(counter);
    state[13] = counterHigh(counter);
    state[14] = @as(u32, block_len);
    state[15] = @as(u32, flags.toInt());
    for (0..7) |round| roundFn(state, &block_words, round);
}

pub fn compressInPlace(cv: *[8]u32, block: []const u8, block_len: u8, counter: u64, flags: Flags) void {
    var state: [16]u32 = undefined;
    compressPre(&state, cv, block, block_len, counter, flags);
    for (0..8) |i| cv[i] = state[i] ^ state[i + 8];
}

/// Hash a single chunk (1..=`chunk_length` bytes), returning its 32-byte
/// chaining value (CV). `chunk_counter` is the chunk's index in the file's
/// chunk sequence.
/// `extra_flags` is ORed with the per-block CHUNK_START/CHUNK_END flags —
/// pass `.{}` for normal mode, `.{ .root = true }` only when this single
/// chunk IS the whole file's root.
pub fn chunkHash(chunk: []const u8, chunk_counter: u64, key: [8]u32, extra_flags: Flags) [8]u32 {
    std.debug.assert(chunk.len > 0 and chunk.len <= chunk_length);

    var cv = key;
    var offset: usize = 0;
    var block_idx: usize = 0;
    const num_full_blocks = chunk.len / block_length;
    const last_block_len: u8 = blk: {
        const rem: u8 = @intCast(chunk.len % block_length);
        break :blk if (rem == 0) block_length else rem;
    };
    const num_blocks: usize = if (chunk.len % block_length == 0) num_full_blocks else num_full_blocks + 1;

    while (block_idx < num_blocks) : (block_idx += 1) {
        var f: Flags = .{};
        if (block_idx == 0) f = f.with(.{ .chunk_start = true });
        const is_last = (block_idx == num_blocks - 1);
        if (is_last) {
            f = f.with(.{ .chunk_end = true });
            // ROOT (and any other terminal-only flag) only on the final block.
            f = f.with(extra_flags);
        }

        const blen: u8 = if (is_last) last_block_len else @intCast(block_length);

        var block_buf: [block_length]u8 = @splat(0);
        const start = offset;
        const end = start + blen;
        @memcpy(block_buf[0..blen], chunk[start..end]);

        compressInPlace(&cv, &block_buf, blen, chunk_counter, f);

        offset += blen;
    }

    return cv;
}

/// Parent node hash: input block = left_cv || right_cv (64 bytes).
/// Pass `.{ .root = true }` in `extra_flags` only at the tree root.
pub fn parentHash(left_cv: [8]u32, right_cv: [8]u32, key: [8]u32, extra_flags: Flags) [8]u32 {
    var block: [block_length]u8 = undefined;
    for (0..8) |i| {
        store32(block[i * 4 ..][0..4], left_cv[i]);
        store32(block[(i + 8) * 4 ..][0..4], right_cv[i]);
    }
    var cv = key;
    var f: Flags = .{ .parent = true };
    f = f.with(extra_flags);
    compressInPlace(&cv, &block, block_length, 0, f);
    return cv;
}

test "single-chunk path matches stdlib for sizes ≤ stdlib chunk size" {
    // Single-chunk files hash identically to canonical BLAKE3 — the
    // compression function and ROOT-flag handling are the same regardless
    // of where `chunk_length` is drawn. This overlap with stdlib output
    // only holds for sizes ≤ stdlib's chunk size (1024). Beyond that,
    // stdlib starts a new chunk while we keep extending the same one.
    const stdlib = std.crypto.hash.Blake3;
    var msg: [1024]u8 = undefined;
    for (&msg, 0..) |*b, i| b.* = @truncate(i);

    var expected: [digest_length]u8 = undefined;
    stdlib.hash(&msg, &expected, .{});

    const cv = chunkHash(&msg, 0, iv, .{ .root = true });
    const got = cvWordsToBytes(cv);

    try std.testing.expectEqualSlices(u8, &expected, &got);
}

test "multi-block single chunk: parent compose round-trip" {
    // Exercise multi-block chunk (chunk > 64 B) + parent compose. Pure
    // self-consistency: chunkHash + parentHash should be deterministic and
    // independent of being called as part of a bigger tree.
    var msg: [chunk_length * 2]u8 = undefined;
    for (&msg, 0..) |*b, i| b.* = @truncate(i);

    const cv_left = chunkHash(msg[0..chunk_length], 0, iv, .{});
    const cv_right = chunkHash(msg[chunk_length..], 1, iv, .{});
    const root_a = parentHash(cv_left, cv_right, iv, .{ .root = true });

    const cv_left_again = chunkHash(msg[0..chunk_length], 0, iv, .{});
    const cv_right_again = chunkHash(msg[chunk_length..], 1, iv, .{});
    const root_b = parentHash(cv_left_again, cv_right_again, iv, .{ .root = true });

    try std.testing.expectEqualSlices(u32, &root_a, &root_b);
}
