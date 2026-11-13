//! Layer III Huffman encode tables, derived at compile time from the decoder's tables
//! (tables.zig) by walking their trees, so encoder and decoder can never disagree.
//! Plus bit counting and writing for the big-values and count1 regions.
const std = @import("std");
const T = @import("tables.zig");
const BitWriter = @import("bitwriter.zig");

pub const Code = struct { code: u32 = 0, len: u8 = 0 };

/// Largest value + 1 each big-values table codes directly (16 = linbits escape tables).
pub const xlen = [32]u8{ 1, 2, 3, 3, 0, 4, 4, 6, 6, 6, 8, 8, 8, 16, 0, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16 };
pub const linbits = T.linbits;

/// big_codes[table][x][y]
pub const big_codes: [32][16][16]Code = blk: {
    @setEvalBranchQuota(2_000_000);
    var all: [32][16][16]Code = @splat(@splat(@splat(.{})));
    for (1..32) |t| {
        if (xlen[t] == 0) continue;
        const cb = T.huff_tabs[T.tabindex[t]..];
        walk(cb, 0, 5, 0, 0, &all[t]);
    }
    break :blk all;
};

fn walk(cb: []const i16, off: usize, w: u5, prefix: u32, plen: u8, out: *[16][16]Code) void {
    for (0..@as(usize, 1) << w) |v| {
        const e: i32 = cb[off + v];
        if (e < 0) {
            walk(cb, @intCast(-(e >> 3)), @intCast(e & 7), (prefix << w) | @as(u32, @intCast(v)), plen + w, out);
        } else {
            const l: u5 = @intCast(e >> 8);
            const x: usize = @intCast(e & 15);
            const y: usize = @intCast((e >> 4) & 15);
            const code: Code = .{ .code = (prefix << l) | @as(u32, @intCast(v >> (w - l))), .len = plen + l };
            if (out[x][y].len == 0) out[x][y] = code;
        }
    }
}

/// count1_codes[table (0 = A, 1 = B)][vwxy as a 4-bit number]
pub const count1_codes: [2][16]Code = blk: {
    var all: [2][16]Code = @splat(@splat(.{}));
    for (0..2) |t| {
        const cb: []const u8 = if (t == 0) &T.tab32 else &T.tab33;
        for (0..64) |b| { // every 6-bit string (the longest count1 code)
            var leaf: u32 = cb[b >> 2];
            if (leaf & 8 == 0) {
                const n: u5 = @intCast(leaf & 3);
                leaf = cb[(leaf >> 3) + ((b & 3) >> (2 - n))];
            }
            const len: u5 = @intCast(leaf & 7);
            const q = (leaf >> 4) & 15;
            if (all[t][q].len == 0) all[t][q] = .{ .code = @intCast(b >> (6 - len)), .len = len };
        }
    }
    break :blk all;
};

/// Bits to code pairs ix[0..len] with big-values table `t` (null if a value doesn't fit).
pub fn countBig(t: usize, ix: []const u16) ?u32 {
    if (t == 0) {
        for (ix) |v| if (v != 0) return null;
        return 0;
    }
    const lb = linbits[t];
    const cap: u32 = if (lb != 0) 15 + (@as(u32, 1) << @intCast(lb)) - 1 else xlen[t] - 1;
    const codes = &big_codes[t];
    var bits: u32 = 0;
    var i: usize = 0;
    while (i < ix.len) : (i += 2) {
        const x: u32 = ix[i];
        const y: u32 = ix[i + 1];
        if (x > cap or y > cap) return null;
        const cx = @min(x, 15);
        const cy = @min(y, 15);
        bits += codes[cx][cy].len + @intFromBool(x != 0) + @intFromBool(y != 0);
        if (lb != 0) bits += lb * (@as(u32, @intFromBool(x >= 15)) + @intFromBool(y >= 15));
    }
    return bits;
}

