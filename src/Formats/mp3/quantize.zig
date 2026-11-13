//! Layer III quantization, noise shaping and rate control for one granule of one channel.
//!
//! The decoder reconstructs band b as |x| = ix^(4/3) * 2^(E_b / 4) with
//!     E_b = global_gain - 214 - 2*ms - (sf_b << (scalefac_scale + 1)) - 8 * subblock_gain
//! (scale factor bands: 22 long, or 13 x 3 windows for short blocks; the last band of each has
//! no scale factor). The encoder inverts that with the usual rounding,
//!     ix = floor((|x| * 2^(-E_b / 4))^(3/4) + 0.4054)
//! Inner loop: binary search for the smallest global gain whose bits fit the budget.
//! Outer loop (with a psychoacoustic threshold): raise the scale factors of bands whose noise
//! is above their allowed noise until all are masked, nothing more can be done, or the
//! amplification limit is reached; keep the best result. Once everything is masked, raise the
//! global gain again as long as it stays masked, leaving the saved bits to the reservoir.
const std = @import("std");
const T = @import("tables.zig");
const huff = @import("huffman.zig");
const BitWriter = @import("bitwriter.zig");
pub const BlockType = @import("analysis.zig").BlockType;
const W = @import("../../Samples/misc.zig").N / 4;

/// Largest quantized value Layer III can code (15 + 2^13 - 1).
pub const MAX_IX = 8206;

/// ix^(4/3) for every codable ix.
pub const Pow43 = [MAX_IX + 1]f32;

pub fn pow43Table(t: *Pow43) void {
    for (t, 0..) |*v, i| v.* = @floatCast(std.math.pow(f64, @floatFromInt(i), 4.0 / 3.0));
}

/// Scale factor bands of a granule, in bitstream order.
pub const Bands = struct {
    n: u8,
    start: [39]u16,
    width: [39]u16,
    /// scale factor slot of the band (null: the top band, which has none)
    slot: [39]?u8,
    window: [39]u2,
    short: bool,

    /// 22 long bands from their 23 edges.
    pub fn long(edges: *const [23]u16) Bands {
        var b: Bands = .{ .n = 22, .start = undefined, .width = undefined, .slot = undefined, .window = @splat(0), .short = false };
        for (0..22) |i| {
            b.start[i] = edges[i];
            b.width[i] = edges[i + 1] - edges[i];
            b.slot[i] = if (i < 21) @intCast(i) else null;
        }
        return b;
    }

    /// 13 short bands x 3 windows, ordered band, then window (13 widths of one window).
    pub fn short_(widths: *const [13]u8) Bands {
        var b: Bands = .{ .n = 39, .start = undefined, .width = undefined, .slot = undefined, .window = undefined, .short = true };
        var pos: u16 = 0;
        for (0..13) |band| for (0..3) |w| {
            const i = 3 * band + w;
            b.start[i] = pos;
            b.width[i] = widths[band];
            b.slot[i] = if (band < 12) @intCast(i) else null;
            b.window[i] = @intCast(w);
            pos += widths[band];
        };
        return b;
    }
};

pub const Granule = struct {
    // side info
    part2_3_length: u16 = 0,
    big_values: u16 = 0,
    global_gain: u8 = 210,
    scalefac_compress: u16 = 0,
    block_type: BlockType = .normal,
    table_select: [3]u8 = .{ 0, 0, 0 },
    region0_count: u8 = 0,
    region1_count: u8 = 0,
    subblock_gain: [3]u3 = .{ 0, 0, 0 },
    scalefac_scale: u1 = 0,
    count1table_select: u1 = 0,
    // scale factors (slot = long band, or 3 * short band + window) and how they are coded
    sf: [36]u8 = @splat(0),
    slen: [4]u8 = @splat(0),
    counts: [4]u8 = @splat(0),
    part2_length: u16 = 0,
    // layout of the coded values
    region1_start: u16 = 0,
    region2_start: u16 = 0,
    count1_end: u16 = 0,
    ix: [576]u16 = @splat(0),
};

/// Region 0 / region 1 band counts by how many bands the big values span (ISO reference).
const subdv = [23][2]u8{
    .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 1 },
    .{ 1, 2 }, .{ 2, 2 }, .{ 2, 3 }, .{ 2, 3 }, .{ 3, 4 }, .{ 3, 4 }, .{ 3, 4 }, .{ 4, 5 },
    .{ 4, 5 }, .{ 4, 6 }, .{ 5, 6 }, .{ 5, 6 }, .{ 5, 7 }, .{ 6, 7 }, .{ 6, 7 },
};

