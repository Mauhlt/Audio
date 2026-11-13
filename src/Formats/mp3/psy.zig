//! Psychoacoustic model: how much quantization noise each scale factor band can hide.
//!
//! Works on the encoder's own MDCT spectrum (no separate FFT), per granule and channel:
//!   1. band energies e[b] (long blocks: 22 bands; short: 13 bands x 3 windows)
//!   2. spreading across bands on the Bark scale (Schroeder's spreading function, each row
//!      normalized so a flat spectrum keeps its level)
//!   3. masking offset by tonality: tonal bands (low spectral flatness) mask less
//!      (14.5 + bark dB below), noise-like bands more (5.5 dB below)
//!   4. the absolute threshold of hearing (Terhardt), with a full-scale sine taken as 96 dB SPL
//!      (calibrated by running a full-scale sine through the same analysis)
//!   5. pre-echo control for long blocks: a threshold may grow at most 2x per granule
//! The result is the allowed noise energy per band (`xmin`), and the perceptual entropy: an
//! estimate of the bits a granule needs, which steers the bit reservoir.
//!
//! `attack` is the transient detector for block switching (time domain, high-passed energy).
const std = @import("std");
const analysis = @import("analysis.zig");
const V32 = analysis.V32;

pub const N_LONG = 22;
pub const N_SHORT = 13;

const full_scale_spl = 96.0;

fn bark(hz: f64) f64 {
    return 13.0 * std.math.atan(0.00076 * hz) + 3.5 * std.math.atan(std.math.pow(f64, hz / 7500.0, 2));
}

/// Threshold in quiet, dB SPL (Terhardt).
fn athDb(hz_in: f64) f64 {
    const f = @max(hz_in, 20) / 1000.0;
    return 3.64 * std.math.pow(f64, f, -0.8) - 6.5 * @exp(-0.6 * (f - 3.3) * (f - 3.3)) + 1e-3 * std.math.pow(f64, f, 4);
}

/// Schroeder's spreading function, as a power ratio, for a masker dz Bark below the maskee.
fn spread(dz: f64) f64 {
    const x = dz + 0.474;
    const db = 15.81 + 7.5 * x - 17.5 * @sqrt(1 + x * x);
    return std.math.pow(f64, 10, db / 10);
}

fn Layout(comptime n: usize) type {
    return struct {
        start: [n]u16, // first line (within one window for short blocks)
        width: [n]u16,
        bark: [n]f32,
        ath: [n]f32, // allowed noise energy in quiet
        spread: [n][n]f32, // spread[b][j]: share of band j's energy that masks band b
    };
}

