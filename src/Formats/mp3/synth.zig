//! Polyphase synthesis filterbank: 32 subbands -> PCM.
//! `dctII` runs W columns per vector (each column is independent, so this is bit-identical
//! to the scalar code at any width); `synth` is minimp3's 4-lane SSE windowing. The scalar
//! versions are the test oracle in scalar.zig.
const std = @import("std");
const T = @import("tables.zig");
const oracle = @import("scalar.zig");
/// columns per vector (a performance choice)
const W = @import("../../Samples/misc.zig").N / 4;

pub inline fn scalePcm(sample: f32) f32 {
    return sample * (1.0 / 32768.0);
}

pub fn synthPair(pcm: []f32, p: usize, nch: usize, z: []const f32, zo: usize) void {
    var a: f32 = undefined;
    a = (z[zo + 14 * 64] - z[zo + 0]) * 29;
    a += (z[zo + 1 * 64] + z[zo + 13 * 64]) * 213;
    a += (z[zo + 12 * 64] - z[zo + 2 * 64]) * 459;
    a += (z[zo + 3 * 64] + z[zo + 11 * 64]) * 2037;
    a += (z[zo + 10 * 64] - z[zo + 4 * 64]) * 5153;
    a += (z[zo + 5 * 64] + z[zo + 9 * 64]) * 6574;
    a += (z[zo + 8 * 64] - z[zo + 6 * 64]) * 37489;
    a += z[zo + 7 * 64] * 75038;
    pcm[p] = scalePcm(a);
    const z2 = zo + 2;
    a = z[z2 + 14 * 64] * 104;
    a += z[z2 + 12 * 64] * 1567;
    a += z[z2 + 10 * 64] * 9727;
    a += z[z2 + 8 * 64] * 64019;
    a += z[z2 + 6 * 64] * -9975;
    a += z[z2 + 4 * 64] * -45;
    a += z[z2 + 2 * 64] * 146;
    a += z[z2 + 0 * 64] * -5;
    pcm[p + 16 * nch] = scalePcm(a);
}

pub fn synthGranule(qmf_state: *[15 * 64]f32, grbuf: *[1152]f32, nbands: usize, nch: usize, pcm: []f32, lins: *[(18 + 15) * 64]f32) void {
    synthGranuleWith(false, qmf_state, grbuf, nbands, nch, pcm, lins);
}

fn synthGranuleWith(comptime scalar: bool, qmf_state: *[15 * 64]f32, grbuf: *[1152]f32, nbands: usize, nch: usize, pcm: []f32, lins: *[(18 + 15) * 64]f32) void {
    for (0..nch) |i| {
        if (scalar) oracle.dctII(grbuf[576 * i ..], nbands) else dctII(grbuf[576 * i ..][0..576], nbands);
    }
    @memcpy(lins[0 .. 15 * 64], qmf_state);
    var i: usize = 0;
    while (i < nbands) : (i += 2) {
        if (scalar) oracle.synth(grbuf, i, pcm, 32 * nch * i, nch, lins, i * 64) else synth(grbuf, i, pcm, 32 * nch * i, nch, lins, i * 64);
    }
    if (nch == 1) {
        // minimp3 keeps only the even (left) history for mono streams
        var k: usize = 0;
        while (k < 15 * 64) : (k += 2) qmf_state[k] = lins[nbands * 64 + k];
    } else {
        @memcpy(qmf_state, lins[nbands * 64 ..][0 .. 15 * 64]);
    }
}

// ───────────────────────────── vector versions ─────────────────────────────

const VW = @Vector(W, f32);

/// Columns k .. k + count of row `row` (count <= W; missing lanes are 0).
inline fn loadCols(grbuf: *const [576]f32, k: usize, row: usize, count: usize) VW {
    if (count == W) return grbuf[k + row * 18 ..][0..W].*;
    var a: [W]f32 = @splat(0);
    for (0..count) |c| a[c] = grbuf[k + row * 18 + c];
    return a;
}

inline fn storeCols(grbuf: *[576]f32, k: usize, row: usize, count: usize, v: VW) void {
    if (count == W) {
        grbuf[k + row * 18 ..][0..W].* = v;
        return;
    }
    const a: [W]f32 = v;
    for (0..count) |c| grbuf[k + row * 18 + c] = a[c];
}