/// Scale factor band edges (sample indices, 23 of them) of a long-block band table row.
pub fn bandEdges(row: []const u8) [23]u16 {
    var e: [23]u16 = undefined;
    e[0] = 0;
    for (0..22) |b| e[b + 1] = e[b] + row[b];
    return e;
}

/// |x|^(3/4), computed once per granule.
pub fn pow34(xr: *const [576]f32, out: *[576]f32) void {
    const V = @Vector(W, f32);
    var i: usize = 0;
    while (i < 576) : (i += W) {
        const a: V = @abs(@as(V, xr[i..][0..W].*));
        const p: V = @sqrt(a * @sqrt(a));
        out[i..][0..W].* = p;
    }
}

// ───────────────────────────── scale factor coding ─────────────────────────────

/// bits to code 0..n
fn bitsFor(n: u8) u8 {
    return if (n == 0) 0 else 8 - @clz(n);
}

/// The largest value each scale factor slot can take (for the amplification limit).
fn slotLimit(mpeg1: bool, short: bool, slot: usize) u8 {
    if (mpeg1) return if (slot < (if (short) @as(usize, 18) else 11)) 15 else 7;
    const first_two: usize = if (short) 18 else 11; // partitions {9,9,9,9} / {6,5,5,5}
    return if (slot < first_two) 15 else 7;
}

/// Picks the cheapest scalefac_compress for the current scale factors (null: they don't fit).
fn codeScalefactors(g: *Granule, mpeg1: bool) bool {
    const short = g.block_type == .short;
    if (mpeg1) {
        const n1: u8 = if (short) 18 else 11;
        const n2: u8 = if (short) 18 else 10;
        var m1: u8 = 0;
        var m2: u8 = 0;
        for (g.sf[0..n1]) |v| m1 = @max(m1, v);
        for (g.sf[n1..][0..n2]) |v| m2 = @max(m2, v);
        var best: ?u16 = null;
        var best_bits: u16 = std.math.maxInt(u16);
        for (T.scfc_decode, 0..) |part, c| {
            const s1 = part >> 2;
            const s2 = part & 3;
            if (bitsFor(m1) > s1 or bitsFor(m2) > s2) continue;
            const bits = @as(u16, n1) * s1 + @as(u16, n2) * s2;
            if (bits < best_bits) {
                best_bits = bits;
                best = @intCast(c);
            }
        }
        const c = best orelse return false;
        const part = T.scfc_decode[c];
        g.scalefac_compress = c;
        g.slen = .{ part >> 2, part >> 2, part & 3, part & 3 };
        g.counts = if (short) .{ 9, 9, 9, 9 } else .{ 6, 5, 5, 5 };
        g.part2_length = best_bits;
        return true;
    }
    // MPEG-2 (no intensity stereo, no preflag): four partitions, slen 0..4, 0..4, 0..3, 0..3
    g.counts = if (short) .{ 9, 9, 9, 9 } else .{ 6, 5, 5, 5 };
    var slot: usize = 0;
    var bits: u16 = 0;
    for (0..4) |p| {
        var m: u8 = 0;
        for (g.sf[slot..][0..g.counts[p]]) |v| m = @max(m, v);
        const s = bitsFor(m);
        if (s > (if (p < 2) @as(u8, 4) else 3)) return false;
        g.slen[p] = s;
        bits += @as(u16, g.counts[p]) * s;
        slot += g.counts[p];
    }
    g.scalefac_compress = ((@as(u16, g.slen[0]) * 5 + g.slen[1]) * 4 + g.slen[2]) * 4 + g.slen[3];
    g.part2_length = bits;
    return true;
}

// ───────────────────────────── quantization ─────────────────────────────

/// E_b for band b (see the file comment).
fn exponent(g: *const Granule, bands: *const Bands, b: usize, ms: bool) i32 {
    var e: i32 = @as(i32, g.global_gain) - 214 - @as(i32, if (ms) 2 else 0);
    if (bands.slot[b]) |s| e -= @as(i32, g.sf[s]) << (@as(u5, g.scalefac_scale) + 1);
    if (bands.short) e -= 8 * @as(i32, g.subblock_gain[bands.window[b]]);
    return e;
}

