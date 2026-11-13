//! Test oracle: the original one-value-at-a-time Layer III and synthesis kernels (a
//! straight port of minimp3's scalar code). The vector kernels in layer3.zig and
//! synth.zig must give bit-identical results.
const std = @import("std");
const T = @import("tables.zig");
const synthPair = @import("synth.zig").synthPair;
const scalePcm = @import("synth.zig").scalePcm;
const dct3_9 = @import("layer3.zig").dct3_9;

pub fn dctII(grbuf: []f32, n: usize) void {
    for (0..n) |k| {
        var t: [4][8]f32 = undefined;
        for (0..8) |i| {
            const x0 = grbuf[k + i * 18];
            const x1 = grbuf[k + (15 - i) * 18];
            const x2 = grbuf[k + (16 + i) * 18];
            const x3 = grbuf[k + (31 - i) * 18];
            const t0 = x0 + x3;
            const t1 = x1 + x2;
            const t2 = (x1 - x2) * T.sec[3 * i + 0];
            const t3 = (x0 - x3) * T.sec[3 * i + 1];
            t[0][i] = t0 + t1;
            t[1][i] = (t0 - t1) * T.sec[3 * i + 2];
            t[2][i] = t3 + t2;
            t[3][i] = (t3 - t2) * T.sec[3 * i + 2];
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
            var xt: f32 = undefined;
            xt = x0 - x7;
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
            x[4] = (x0 - x1) * 0.70710677;
            x5 = x5 + x6;
            x6 = (x6 + x7) * 0.70710677;
            x7 = x7 + xt;
            x3 = (x3 + x4) * 0.70710677;
            x5 -= x7 * 0.198912367;
            x7 += x5 * 0.382683432;
            x5 -= x7 * 0.198912367;
            x0 = xt - x6;
            xt += x6;
            x[1] = (xt + x7) * 0.50979561;
            x[2] = (x4 + x3) * 0.54119611;
            x[3] = (x0 - x5) * 0.60134488;
            x[5] = (x0 + x5) * 0.89997619;
            x[6] = (x4 - x3) * 1.30656302;
            x[7] = (xt - x7) * 2.56291556;
        }
        var y = k;
        for (0..7) |i| {
            // same association as minimp3's SSE path
            const s = t[3][i] + t[3][i + 1];
            grbuf[y + 0 * 18] = t[0][i];
            grbuf[y + 1 * 18] = t[2][i] + s;
            grbuf[y + 2 * 18] = t[1][i] + t[1][i + 1];
            grbuf[y + 3 * 18] = t[2][1 + i] + s;
            y += 4 * 18;
        }
        grbuf[y + 0 * 18] = t[0][7];
        grbuf[y + 1 * 18] = t[2][7] + t[3][7];
        grbuf[y + 2 * 18] = t[1][7];
        grbuf[y + 3 * 18] = t[3][7];
    }
}

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

        var a: [4]f32 = undefined;
        var b: [4]f32 = undefined;
        const w = T.synth_win[(14 - i) * 16 ..][0..16];
        inline for (0..8) |k| {
            const w0 = w[2 * k];
            const w1 = w[2 * k + 1];
            const vz = zlin + 4 * i - k * 64;
            const vy = zlin + 4 * i - (15 - k) * 64;
            for (0..4) |j| {
                const z = lins[vz + j];
                const y = lins[vy + j];
                if (k == 0) {
                    b[j] = z * w1 + y * w0;
                    a[j] = z * w0 - y * w1;
                } else if (k % 2 == 0) {
                    b[j] += z * w1 + y * w0;
                    a[j] += z * w0 - y * w1;
                } else {
                    b[j] += z * w1 + y * w0;
                    a[j] += y * w1 - z * w0;
                }
            }
        }
        dst[dr + (15 - i) * nch] = scalePcm(a[1]);
        dst[dr + (17 + i) * nch] = scalePcm(b[1]);
        dst[dl + (15 - i) * nch] = scalePcm(a[0]);
        dst[dl + (17 + i) * nch] = scalePcm(b[0]);
        dst[dr + (47 - i) * nch] = scalePcm(a[3]);
        dst[dr + (49 + i) * nch] = scalePcm(b[3]);
        dst[dl + (47 - i) * nch] = scalePcm(a[2]);
        dst[dl + (49 + i) * nch] = scalePcm(b[2]);
    }
}

pub fn midsideStereo(buf: *[1152]f32, off: usize, n: usize) void {
    for (off..off + n) |i| {
        const a = buf[i];
        const b = buf[i + 576];
        buf[i] = a + b;
        buf[i + 576] = a - b;
    }
}

pub fn antialias(buf: *[1152]f32, off: usize, nbands: i32) void {
    var b = off;
    var n = nbands;
    while (n > 0) : ({
        n -= 1;
        b += 18;
    }) {
        for (0..8) |i| {
            const u = buf[b + 18 + i];
            const d = buf[b + 17 - i];
            buf[b + 18 + i] = u * T.aa[0][i] - d * T.aa[1][i];
            buf[b + 17 - i] = u * T.aa[1][i] + d * T.aa[0][i];
        }
    }
}

pub fn imdct36(grbuf: []f32, overlap: []f32, window: *const [18]f32, nbands: usize) void {
    for (0..nbands) |j| {
        const g = grbuf[j * 18 ..][0..18];
        const ov = overlap[j * 9 ..][0..9];
        var co: [9]f32 = undefined;
        var si: [9]f32 = undefined;
        co[0] = -g[0];
        si[0] = g[17];
        for (0..4) |i| {
            si[8 - 2 * i] = g[4 * i + 1] - g[4 * i + 2];
            co[1 + 2 * i] = g[4 * i + 1] + g[4 * i + 2];
            si[7 - 2 * i] = g[4 * i + 4] - g[4 * i + 3];
            co[2 + 2 * i] = -(g[4 * i + 3] + g[4 * i + 4]);
        }
        dct3_9(&co);
        dct3_9(&si);
        si[1] = -si[1];
        si[3] = -si[3];
        si[5] = -si[5];
        si[7] = -si[7];
        for (0..9) |i| {
            const ovl = ov[i];
            const sum = co[i] * T.twid9[9 + i] + si[i] * T.twid9[0 + i];
            ov[i] = co[i] * T.twid9[0 + i] - si[i] * T.twid9[9 + i];
            g[i] = ovl * window[0 + i] - sum * window[9 + i];
            g[17 - i] = ovl * window[9 + i] + sum * window[0 + i];
        }
    }
}
