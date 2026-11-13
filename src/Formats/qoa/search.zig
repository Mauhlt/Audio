//! Vector slice encoder: scale factor candidates run 8 at a time, one per lane, and pick
//! exactly the slice the reference's sequential search picks.
//!
//! The reference tries candidates in the order prev_sf, prev_sf + 1, ... (mod 16) and abandons
//! one as soon as its running rank exceeds the best finished rank so far. Ranks are 64-bit
//! wrapping sums (the weights penalty can wrap negative), so a running rank is not always
//! increasing; each lane therefore tracks the highest running rank it reached, and a
//! candidate is abandoned exactly when that maximum exceeds the best rank before it.
//!
//! Pass 1 runs the 8 candidates nearest prev_sf (j = -3 .. 4, where the winner almost always
//! is) to the end. Its first lane is the first candidate, which is never abandoned: every
//! later candidate is compared against a best rank <= its final rank r0. Pass 2 runs the
//! other 8 and stops as soon as all of them have exceeded r0, which usually takes a sample
//! or two: they are all abandoned then.
const std = @import("std");
const lms_mod = @import("lms.zig");
const Lms = lms_mod.Lms;
const scalar = @import("scalar.zig");
const SliceResult = scalar.SliceResult;

const L = 8; // lanes per channel

/// Candidate order offsets j (sf = (prev_sf + j) % 16) of each pass's lanes.
const near = [L]usize{ 0, 1, 2, 3, 4, 13, 14, 15 };
const far = [L]usize{ 5, 6, 7, 8, 9, 10, 11, 12 };

inline fn ones(comptime W: usize, b: @Vector(W, bool)) @Vector(W, i32) {
    return @select(i32, b, @as(@Vector(W, i32), @splat(1)), @as(@Vector(W, i32), @splat(0)));
}

/// -1, 0 or 1 per lane.
inline fn sign(comptime W: usize, v: @Vector(W, i32)) @Vector(W, i32) {
    const zero: @Vector(W, i32) = @splat(0);
    return ones(W, v > zero) - ones(W, v < zero);
}

const Lanes = struct {
    rank: [L]u64,
    max_rank: [L]u64,
    slice: [L]u64,
    history: [4][L]i32,
    weights: [4][L]i32,
    sf: [L]i32,
};

/// One channel's slice: where its samples are and the state it starts from.
const Job = struct { first: usize, lms0: Lms, prev_sf: usize };