/// Quantizes every band with its own step; false if a value exceeds MAX_IX.
fn quantize(g: *Granule, bands: *const Bands, xr34: *const [576]f32, ms: bool) bool {
    const V = @Vector(W, f32);
    var q: [576]f32 = undefined;
    for (0..bands.n) |b| {
        const e: f32 = @floatFromInt(exponent(g, bands, b, ms));
        @memset(q[bands.start[b]..][0..bands.width[b]], std.math.exp2(-3.0 * e / 16.0));
    }
    const round: V = @splat(0.4054);
    const limit: V = @splat(MAX_IX);
    var i: usize = 0;
    while (i < 576) : (i += W) {
        const v = @floor(@as(V, xr34[i..][0..W].*) * @as(V, q[i..][0..W].*) + round);
        if (@reduce(.Or, v > limit)) return false;
        const u: @Vector(W, u32) = @intFromFloat(v);
        const t: @Vector(W, u16) = @truncate(u);
        g.ix[i..][0..W].* = t;
    }
    return true;
}

/// Splits the quantized values into big-values regions / count1 / zeros, picks tables, and
/// returns the Huffman bit count.
fn layout(g: *Granule, bands: *const Bands) u32 {
    var i: usize = 576;
    while (i >= 2 and g.ix[i - 1] == 0 and g.ix[i - 2] == 0) i -= 2;
    const nz_end = i;
    while (i >= 4 and g.ix[i - 1] <= 1 and g.ix[i - 2] <= 1 and g.ix[i - 3] <= 1 and g.ix[i - 4] <= 1) i -= 4;
    const bv_end = i;
    g.big_values = @intCast(bv_end / 2);
    g.count1_end = @intCast(nz_end);

    var r1_start: usize = undefined;
    var r2_start: usize = undefined;
    switch (g.block_type) {
        .normal => {
            var used: usize = 0;
            while (used < 22 and bands.start[used] < bv_end) used += 1;
            const r0 = subdv[used][0];
            const r1 = subdv[used][1];
            g.region0_count = r0;
            g.region1_count = r1;
            r1_start = if (r0 + 1 < 22) bands.start[r0 + 1] else 576;
            r2_start = if (r0 + r1 + 2 < 22) bands.start[r0 + r1 + 2] else 576;
        },
        // window switching: region 0 is 8 long bands / 9 short (band, window) entries, region 1
        // is the rest (the decoder fixes both)
        .start, .stop => {
            r1_start = bands.start[8];
            r2_start = 576;
        },
        .short => {
            r1_start = bands.start[9];
            r2_start = 576;
        },
    }
    r1_start = @min(r1_start, bv_end);
    r2_start = @min(r2_start, bv_end);
    g.region1_start = @intCast(r1_start);
    g.region2_start = @intCast(r2_start);

    var bits: u32 = 0;
    const regions = [3][2]usize{ .{ 0, r1_start }, .{ r1_start, r2_start }, .{ r2_start, bv_end } };
    for (regions, 0..) |r, k| {
        const c = huff.chooseBig(g.ix[r[0]..r[1]]);
        g.table_select[k] = c.table;
        bits += c.bits;
    }
    const a = huff.countQuads(0, g.ix[bv_end..nz_end]);
    const b = huff.countQuads(1, g.ix[bv_end..nz_end]);
    g.count1table_select = @intFromBool(b < a);
    bits += @min(a, b);
    return bits;
}

/// Inner loop: the smallest global gain whose Huffman bits fit `budget` (scale factors fixed).
fn innerLoop(g: *Granule, bands: *const Bands, xr34: *const [576]f32, ms: bool, budget: u32) void {
    var lo: u16 = 0;
    var hi: u16 = 255;
    while (lo < hi) {
        g.global_gain = @intCast((lo + hi) / 2);
        if (quantize(g, bands, xr34, ms) and layout(g, bands) <= budget) hi = g.global_gain else lo = g.global_gain + 1;
    }
    g.global_gain = @intCast(lo);
    if (!quantize(g, bands, xr34, ms)) @memset(&g.ix, 0);
    g.part2_3_length = @intCast(layout(g, bands) + g.part2_length);
    if (g.part2_3_length > budget + g.part2_length) { // even the coarsest step does not fit
        @memset(&g.ix, 0);
        g.part2_3_length = @intCast(layout(g, bands) + g.part2_length);
    }
}

const Distortion = struct {
    over: u32 = 0, // bands with audible noise
    over_db: f32 = 0, // their total excess, dB
    max_db: f32 = -1000, // worst band, dB above its allowed noise
    /// worse than every real result
    const worst: Distortion = .{ .over = std.math.maxInt(u32), .over_db = std.math.inf(f32), .max_db = std.math.inf(f32) };

    fn better(a: Distortion, b: Distortion) bool {
        if (a.over != b.over) return a.over < b.over;
        if (a.over > 0 and a.over_db != b.over_db) return a.over_db < b.over_db;
        return a.max_db < b.max_db;
    }
};

