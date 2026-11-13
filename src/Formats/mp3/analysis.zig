//! Encoder analysis: PCM -> 576 MDCT lines per granule, as the exact transpose (adjoint) of
//! the decoder's synthesis in synth.zig and layer3.zig.
//!
//! Polyphase analysis: the decoder's synthesis filters are f_k[n] = w[n] cos((2k+1)(n-48)pi/64)
//! (measured: `window` recovers w from the decoder itself, so the two always agree). The
//! matched analysis filters are the same functions read forwards:
//!     s_k[t] = sum_n f_k[n] x[32t + n]
//! computed as window -> fold 512 to 64 -> 64 x 32 cosine matrix. Analysis followed by the
//! decoder's synthesis reproduces the input with no delay (the analysis looks ahead 511
//! samples instead).
//!
//! Hybrid: per subband, MDCT over 36 slots (this granule and the next, matching the
//! decoder's overlap-add), the decoder's odd-subband sign flips, and the inverse of its
//! alias-reduction butterflies.
//!
//! Subband samples are stored slot-major (`[slot][32]`), so every step below is one 32-lane
//! vector per slot (a width the layout dictates).
const std = @import("std");
const T = @import("tables.zig");
const synth = @import("synth.zig");

pub const V32 = @Vector(32, f32);

/// The analysis window, scaled so that analysis + decoder synthesis has unity gain.
pub const Window = [512]f32;

/// Recovers w[n] from the decoder's synthesis impulse response of subband 0.
pub fn window() Window {
    var qmf: [15 * 64]f32 = @splat(0);
    var lins: [(18 + 15) * 64]f32 = undefined;
    var grbuf: [1152]f32 = @splat(0);
    var pcm: [1152]f32 = undefined;
    var resp: [1152]f32 = undefined;
    grbuf[0] = 1; // subband 0, slot 0
    for (0..2) |g| {
        synth.synthGranule(&qmf, &grbuf, 18, 2, &pcm, &lins);
        for (0..576) |i| resp[g * 576 + i] = pcm[2 * i];
        @memset(&grbuf, 0);
    }
    var w: Window = undefined;
    for (&w, 0..) |*v, n| {
        const c = @cos((@as(f64, @floatFromInt(n)) - 48) * std.math.pi / 64);
        // where every f_k is zero (n = 16 mod 64) w does not matter
        v.* = if (@abs(c) < 1e-9) 0 else @floatCast(resp[n] / c / gain);
    }
    return w;
}

/// Analysis + synthesis gain with the unscaled matched filters (measured: 128).
const gain = 128.0;

/// cos((2k+1)(i-48)pi/64), stored by i so one row multiplies all 32 subbands.
const matrix: [64]V32 = blk: {
    @setEvalBranchQuota(100_000);
    var m: [64][32]f32 = undefined;
    for (0..64) |i| for (0..32) |k| {
        const a: f64 = @as(f64, @floatFromInt(2 * k + 1)) * (@as(f64, @floatFromInt(i)) - 48) * std.math.pi / 64;
        m[i][k] = @floatCast(@cos(a));
    };
    var out: [64]V32 = undefined;
    for (&out, m) |*o, row| o.* = row;
    break :blk out;
};

/// 32 subband samples of one slot from x[0 .. 512].
pub fn analyzeSlot(w: *const Window, x: []const f32) V32 {
    const V = @Vector(64, f32);
    var y: V = @splat(0);
    inline for (0..8) |j| {
        const xv: V = x[64 * j ..][0..64].*;
        const wv: V = w[64 * j ..][0..64].*;
        if (j % 2 == 0) y += wv * xv else y -= wv * xv;
    }
    const ya: [64]f32 = y;
    var s: V32 = @splat(0);
    for (matrix, ya) |row, v| s += row * @as(V32, @splat(v));
    return s;
}

pub const BlockType = enum(u2) { normal = 0, start = 1, short = 2, stop = 3 };

/// ISO 11172-3 window of a long block type (36 slots).
fn longWindow(t: BlockType, n: usize) f64 {
    const nf: f64 = @floatFromInt(n);
    const long = @sin(std.math.pi / 36.0 * (nf + 0.5));
    return switch (t) {
        .normal => long,
        .start => if (n < 18) long else if (n < 24) 1 else if (n < 30) @sin(std.math.pi / 12.0 * (nf - 18 + 0.5)) else 0,
        .stop => if (n < 6) 0 else if (n < 12) @sin(std.math.pi / 12.0 * (nf - 6 + 0.5)) else if (n < 18) 1 else long,
        .short => unreachable,
    };
}