/// The cheapest table for pairs ix[0..len], and its bit count.
pub fn chooseBig(ix: []const u16) struct { table: u8, bits: u32 } {
    var max: u16 = 0;
    for (ix) |v| max = @max(max, v);
    if (max == 0) return .{ .table = 0, .bits = 0 };
    var best: struct { table: u8, bits: u32 } = .{ .table = 0, .bits = std.math.maxInt(u32) };
    const candidates: []const u8 = if (max > 15) &.{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 } else switch (max) {
        1 => &.{ 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15 },
        2 => &.{ 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15 },
        3 => &.{ 5, 6, 7, 8, 9, 10, 11, 12, 13, 15 },
        4, 5 => &.{ 7, 8, 9, 10, 11, 12, 13, 15 },
        6, 7 => &.{ 10, 11, 12, 13, 15 },
        else => &.{ 13, 15, 16, 24 },
    };
    for (candidates) |t| {
        // for escapes only the first table of each linbits group that fits is worth trying
        const bits = countBig(t, ix) orelse continue;
        if (bits < best.bits) best = .{ .table = t, .bits = bits };
    }
    return .{ .table = best.table, .bits = best.bits };
}

pub fn writeBig(bw: *BitWriter, t: usize, ix: []const u16, sign: []const bool) void {
    if (t == 0) return;
    const lb: u6 = @intCast(linbits[t]);
    const codes = &big_codes[t];
    var i: usize = 0;
    while (i < ix.len) : (i += 2) {
        const x: u32 = ix[i];
        const y: u32 = ix[i + 1];
        const c = codes[@min(x, 15)][@min(y, 15)];
        bw.write(c.code, @intCast(c.len));
        if (lb != 0 and x >= 15) bw.write(x - 15, lb);
        if (x != 0) bw.write(@intFromBool(sign[i]), 1);
        if (lb != 0 and y >= 15) bw.write(y - 15, lb);
        if (y != 0) bw.write(@intFromBool(sign[i + 1]), 1);
    }
}

/// Bits for quads ix[0..len] (all values <= 1) with count1 table `t`.
pub fn countQuads(t: usize, ix: []const u16) u32 {
    var bits: u32 = 0;
    var i: usize = 0;
    while (i < ix.len) : (i += 4) {
        const q = quad(ix[i..][0..4]);
        bits += count1_codes[t][q].len + @popCount(q);
    }
    return bits;
}

fn quad(v: *const [4]u16) u32 {
    return (@as(u32, v[0]) << 3) | (@as(u32, v[1]) << 2) | (@as(u32, v[2]) << 1) | v[3];
}

pub fn writeQuads(bw: *BitWriter, t: usize, ix: []const u16, sign: []const bool) void {
    var i: usize = 0;
    while (i < ix.len) : (i += 4) {
        const q = quad(ix[i..][0..4]);
        const c = count1_codes[t][q];
        bw.write(c.code, @intCast(c.len));
        for (0..4) |k| if (ix[i + k] != 0) bw.write(@intFromBool(sign[i + k]), 1);
    }
}

test "mp3 huffman encode tables are complete prefix codes" {
    for (1..32) |t| {
        if (xlen[t] == 0) continue;
        var kraft: f64 = 0;
        for (0..xlen[t]) |x| for (0..xlen[t]) |y| {
            const c = big_codes[t][x][y];
            try std.testing.expect(c.len > 0);
            kraft += std.math.pow(f64, 2, -@as(f64, @floatFromInt(c.len)));
        };
        try std.testing.expectApproxEqAbs(@as(f64, 1), kraft, 1e-9);
    }
    for (0..2) |t| {
        var kraft: f64 = 0;
        for (count1_codes[t]) |c| kraft += std.math.pow(f64, 2, -@as(f64, @floatFromInt(c.len)));
        try std.testing.expectApproxEqAbs(@as(f64, 1), kraft, 1e-9);
    }
    // ISO 11172-3 table B is the inverted 4-bit pattern
    for (count1_codes[1], 0..) |c, q| {
        try std.testing.expectEqual(@as(u8, 4), c.len);
        try std.testing.expectEqual(@as(u32, 15 - @as(u32, @intCast(q))), c.code);
    }
}