pub const Psy = struct {
    long: Layout(N_LONG),
    short: Layout(N_SHORT),
    /// last long-block threshold per channel, for pre-echo control
    prev: [2][N_LONG]f32,
    have_prev: [2]bool = .{ false, false },
    /// last short window's threshold per channel (temporal limit across windows)
    prev_short: [2][N_SHORT]f32 = undefined,
    have_prev_short: [2]bool = .{ false, false },
    /// energy of a short window relative to a long granule (calibration)
    short_ratio: f32 = 1.0 / 3.0,

    /// `long_edges`: 23 band edges of a long granule; `short_widths`: 13 band widths of one
    /// short window.
    pub fn init(sample_rate: u32, long_edges: *const [23]u16, short_widths: *const [13]u8) Psy {
        var p: Psy = .{ .long = undefined, .short = undefined, .prev = undefined };
        const refs = calibrate();
        const nyquist: f64 = @as(f64, @floatFromInt(sample_rate)) / 2;
        var long_starts: [N_LONG]u16 = undefined;
        var long_widths: [N_LONG]u16 = undefined;
        for (0..N_LONG) |b| {
            long_starts[b] = long_edges[b];
            long_widths[b] = long_edges[b + 1] - long_edges[b];
        }
        fill(N_LONG, &p.long, &long_starts, &long_widths, nyquist / 576, refs.long);
        var short_starts: [N_SHORT]u16 = undefined;
        var short_w: [N_SHORT]u16 = undefined;
        var edge: u16 = 0;
        for (0..N_SHORT) |b| {
            short_starts[b] = edge;
            short_w[b] = short_widths[b];
            edge += short_widths[b];
        }
        fill(N_SHORT, &p.short, &short_starts, &short_w, nyquist / 192, refs.short);
        p.short_ratio = @floatCast(refs.short / refs.long);
        return p;
    }

    fn fill(comptime n: usize, l: *Layout(n), starts: *const [n]u16, widths: *const [n]u16, hz_per_line: f64, ref: f64) void {
        for (0..n) |b| {
            l.start[b] = starts[b];
            l.width[b] = widths[b];
            const lo = @as(f64, @floatFromInt(starts[b])) * hz_per_line;
            const hi = @as(f64, @floatFromInt(starts[b] + widths[b])) * hz_per_line;
            l.bark[b] = @floatCast(bark((lo + hi) / 2));
            // quietest point of the band: a tone there at the threshold in quiet
            var ath = athDb(lo);
            var f = lo;
            while (f < hi) : (f += hz_per_line) ath = @min(ath, athDb(f));
            l.ath[b] = @floatCast(ref * std.math.pow(f64, 10, (ath - full_scale_spl) / 10));
        }
        for (0..n) |b| {
            var sum: f64 = 0;
            for (0..n) |j| sum += spread(l.bark[b] - l.bark[j]);
            for (0..n) |j| l.spread[b][j] = @floatCast(spread(l.bark[b] - l.bark[j]) / sum);
        }
    }

    /// Energy a full-scale 1 kHz sine puts into one long granule / one short window.
    fn calibrate() struct { long: f64, short: f64 } {
        const w = analysis.window();
        var x: [576 * 5 + 512]f32 = undefined;
        for (&x, 0..) |*v, i| v.* = @floatCast(@sin(2 * std.math.pi * 1000.0 * @as(f64, @floatFromInt(i)) / 44100.0));
        var slots: [36]V32 = undefined;
        for (&slots, 0..) |*s, t| {
            const slot = 36 + t; // steady state
            const a = analysis.analyzeSlot(&w, x[32 * slot ..]);
            s.* = if (slot % 2 == 1) a * analysis.odd_subbands else a;
        }
        var xr: [576]f32 = undefined;
        analysis.hybrid(&slots, .normal, &.{}, &xr);
        var long: f64 = 0;
        for (xr) |v| long += v * v;
        const widths = [13]u8{ 4, 4, 4, 4, 6, 8, 10, 12, 14, 18, 22, 30, 56 };
        analysis.hybrid(&slots, .short, &widths, &xr);
        var short: f64 = 0;
        for (xr) |v| short += v * v;
        return .{ .long = long, .short = short / 3 };
    }

    /// Allowed noise per long band for channel `ch`; returns the perceptual entropy.
    pub fn longThresholds(self: *Psy, ch: usize, xr: *const [576]f32, xmin: *[N_LONG]f32) f32 {
        const l = &self.long;
        var e: [N_LONG]f32 = undefined;
        var offset: [N_LONG]f32 = undefined;
        for (0..N_LONG) |b| {
            const lines = xr[l.start[b]..][0..l.width[b]];
            e[b] = energy(lines);
            offset[b] = maskOffsetDb(lines, e[b], l.bark[b]);
        }
        var pe: f32 = 0;
        for (0..N_LONG) |b| {
            var c: f32 = 0;
            for (0..N_LONG) |j| c += e[j] * l.spread[b][j];
            var thr = @max(c * std.math.pow(f32, 10, -offset[b] / 10), l.ath[b]);
            if (self.have_prev[ch]) thr = @min(thr, 2 * self.prev[ch][b]);
            thr = @max(thr, l.ath[b]);
            self.prev[ch][b] = thr;
            xmin[b] = thr;
            pe += entropy(e[b], thr, l.width[b]);
        }
        self.have_prev[ch] = true;
        self.have_prev_short[ch] = false;
        return pe;
    }

    /// Allowed noise per short band and window (`xmin[3 * b + w]`) from a spectrum in short-
    /// block bitstream order; returns the perceptual entropy.
    pub fn shortThresholds(self: *Psy, ch: usize, xr: *const [576]f32, xmin: *[3 * N_SHORT]f32) f32 {
        const l = &self.short;
        var pe: f32 = 0;
        // temporal limit: a window's threshold may be at most 2x the previous window's, the
        // first one chained to the previous granule (a long one mapped onto short bands)
        var prev: [N_SHORT]f32 = undefined;
        var have_prev = self.have_prev_short[ch];
        if (have_prev) {
            prev = self.prev_short[ch];
        } else if (self.have_prev[ch]) {
            have_prev = true;
            for (0..N_SHORT) |b| {
                const lo = 3 * @as(u32, l.start[b]);
                const hi = lo + 3 * @as(u32, l.width[b]);
                var t: f32 = 0;
                for (0..N_LONG) |lb| {
                    const a = @max(lo, self.long.start[lb]);
                    const z = @min(hi, @as(u32, self.long.start[lb]) + self.long.width[lb]);
                    if (z > a) t += self.prev[ch][lb] * @as(f32, @floatFromInt(z - a)) / @as(f32, @floatFromInt(self.long.width[lb]));
                }
                prev[b] = t * self.short_ratio;
            }
        }
        for (0..3) |w| {
            var e: [N_SHORT]f32 = undefined;
            var offset: [N_SHORT]f32 = undefined;
            for (0..N_SHORT) |b| {
                const lines = xr[3 * l.start[b] + w * l.width[b] ..][0..l.width[b]];
                e[b] = energy(lines);
                offset[b] = maskOffsetDb(lines, e[b], l.bark[b]);
            }
            for (0..N_SHORT) |b| {
                var c: f32 = 0;
                for (0..N_SHORT) |j| c += e[j] * l.spread[b][j];
                var thr = @max(c * std.math.pow(f32, 10, -offset[b] / 10), l.ath[b]);
                if (have_prev) thr = @max(@min(thr, 2 * prev[b]), l.ath[b]);
                xmin[3 * b + w] = thr;
                pe += entropy(e[b], thr, l.width[b]);
            }
            for (0..N_SHORT) |b| prev[b] = xmin[3 * b + w];
            have_prev = true;
        }
        self.prev_short[ch] = prev;
        self.have_prev_short[ch] = true;
        // after short blocks, long-block pre-echo control starts over
        self.have_prev[ch] = false;
        return pe;
    }
};