/// Noise vs allowed noise per band (bands without a scale factor can't be shaped: skipped).
fn distortion(g: *const Granule, bands: *const Bands, xr: *const [576]f32, xmin: []const f32, ms: bool, p43: *const Pow43, over: *[39]bool) Distortion {
    var d: Distortion = .{};
    for (0..bands.n) |b| {
        over[b] = false;
        if (bands.slot[b] == null) continue;
        const step = std.math.exp2(@as(f32, @floatFromInt(exponent(g, bands, b, ms))) / 4.0);
        var noise: f32 = 0;
        for (bands.start[b]..bands.start[b] + bands.width[b]) |i| {
            const e = @abs(xr[i]) - p43[g.ix[i]] * step;
            noise += e * e;
        }
        const db = 10 * std.math.log10(@max(noise, 1e-30) / @max(xmin[b], 1e-30));
        d.max_db = @max(d.max_db, db);
        if (db > 0) {
            over[b] = true;
            d.over += 1;
            d.over_db += db;
        }
    }
    return d;
}

pub const Request = struct {
    xr: *const [576]f32,
    xr34: *const [576]f32,
    bands: *const Bands,
    block_type: BlockType,
    ms: bool,
    mpeg1: bool,
    /// bits available for this granule (scale factors + Huffman), at most 4095
    max_bits: u32,
    /// allowed noise per band; null: no noise shaping, just fill `max_bits`
    xmin: ?[]const f32,
    pow43: *const Pow43,
};

pub fn encode(req: Request, g: *Granule) void {
    const max_bits = @min(req.max_bits, 4095);
    g.* = .{ .block_type = req.block_type };
    _ = codeScalefactors(g, req.mpeg1);
    const xmin = req.xmin orelse {
        innerLoop(g, req.bands, req.xr34, req.ms, max_bits -| g.part2_length);
        return;
    };

    var best = g.*;
    var best_d: Distortion = .worst;
    var over: [39]bool = undefined;
    for (0..32) |_| {
        if (g.part2_length >= max_bits) break;
        innerLoop(g, req.bands, req.xr34, req.ms, max_bits - g.part2_length);
        const d = distortion(g, req.bands, req.xr, xmin, req.ms, req.pow43, &over);
        if (d.better(best_d)) {
            best = g.*;
            best_d = d;
        }
        if (d.over == 0) break;
        // amplify the bands with audible noise by one scale factor step
        var next = g.*;
        var all = true;
        var changed = false;
        var overflow = false;
        for (0..req.bands.n) |b| {
            const s = req.bands.slot[b] orelse continue;
            if (!over[b]) {
                all = false;
                continue;
            }
            next.sf[s] += 1;
            changed = true;
            if (next.sf[s] > slotLimit(req.mpeg1, req.bands.short, s)) overflow = true;
        }
        if (!changed or all) break; // nothing to do / shaping no longer changes the balance
        if (overflow) {
            if (next.scalefac_scale == 1) break;
            next.scalefac_scale = 1; // coarser scale factor steps: halve them, rounding up
            for (&next.sf) |*v| v.* = (v.* + 1) / 2;
        }
        if (!codeScalefactors(&next, req.mpeg1)) break;
        g.* = next;
    }
    g.* = best;
    if (best_d.over != 0) return;
    // all masked: coarser steps while still masked save bits for the reservoir
    while (g.global_gain < 255) {
        var t = g.*;
        t.global_gain += 1;
        if (!quantize(&t, req.bands, req.xr34, req.ms)) break;
        t.part2_3_length = @intCast(layout(&t, req.bands) + t.part2_length);
        if (distortion(&t, req.bands, req.xr, xmin, req.ms, req.pow43, &over).over != 0) break;
        g.* = t;
    }
}

/// Main data of the granule: scale factors, then Huffman codes (signs from `xr`).
pub fn write(bw: *BitWriter, g: *const Granule, xr: *const [576]f32) void {
    var slot: usize = 0;
    for (g.counts, g.slen) |n, s| {
        for (g.sf[slot..][0..n]) |v| if (s != 0) bw.write(v, @intCast(s));
        slot += n;
    }
    var sign: [576]bool = undefined;
    for (&sign, xr) |*sg, x| sg.* = x < 0;
    const bv_end = @as(usize, g.big_values) * 2;
    const regions = [3][2]usize{ .{ 0, g.region1_start }, .{ g.region1_start, g.region2_start }, .{ g.region2_start, bv_end } };
    for (regions, 0..) |r, k| huff.writeBig(bw, g.table_select[k], g.ix[r[0]..r[1]], sign[r[0]..r[1]]);
    huff.writeQuads(bw, g.count1table_select, g.ix[bv_end..g.count1_end], sign[bv_end..g.count1_end]);
}