/// window(n) cos(pi/72 (2n + 19)(2k + 1)) / 9 per long block type: the decoder's IMDCT basis
/// (measured identical for normal blocks), divided by its overlap-add gain.
const mdct_long: [4][18][36]f32 = blk: {
    @setEvalBranchQuota(1_000_000);
    var m: [4][18][36]f32 = @splat(@splat(@splat(0)));
    for ([_]BlockType{ .normal, .start, .stop }) |t| for (0..18) |k| for (0..36) |n| {
        const nf: f64 = @floatFromInt(n);
        const kf: f64 = @floatFromInt(k);
        m[@backingInt(t)][k][n] = @floatCast(longWindow(t, n) * @cos(std.math.pi / 72.0 * (2 * nf + 19) * (2 * kf + 1)) / 9.0);
    };
    break :blk m;
};

/// sin(pi/12 (n + 1/2)) cos(pi/24 (2n + 7)(2k + 1)) / 3: the 12-point short-block MDCT.
const mdct_short: [6][12]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var m: [6][12]f32 = undefined;
    for (0..6) |k| for (0..12) |n| {
        const nf: f64 = @floatFromInt(n);
        const kf: f64 = @floatFromInt(k);
        m[k][n] = @floatCast(@sin(std.math.pi / 12.0 * (nf + 0.5)) * @cos(std.math.pi / 24.0 * (2 * nf + 7) * (2 * kf + 1)) / 3.0);
    };
    break :blk m;
};

/// The decoder negates odd slots of odd subbands after its IMDCT; the encoder does the same
/// (it is its own inverse) before the MDCT.
pub const odd_subbands: V32 = blk: {
    var v: [32]f32 = undefined;
    for (&v, 0..) |*x, k| x.* = if (k % 2 == 1) -1 else 1;
    break :blk v;
};

/// MDCT of the 36 slots `slots` (this granule's 18, then the next granule's 18; already
/// sign-flipped) with the window of `block_type`, in the order the bitstream carries it:
///   long blocks:  frequency order xr[sb * 18 + k], after the inverse alias reduction
///   short blocks: by scale factor band, then window, then line (`short_widths` = the 13
///                 band widths of one window); the decoder's `reorder` undoes this.
pub fn hybrid(slots: *const [36]V32, block_type: BlockType, short_widths: []const u8, xr: *[576]f32) void {
    if (block_type == .short) return hybridShort(slots, short_widths, xr);
    var lines: [18]V32 = undefined; // [k] -> all subbands
    for (&lines, &mdct_long[@backingInt(block_type)]) |*l, row| {
        var acc: V32 = @splat(0);
        for (slots, row) |s, c| acc += s * @as(V32, @splat(c));
        l.* = acc;
    }
    for (lines, 0..) |l, k| {
        const a: [32]f32 = l;
        for (a, 0..) |v, sb| xr[sb * 18 + k] = v;
    }
    // inverse of the decoder's butterflies (each is a rotation, so its inverse is its transpose)
    for (0..31) |sb| {
        const b = sb * 18;
        for (0..8) |i| {
            const u = xr[b + 18 + i];
            const d = xr[b + 17 - i];
            xr[b + 18 + i] = u * T.aa[0][i] + d * T.aa[1][i];
            xr[b + 17 - i] = d * T.aa[0][i] - u * T.aa[1][i];
        }
    }
}

fn hybridShort(slots: *const [36]V32, short_widths: []const u8, xr: *[576]f32) void {
    // three overlapping 12-slot windows at slots 6, 12, 18 (no alias reduction)
    var lines: [3][6][32]f32 = undefined; // [window][k][sb]
    for (0..3) |w| for (&mdct_short, 0..) |row, k| {
        var acc: V32 = @splat(0);
        for (slots[6 + 6 * w ..][0..12], row) |s, c| acc += s * @as(V32, @splat(c));
        lines[w][k] = acc;
    };
    // line f of a window = subband f / 6, coefficient f % 6
    var edge: usize = 0;
    for (short_widths[0..13]) |width| {
        for (0..3) |w| for (0..width) |j| {
            const f = edge + j;
            xr[3 * edge + w * width + j] = lines[w][f % 6][f / 6];
        };
        edge += width;
    }
}