/// Encodes `G` channels' slices with `L` scale factors each, all at once (G * L lanes; the
/// channels are independent, so G = 2 gives the CPU two dependency chains to overlap).
/// With `exit_bound` (G = 1 only), returns null as soon as every lane's running rank has
/// exceeded it.
fn run(comptime G: usize, pcm: []const i16, stride: usize, len: usize, jobs: [G]Job, offsets: [L]usize, exit_bound: ?u64) ?[G]Lanes {
    const W = G * L;
    const V = @Vector(W, i32);
    const VU = @Vector(W, u64);
    const VI64 = @Vector(W, i64);
    const splat = struct {
        inline fn f(x: i32) V {
            return @splat(x);
        }
    }.f;
    var sf_arr: [W]i32 = undefined;
    var rec_arr: [W]i32 = undefined;
    var dq_arr: [4][W]i32 = undefined; // |dequantized| for quantized value 2m (odd = negative)
    var h_arr: [4][W]i32 = undefined;
    var w_arr: [4][W]i32 = undefined;
    for (jobs, 0..) |job, g| for (offsets, 0..) |j, k| {
        const lane = g * L + k;
        const sf = (job.prev_sf + j) % 16;
        sf_arr[lane] = @intCast(sf);
        rec_arr[lane] = lms_mod.reciprocal_tab[sf];
        for (0..4) |m| dq_arr[m][lane] = lms_mod.dequant_tab[sf][2 * m];
        for (0..4) |t| {
            h_arr[t][lane] = job.lms0.history[t];
            w_arr[t][lane] = job.lms0.weights[t];
        }
    };
    const group1 = comptime blk: { // lanes of the second channel
        var m: [W]bool = @splat(false);
        for (L..W) |k| m[k] = true;
        break :blk m;
    };
    const rec: V = rec_arr;
    const dq0: V = dq_arr[0];
    const dq1: V = dq_arr[1];
    const dq2: V = dq_arr[2];
    const dq3: V = dq_arr[3];
    const bound: VU = @splat(exit_bound orelse 0);

    var h: [4]V = .{ h_arr[0], h_arr[1], h_arr[2], h_arr[3] };
    var w: [4]V = .{ w_arr[0], w_arr[1], w_arr[2], w_arr[3] };
    var slice: VU = @intCast(@as(@Vector(W, u32), @bitCast(@as(V, sf_arr))));
    var rank: VU = @splat(0);
    var max_rank: VU = @splat(0);

    for (0..len) |t| {
        const sample: V = if (G == 1)
            splat(pcm[jobs[0].first + t * stride])
        else
            @select(i32, @as(@Vector(W, bool), group1), splat(pcm[jobs[1].first + t * stride]), splat(pcm[jobs[0].first + t * stride]));
        const predicted = (w[0] *% h[0] +% w[1] *% h[1] +% w[2] *% h[2] +% w[3] *% h[3]) >> @splat(13);
        const residual = sample -% predicted;
        const n = (residual *% rec +% splat(1 << 15)) >> @splat(16);
        const scaled = n +% sign(W, residual) -% sign(W, n);
        const c = @min(@max(scaled, splat(-8)), splat(8));
        // quant_tab as arithmetic: q = min(|c| & ~1, 6) | (c < 0)
        const mag: V = @min(@as(V, @intCast(@abs(c))) & splat(~@as(i32, 1)), splat(6));
        const neg = c < splat(0);
        const q = mag | ones(W, neg);
        const m = mag >> @splat(1);
        const dq_abs = @select(i32, m == splat(0), dq0, @select(i32, m == splat(1), dq1, @select(i32, m == splat(2), dq2, dq3)));
        const dq = @select(i32, neg, splat(0) -% dq_abs, dq_abs);
        const r = @min(@max(predicted +% dq, splat(-32768)), splat(32767));

        // rank += error^2 + penalty (penalty in the reference's wrapping 32-bit int)
        const sum = w[0] *% w[0] +% w[1] *% w[1] +% w[2] *% w[2] +% w[3] *% w[3];
        const p = @max(splat(0), (sum >> @splat(18)) -% splat(0x8ff));
        const pp: VI64 = @intCast(p *% p); // sign-extends, like C's int -> uint64
        const e = @abs(sample - r); // <= 65535, so e * e fits in u32
        rank +%= @as(VU, @intCast(e * e)) +% @as(VU, @bitCast(pp));
        max_rank = @max(max_rank, rank);
        if (exit_bound != null and @reduce(.And, max_rank > bound)) return null;

        // LMS update
        const delta = dq >> @splat(4);
        inline for (0..4) |k| w[k] +%= @select(i32, h[k] < splat(0), splat(0) -% delta, delta);
        h = .{ h[1], h[2], h[3], r };
        slice = (slice << @splat(3)) | @as(VU, @intCast(@as(@Vector(W, u32), @bitCast(q))));
    }
    const ranks: [W]u64 = rank;
    const maxes: [W]u64 = max_rank;
    const slices: [W]u64 = slice;
    var out: [G]Lanes = undefined;
    for (&out, 0..) |*o, g| {
        const lo = g * L;
        o.rank = ranks[lo..][0..L].*;
        o.max_rank = maxes[lo..][0..L].*;
        o.slice = slices[lo..][0..L].*;
        o.sf = sf_arr[lo..][0..L].*;
        for (0..4) |k| {
            const hk: [W]i32 = h[k];
            const wk: [W]i32 = w[k];
            o.history[k] = hk[lo..][0..L].*;
            o.weights[k] = wk[lo..][0..L].*;
        }
    }
    return out;
}

