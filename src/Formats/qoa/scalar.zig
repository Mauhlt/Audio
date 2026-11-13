//! Scalar slice encoder, a line-by-line copy of the reference `qoa_encode_frame` search.
//! `search.zig` must pick exactly the same slice; this is its test oracle.
const lms_mod = @import("lms.zig");
const Lms = lms_mod.Lms;

pub const SliceResult = struct { slice: u64, lms: Lms, sf: usize };
pub const Candidate = struct { slice: u64, lms: Lms, rank: u64 };

/// Encodes the slice with scale factor `sf`; null once the running rank exceeds `bound`
/// (the reference abandons the candidate there).
pub fn tryScaleFactor(pcm: []const i16, first: usize, stride: usize, len: usize, lms0: Lms, sf: usize, bound: u64) ?Candidate {
    var l = lms0;
    var slice: u64 = sf;
    var rank: u64 = 0;
    var i = first;
    for (0..len) |_| {
        const sample: i32 = pcm[i];
        i += stride;
        const predicted = l.predict();
        const residual = sample -% predicted;
        const scaled = lms_mod.div(residual, sf);
        const q = lms_mod.quant_tab[@intCast(@min(@max(scaled, -8), 8) + 8)];
        const dq = lms_mod.dequant_tab[sf][q];
        const r = lms_mod.clampS16(predicted +% dq);
        const penalty = lms_mod.weightsPenalty(l.weights);
        const e: i64 = sample - r;
        rank +%= @as(u64, @bitCast(e * e)) +% @as(u64, @bitCast(@as(i64, penalty)));
        if (rank > bound) return null;
        l.update(r, dq);
        slice = (slice << 3) | q;
    }
    return .{ .slice = slice, .lms = l, .rank = rank };
}

/// Tries every scale factor (starting from the previous one, which usually wins early) and
/// keeps the one with the lowest rank (squared error plus the weights penalty).
pub fn encodeSlice(pcm: []const i16, first: usize, stride: usize, len: usize, lms0: Lms, prev_sf: usize) SliceResult {
    var best: SliceResult = undefined;
    var best_rank: u64 = ~@as(u64, 0);
    for (0..16) |sfi| {
        const sf = (sfi + prev_sf) % 16;
        const c = tryScaleFactor(pcm, first, stride, len, lms0, sf, best_rank) orelse continue;
        if (c.rank < best_rank) {
            best_rank = c.rank;
            best = .{ .slice = c.slice, .lms = c.lms, .sf = sf };
        }
    }
    return best;
}