inline fn sp(x: f32) VW {
    return @splat(x);
}

/// 32-point DCT-II down each of the first `n` columns (time slots) of a granule.
pub fn dctII(grbuf: *[576]f32, n: usize) void {
    var k: usize = 0;
    while (k < n) : (k += W) {
        const count = @min(W, n - k);
        var t: [4][8]VW = undefined;
        for (0..8) |i| {
            const x0 = loadCols(grbuf, k, i, count);
            const x1 = loadCols(grbuf, k, 15 - i, count);
            const x2 = loadCols(grbuf, k, 16 + i, count);
            const x3 = loadCols(grbuf, k, 31 - i, count);
            const t0 = x0 + x3;
            const t1 = x1 + x2;
            const t2 = (x1 - x2) * sp(T.sec[3 * i + 0]);
            const t3 = (x0 - x3) * sp(T.sec[3 * i + 1]);
            t[0][i] = t0 + t1;
            t[1][i] = (t0 - t1) * sp(T.sec[3 * i + 2]);
            t[2][i] = t3 + t2;
            t[3][i] = (t3 - t2) * sp(T.sec[3 * i + 2]);
        }
        for (&t) |*x| {
            var x0 = x[0];
            var x1 = x[1];
            var x2 = x[2];
            var x3 = x[3];
            var x4 = x[4];
            var x5 = x[5];
            var x6 = x[6];
            var x7 = x[7];
            var xt = x0 - x7;
            x0 += x7;
            x7 = x1 - x6;
            x1 += x6;
            x6 = x2 - x5;
            x2 += x5;
            x5 = x3 - x4;
            x3 += x4;
            x4 = x0 - x3;
            x0 += x3;
            x3 = x1 - x2;
            x1 += x2;
            x[0] = x0 + x1;
            x[4] = (x0 - x1) * sp(0.70710677);
            x5 = x5 + x6;
            x6 = (x6 + x7) * sp(0.70710677);
            x7 = x7 + xt;
            x3 = (x3 + x4) * sp(0.70710677);
            x5 -= x7 * sp(0.198912367);
            x7 += x5 * sp(0.382683432);
            x5 -= x7 * sp(0.198912367);
            x0 = xt - x6;
            xt += x6;
            x[1] = (xt + x7) * sp(0.50979561);
            x[2] = (x4 + x3) * sp(0.54119611);
            x[3] = (x0 - x5) * sp(0.60134488);
            x[5] = (x0 + x5) * sp(0.89997619);
            x[6] = (x4 - x3) * sp(1.30656302);
            x[7] = (xt - x7) * sp(2.56291556);
        }
        for (0..7) |i| {
            const sum = t[3][i] + t[3][i + 1];
            storeCols(grbuf, k, 4 * i + 0, count, t[0][i]);
            storeCols(grbuf, k, 4 * i + 1, count, t[2][i] + sum);
            storeCols(grbuf, k, 4 * i + 2, count, t[1][i] + t[1][i + 1]);
            storeCols(grbuf, k, 4 * i + 3, count, t[2][1 + i] + sum);
        }
        storeCols(grbuf, k, 28, count, t[0][7]);
        storeCols(grbuf, k, 29, count, t[2][7] + t[3][7]);
        storeCols(grbuf, k, 30, count, t[1][7]);
        storeCols(grbuf, k, 31, count, t[3][7]);
    }
}

const V4 = @Vector(4, f32);