/// Replays the reference's sequential choice over j = 0..15, given pass 1 (`a`) and pass 2
/// (`b`, null if it exited early: then all its candidates were abandoned).
fn pick(a: *const Lanes, b: ?*const Lanes) SliceResult {
    var best_rank: u64 = ~@as(u64, 0);
    var best_pass: *const Lanes = a;
    var best_lane: usize = 0;
    for (0..16) |j| {
        var pass: *const Lanes = a;
        var lane: usize = undefined;
        if (std.mem.indexOfScalar(usize, &near, j)) |k| {
            lane = k;
        } else {
            pass = b orelse continue;
            lane = std.mem.indexOfScalar(usize, &far, j).?;
        }
        if (pass.max_rank[lane] > best_rank) continue; // abandoned early
        if (pass.rank[lane] < best_rank) {
            best_rank = pass.rank[lane];
            best_pass = pass;
            best_lane = lane;
        }
    }
    var out: SliceResult = .{ .slice = best_pass.slice[best_lane], .lms = undefined, .sf = @intCast(best_pass.sf[best_lane]) };
    for (0..4) |k| {
        out.lms.history[k] = best_pass.history[k][best_lane];
        out.lms.weights[k] = best_pass.weights[k][best_lane];
    }
    return out;
}

pub fn encodeSlice(pcm: []const i16, first: usize, stride: usize, len: usize, lms0: Lms, prev_sf: usize) SliceResult {
    const job: Job = .{ .first = first, .lms0 = lms0, .prev_sf = prev_sf };
    const a = run(1, pcm, stride, len, .{job}, near, null).?[0];
    const b = run(1, pcm, stride, len, .{job}, far, a.rank[0]);
    return pick(&a, if (b) |*bb| &bb[0] else null);
}

/// Two channels' slices at once (same position, independent predictors).
pub fn encodeSlicePair(pcm: []const i16, first: [2]usize, stride: usize, len: usize, lms0: [2]Lms, prev_sf: [2]usize) [2]SliceResult {
    const jobs = [2]Job{
        .{ .first = first[0], .lms0 = lms0[0], .prev_sf = prev_sf[0] },
        .{ .first = first[1], .lms0 = lms0[1], .prev_sf = prev_sf[1] },
    };
    const a = run(2, pcm, stride, len, jobs, near, null).?;
    var out: [2]SliceResult = undefined;
    for (&out, jobs, &a) |*o, job, *ag| {
        const b = run(1, pcm, stride, len, .{job}, far, ag.rank[0]);
        o.* = pick(ag, if (b) |*bb| &bb[0] else null);
    }
    return out;
}

test "QOA - vector slice search matches the scalar reference" {
    var prng: std.Random.DefaultPrng = .init(0xA0);
    const r = prng.random();
    var pcm: [40]i16 = undefined;
    for (0..20_000) |iter| {
        // quiet, loud, noisy and clipped material; random predictor states, some extreme
        const amp: i32 = switch (iter % 4) {
            0 => 50,
            1 => 3000,
            2 => 20000,
            else => 32767,
        };
        const base: i32 = r.intRangeAtMost(i32, -amp, amp);
        for (&pcm) |*s| s.* = @intCast(std.math.clamp(base + r.intRangeAtMost(i32, -amp, amp), -32768, 32767));
        var l: Lms = .initial;
        for (&l.history) |*x| x.* = r.int(i16);
        for (&l.weights) |*x| x.* = if (iter % 7 == 0) r.int(i32) else r.int(i16);
        const len = if (iter % 5 == 0) r.intRangeAtMost(usize, 1, 20) else 20;
        const stride: usize = if (iter % 2 == 0) 1 else 2;
        const prev = r.uintLessThan(usize, 16);
        const a = encodeSlice(&pcm, 0, stride, len, l, prev);
        const b = scalar.encodeSlice(&pcm, 0, stride, len, l, prev);
        try std.testing.expectEqual(b.sf, a.sf);
        try std.testing.expectEqual(b.slice, a.slice);
        try std.testing.expectEqual(b.lms, a.lms);
        if (stride == 2) {
            var l2 = l;
            l2.weights[3] +%= 77;
            const pair = encodeSlicePair(&pcm, .{ 0, 1 }, 2, len, .{ l, l2 }, .{ prev, (prev + 5) % 16 });
            const c = scalar.encodeSlice(&pcm, 1, 2, len, l2, (prev + 5) % 16);
            try std.testing.expectEqual(b, pair[0]);
            try std.testing.expectEqual(c, pair[1]);
        }
    }
}