fn energy(lines: []const f32) f32 {
    var s: f32 = 0;
    for (lines) |v| s += v * v;
    return s;
}

/// dB the masking threshold sits below the spread energy: interpolated between tone-masking-
/// noise (14.5 + bark) and noise-masking-tone (5.5) by the band's spectral flatness.
fn maskOffsetDb(lines: []const f32, e: f32, z: f32) f32 {
    if (e <= 0 or lines.len < 2) return 5.5;
    var log_sum: f32 = 0;
    const floor = e / @as(f32, @floatFromInt(lines.len)) * 1e-6;
    for (lines) |v| log_sum += @log(v * v + floor);
    const gm = @exp(log_sum / @as(f32, @floatFromInt(lines.len)));
    const am = e / @as(f32, @floatFromInt(lines.len));
    const sfm_db = 10 * @log10(@max(gm / am, 1e-12));
    // MDCT lines of noise already scatter (about -2.5 dB flatness): scale so that is "noise"
    const tonality = std.math.clamp((-sfm_db - 2.5) / 25.0, 0, 1);
    return tonality * (14.5 + z) + (1 - tonality) * 5.5;
}

/// Bits a band needs to bring its noise under the threshold: 1/2 log2(e / thr) per line.
fn entropy(e: f32, thr: f32, width: u16) f32 {
    if (e <= thr) return 0;
    return 0.5 * @as(f32, @floatFromInt(width)) * std.math.log2(e / thr);
}

/// True if the region that granule `g`'s short windows would cover holds an attack: a 64-sample
/// block of high-passed signal with 10x (10 dB) the average energy of the 512 samples before it.
/// `x` is the padded channel input the analysis reads (granule g's MDCT is centred 256 samples
/// after its slots begin, at 576 g + 448 .. 576 g + 1216).
pub fn attack(x: []const f32, g: usize) bool {
    const sub = 64;
    const first = 576 * g + 448;
    var k: usize = 0;
    while (k < 12) : (k += 1) {
        const at = first + k * sub;
        if (at < 512 + 1 or at + sub > x.len) continue;
        const now = hpEnergy(x[at - 1 .. at + sub]);
        const before = hpEnergy(x[at - 513 .. at]) / 8;
        if (now > 10 * before and now > 1e-5) return true;
    }
    return false;
}

/// Energy of the first difference (a gentle high-pass) of `x[1..]`.
fn hpEnergy(x: []const f32) f32 {
    var s: f32 = 0;
    for (1..x.len) |i| {
        const d = x[i] - x[i - 1];
        s += d * d;
    }
    return s;
}

test "mp3 psychoacoustic model basics" {
    const T = @import("tables.zig");
    const quant = @import("quantize.zig");
    const edges = quant.bandEdges(&T.scf_long[5]);
    var short_widths: [13]u8 = undefined;
    for (&short_widths, 0..) |*sw, b| sw.* = T.scf_short[5][3 * b];
    var p: Psy = .init(44100, &edges, &short_widths);
    // the threshold in quiet is lowest around 3-4 kHz
    var lowest: usize = 0;
    for (0..N_LONG) |b| if (p.long.ath[b] / @as(f32, @floatFromInt(p.long.width[b])) < p.long.ath[lowest] / @as(f32, @floatFromInt(p.long.width[lowest]))) {
        lowest = b;
    };
    const hz = @as(f32, @floatFromInt(edges[lowest])) * 22050 / 576;
    try std.testing.expect(hz > 2000 and hz < 5000);

    // a loud tone masks its neighbours: their threshold rises well above quiet
    var xr: [576]f32 = @splat(0);
    xr[40] = 1;
    var xmin: [N_LONG]f32 = undefined;
    const pe = p.longThresholds(0, &xr, &xmin);
    try std.testing.expect(pe > 0);
    var b40: usize = 0;
    while (edges[b40 + 1] <= 40) b40 += 1;
    try std.testing.expect(xmin[b40 + 1] > 100 * p.long.ath[b40 + 1]);
    try std.testing.expect(xmin[b40] < 1); // the tone itself is not masked away

    // attack detection: silence then a click
    var x: [576 * 4 + 2048]f32 = @splat(0);
    for (0..x.len) |i| x[i] = 0.01 * @sin(@as(f32, @floatFromInt(i)) * 0.05);
    try std.testing.expect(!attack(&x, 1));
    x[576 + 800] = 0.9;
    try std.testing.expect(attack(&x, 1));
}