/// Windowing of two time slots for both channels: the 4 lanes are (left, right) of slots
/// 2i and 2i + 1, as interleaved in `lins`.
pub fn synth(x: *const [1152]f32, xl: usize, dst: []f32, dl: usize, nch: usize, lins: *[(18 + 15) * 64]f32, lo: usize) void {
    const xr = xl + 576 * (nch - 1);
    const dr = dl + (nch - 1);
    const zlin = lo + 15 * 64;
    lins[zlin + 4 * 15] = x[xl + 18 * 16];
    lins[zlin + 4 * 15 + 1] = x[xr + 18 * 16];
    lins[zlin + 4 * 15 + 2] = x[xl + 0];
    lins[zlin + 4 * 15 + 3] = x[xr + 0];
    lins[zlin + 4 * 31] = x[xl + 1 + 18 * 16];
    lins[zlin + 4 * 31 + 1] = x[xr + 1 + 18 * 16];
    lins[zlin + 4 * 31 + 2] = x[xl + 1];
    lins[zlin + 4 * 31 + 3] = x[xr + 1];
    synthPair(dst, dr, nch, lins, lo + 4 * 15 + 1);
    synthPair(dst, dr + 32 * nch, nch, lins, lo + 4 * 15 + 64 + 1);
    synthPair(dst, dl, nch, lins, lo + 4 * 15);
    synthPair(dst, dl + 32 * nch, nch, lins, lo + 4 * 15 + 64);

    const scale: V4 = @splat(1.0 / 32768.0);
    var ii: usize = 15;
    while (ii > 0) {
        ii -= 1;
        const i = ii;
        lins[zlin + 4 * i] = x[xl + 18 * (31 - i)];
        lins[zlin + 4 * i + 1] = x[xr + 18 * (31 - i)];
        lins[zlin + 4 * i + 2] = x[xl + 1 + 18 * (31 - i)];
        lins[zlin + 4 * i + 3] = x[xr + 1 + 18 * (31 - i)];
        lins[zlin + 4 * (i + 16)] = x[xl + 1 + 18 * (1 + i)];
        lins[zlin + 4 * (i + 16) + 1] = x[xr + 1 + 18 * (1 + i)];
        lins[zlin + 4 * i - 64 + 2] = x[xl + 18 * (1 + i)];
        lins[zlin + 4 * i - 64 + 3] = x[xr + 18 * (1 + i)];

        var a: V4 = undefined;
        var b: V4 = undefined;
        const w = T.synth_win[(14 - i) * 16 ..][0..16];
        inline for (0..8) |k| {
            const w0: V4 = @splat(w[2 * k]);
            const w1: V4 = @splat(w[2 * k + 1]);
            const vz: V4 = lins[zlin + 4 * i - k * 64 ..][0..4].*;
            const vy: V4 = lins[zlin + 4 * i - (15 - k) * 64 ..][0..4].*;
            if (k == 0) {
                b = vz * w1 + vy * w0;
                a = vz * w0 - vy * w1;
            } else if (k % 2 == 0) {
                b += vz * w1 + vy * w0;
                a += vz * w0 - vy * w1;
            } else {
                b += vz * w1 + vy * w0;
                a += vy * w1 - vz * w0;
            }
        }
        const pa: [4]f32 = a * scale;
        const pb: [4]f32 = b * scale;
        dst[dr + (15 - i) * nch] = pa[1];
        dst[dr + (17 + i) * nch] = pb[1];
        dst[dl + (15 - i) * nch] = pa[0];
        dst[dl + (17 + i) * nch] = pb[0];
        dst[dr + (47 - i) * nch] = pa[3];
        dst[dr + (49 + i) * nch] = pb[3];
        dst[dl + (47 - i) * nch] = pa[2];
        dst[dl + (49 + i) * nch] = pb[2];
    }
}

test "mp3 synthesis matches the scalar oracle" {
    var prng: std.Random.DefaultPrng = .init(3);
    const r = prng.random();
    for ([_]usize{ 1, 2 }) |nch| for ([_]usize{ 18, 12 }) |nbands| {
        var grbuf: [2][1152]f32 = undefined;
        var qmf: [2][15 * 64]f32 = undefined;
        var lins: [2][(18 + 15) * 64]f32 = @splat(@splat(0)); // as the decoder keeps it
        var pcm: [2][1152 * 2]f32 = undefined;
        for (&grbuf[0]) |*v| v.* = (r.float(f32) - 0.5) * 20000;
        for (&qmf[0]) |*v| v.* = (r.float(f32) - 0.5) * 2000;
        grbuf[1] = grbuf[0];
        qmf[1] = qmf[0];
        @memset(&pcm[0], 0);
        @memset(&pcm[1], 0);
        synthGranuleWith(false, &qmf[0], &grbuf[0], nbands, nch, &pcm[0], &lins[0]);
        synthGranuleWith(true, &qmf[1], &grbuf[1], nbands, nch, &pcm[1], &lins[1]);
        try std.testing.expectEqualSlices(f32, &pcm[1], &pcm[0]);
        try std.testing.expectEqualSlices(f32, &qmf[1], &qmf[0]);
    };
}