test "mp3 encoded granules decode through the decoder's scale factor and Huffman readers" {
    const l3 = @import("layer3.zig");
    const Bs = @import("bits.zig").Bs;
    const gpa = std.testing.allocator;
    const p43 = try gpa.create(Pow43);
    defer gpa.destroy(p43);
    pow43Table(p43);
    var prng: std.Random.DefaultPrng = .init(11);
    const r = prng.random();
    for (0..400) |iter| {
        const mpeg1 = iter % 2 == 0;
        const block_type: BlockType = @fromBackingInt(@intCast(iter / 2 % 4));
        const row: usize = if (mpeg1) 5 else 2; // 44.1 / 22.05 kHz
        const edges = bandEdges(&T.scf_long[row]);
        var short_widths: [13]u8 = undefined;
        for (&short_widths, 0..) |*sw, b| sw.* = T.scf_short[row][3 * b];
        const bands = if (block_type == .short) Bands.short_(&short_widths) else Bands.long(&edges);

        var xr: [576]f32 = undefined;
        const amp = std.math.pow(f32, 10, @floatFromInt(iter % 5));
        const top = 100 + r.uintLessThan(usize, 477);
        for (&xr, 0..) |*x, i| {
            const tilt = 1.0 / (1.0 + @as(f32, @floatFromInt(i)) / 30.0);
            x.* = if (i < top) (r.float(f32) - 0.5) * amp * tilt else 0;
        }
        var xr34: [576]f32 = undefined;
        pow34(&xr, &xr34);
        // random allowed noise: some bands strict, so the outer loop shapes
        var xmin: [39]f32 = undefined;
        for (xmin[0..bands.n], 0..) |*m, b| {
            var e: f32 = 0;
            for (xr[bands.start[b]..][0..bands.width[b]]) |v| e += v * v;
            m.* = e * std.math.pow(f32, 10, -(r.float(f32) * 40) / 10) + 1e-12;
        }
        var g: Granule = undefined;
        const budget = 400 + r.uintLessThan(u32, 3600);
        encode(.{ .xr = &xr, .xr34 = &xr34, .bands = &bands, .block_type = block_type, .ms = false, .mpeg1 = mpeg1, .max_bits = budget, .xmin = &xmin, .pow43 = p43 }, &g);
        try std.testing.expect(g.part2_3_length <= budget);

        var buf: [600]u8 = undefined;
        var bw: BitWriter = .init(&buf);
        write(&bw, &g, &xr);
        try std.testing.expectEqual(@as(usize, g.part2_3_length), bw.pos);

        // the decoder's view of this granule
        const hdr = if (mpeg1) [4]u8{ 0xFF, 0xFB, 0x90, 0xC4 } else [4]u8{ 0xFF, 0xF3, 0x90, 0xC4 };
        var gi: l3.GrInfo = .{
            .sfbtab = if (block_type == .short) &T.scf_short[row] else &T.scf_long[row],
            .part_23_length = g.part2_3_length,
            .big_values = g.big_values,
            .global_gain = g.global_gain,
            .scalefac_compress = g.scalefac_compress,
            .block_type = @backingInt(block_type),
            .table_select = g.table_select,
            .region_count = switch (block_type) {
                .normal => .{ g.region0_count, g.region1_count, 255 },
                .short => .{ 8, 255, 255 },
                else => .{ 7, 255, 255 },
            },
            .scalefac_scale = g.scalefac_scale,
            .count1_table = g.count1table_select,
            .n_long_sfb = if (block_type == .short) 0 else 22,
            .n_short_sfb = if (block_type == .short) 39 else 0,
        };
        var bs: Bs = .init(&buf);
        var ist_pos: [39]u8 = undefined;
        var scf: [40]f32 = undefined;
        l3.decodeScalefactors(&hdr, &ist_pos, &bs, &gi, &scf, 0);
        try std.testing.expectEqual(@as(i32, g.part2_length), bs.pos);
        var dst: [576]f32 = @splat(0);
        l3.huffman(&dst, &bs, &gi, &scf, @intCast(g.part2_3_length));
        _ = &gi;
        for (0..bands.n) |b| {
            const step = std.math.exp2(@as(f32, @floatFromInt(exponent(&g, &bands, b, false))) / 4.0);
            for (bands.start[b]..bands.start[b] + bands.width[b]) |i| {
                const want = l3.pow43(g.ix[i]) * step * @as(f32, if (xr[i] < 0 and g.ix[i] != 0) -1 else 1);
                try std.testing.expectApproxEqRel(want, dst[i], 1e-5);
            }
        }
    }
}