test "mp3 encoder analysis is the inverse of the decoder's synthesis" {
    const l3 = @import("layer3.zig");
    const w = window();
    // white noise, then: analysis -> hybrid -> decoder (antialias, IMDCT, sign flips, synthesis)
    const n_gr = 12;
    const lookahead = 576 + 512; // the next granule's slots, plus the window
    var x: [576 * n_gr + lookahead]f32 = @splat(0);
    var prng: std.Random.DefaultPrng = .init(5);
    const r = prng.random();
    const start = 1105; // leading silence, as the encoder pads
    for (x[start .. 576 * (n_gr - 2)]) |*v| v.* = r.float(f32) - 0.5;

    var slots: [18 * (n_gr + 1)]V32 = undefined;
    for (&slots, 0..) |*s, t| s.* = analyzeSlot(&w, x[32 * t ..]) * (if (t % 2 == 1) odd_subbands else @as(V32, @splat(1)));

    var overlap: [2][288]f32 = @splat(@splat(0));
    var qmf: [15 * 64]f32 = @splat(0);
    var lins: [(18 + 15) * 64]f32 = undefined;
    var y: [576 * n_gr]f32 = undefined;
    for (0..n_gr) |g| {
        var grbuf: [1152]f32 = @splat(0);
        hybrid(slots[18 * g ..][0..36], .normal, &.{}, grbuf[0..576]);
        l3.antialias(&grbuf, 0, 31);
        l3.imdctGr(grbuf[0..576], &overlap[0], 0, 0);
        l3.changeSign(grbuf[0..576]);
        var pcm: [1152]f32 = undefined;
        synth.synthGranule(&qmf, &grbuf, 18, 1, &pcm, &lins);
        @memcpy(y[576 * g ..][0..576], pcm[0..576]);
    }
    var sig: f64 = 0;
    var err: f64 = 0;
    for (y, x[0..y.len]) |a, b| {
        sig += b * b;
        err += (a - b) * (a - b);
    }
    const snr = 10 * @log10(sig / err);
    if (snr < 80) {
        std.debug.print("reconstruction SNR {d:.1} dB\n", .{snr});
        return error.TestUnexpectedResult;
    }
}

test "mp3 encoder block switching is the inverse of the decoder's" {
    const l3 = @import("layer3.zig");
    const w = window();
    const n_gr = 40;
    var x: [576 * (n_gr + 2) + 512]f32 = @splat(0);
    var prng: std.Random.DefaultPrng = .init(6);
    const r = prng.random();
    for (x[1105 .. 576 * (n_gr - 2)]) |*v| v.* = r.float(f32) - 0.5;
    var slots: [18 * (n_gr + 1)]V32 = undefined;
    for (&slots, 0..) |*s, t| s.* = analyzeSlot(&w, x[32 * t ..]) * (if (t % 2 == 1) odd_subbands else @as(V32, @splat(1)));

    // a random valid block sequence: start -> short* -> stop
    var types: [n_gr]BlockType = undefined;
    var prev: BlockType = .normal;
    for (&types) |*t| {
        t.* = switch (prev) {
            .start => .short,
            .short => if (r.boolean()) .short else .stop,
            .normal, .stop => if (r.uintLessThan(u8, 3) == 0) .start else .normal,
        };
        prev = t.*;
    }
    types[n_gr - 1] = if (types[n_gr - 2] == .start or types[n_gr - 2] == .short) .short else .normal;

    const widths: []const u8 = &T.scf_short[5]; // 44.1 kHz; every third entry is one band (0-terminated)
    var short_widths: [13]u8 = undefined;
    for (&short_widths, 0..) |*sw, b| sw.* = widths[3 * b];
    var overlap: [288]f32 = @splat(0);
    var qmf: [15 * 64]f32 = @splat(0);
    var lins: [(18 + 15) * 64]f32 = @splat(0);
    var scratch: [(18 + 15) * 64]f32 = undefined;
    var y: [576 * n_gr]f32 = undefined;
    for (0..n_gr) |g| {
        var grbuf: [1152]f32 = @splat(0);
        hybrid(slots[18 * g ..][0..36], types[g], &short_widths, grbuf[0..576]);
        if (types[g] == .short) {
            l3.reorder(&grbuf, 0, &scratch, widths);
        } else {
            l3.antialias(&grbuf, 0, 31);
        }
        l3.imdctGr(grbuf[0..576], &overlap, @backingInt(types[g]), 0);
        l3.changeSign(grbuf[0..576]);
        var pcm: [1152]f32 = undefined;
        synth.synthGranule(&qmf, &grbuf, 18, 1, &pcm, &lins);
        @memcpy(y[576 * g ..][0..576], pcm[0..576]);
    }
    var sig: f64 = 0;
    var err: f64 = 0;
    for (y, x[0..y.len]) |a, b| {
        sig += b * b;
        err += (a - b) * (a - b);
    }
    const snr = 10 * @log10(sig / err);
    if (snr < 80) {
        std.debug.print("block switching reconstruction SNR {d:.1} dB, types {any}\n", .{ snr, types });
        return error.TestUnexpectedResult;
    }
}
