//! Layer III: side info, scale factors, Huffman data, stereo processing, the hybrid
//! filterbank (alias reduction + IMDCT).
const std = @import("std");
const T = @import("tables.zig");
const Header = @import("header.zig").Header;
const bitreader = @import("bits.zig");
const Bs = bitreader.Bs;
const BitCache = bitreader.BitCache;
const oracle = @import("scalar.zig");
/// lanes per vector (a performance choice)
const W = @import("../../Samples/misc.zig").N / 4;

pub const SHORT_BLOCK_TYPE = 2;
pub const STOP_BLOCK_TYPE = 3;
const BITS_DEQUANTIZER_OUT = -1;
const MAX_SCF = 255 + BITS_DEQUANTIZER_OUT * 4 - 210;
const MAX_SCFI = (MAX_SCF + 3) & ~@as(i32, 3);

pub const GrInfo = struct {
    sfbtab: []const u8 = &T.scf_long[0],
    part_23_length: u16 = 0,
    big_values: u16 = 0,
    scalefac_compress: u16 = 0,
    global_gain: u8 = 0,
    block_type: u8 = 0,
    mixed_block_flag: u8 = 0,
    n_long_sfb: u8 = 0,
    n_short_sfb: u8 = 0,
    table_select: [3]u8 = @splat(0),
    region_count: [3]u8 = @splat(255),
    subblock_gain: [3]u8 = @splat(0),
    preflag: u8 = 0,
    scalefac_scale: u8 = 0,
    count1_table: u8 = 0,
    scfsi: u8 = 0,
};

pub fn readSideInfo(bs: *Bs, gr: *[4]GrInfo, hdr: []const u8) ?u32 {
    var tables: u32 = 0;
    var scfsi: u32 = 0;
    var main_data_begin: u32 = 0;
    var part_23_sum: i32 = 0;
    var gr_count: u5 = if (Header.isMono(hdr)) 1 else 2;
    var sr_idx: usize = Header.mySampleRate(hdr);
    sr_idx -= @intFromBool(sr_idx != 0);
    const mpeg1 = Header.isMpeg1(hdr);
    if (mpeg1) {
        gr_count *= 2;
        main_data_begin = bs.getBits(9);
        // private bits, then 4 scfsi bits per channel
        scfsi = bs.getBits(7 + @as(u32, gr_count)) & ((@as(u32, 1) << (gr_count * 2)) - 1);
    } else {
        main_data_begin = bs.getBits(8 + @as(u32, gr_count)) >> gr_count;
    }
    for (gr[0..gr_count]) |*g| {
        if (Header.isMono(hdr)) scfsi <<= 4;
        g.part_23_length = @intCast(bs.getBits(12));
        part_23_sum += g.part_23_length;
        g.big_values = @intCast(bs.getBits(9));
        if (g.big_values > 288) return null;
        g.global_gain = @intCast(bs.getBits(8));
        g.scalefac_compress = @intCast(bs.getBits(if (mpeg1) 4 else 9));
        g.sfbtab = &T.scf_long[sr_idx];
        g.n_long_sfb = 22;
        g.n_short_sfb = 0;
        if (bs.getBits(1) != 0) {
            g.block_type = @intCast(bs.getBits(2));
            if (g.block_type == 0) return null;
            g.mixed_block_flag = @intCast(bs.getBits(1));
            g.region_count = .{ 7, 255, 255 };
            if (g.block_type == SHORT_BLOCK_TYPE) {
                scfsi &= 0x0F0F;
                if (g.mixed_block_flag == 0) {
                    g.region_count[0] = 8;
                    g.sfbtab = &T.scf_short[sr_idx];
                    g.n_long_sfb = 0;
                    g.n_short_sfb = 39;
                } else {
                    g.sfbtab = &T.scf_mixed[sr_idx];
                    g.n_long_sfb = if (mpeg1) 8 else 6;
                    g.n_short_sfb = 30;
                }
            }
            tables = bs.getBits(10);
            tables <<= 5;
            for (&g.subblock_gain) |*sg| sg.* = @intCast(bs.getBits(3));
        } else {
            g.block_type = 0;
            g.mixed_block_flag = 0;
            tables = bs.getBits(15);
            g.region_count[0] = @intCast(bs.getBits(4));
            g.region_count[1] = @intCast(bs.getBits(3));
            g.region_count[2] = 255;
        }
        g.table_select = .{ @intCast(tables >> 10), @intCast((tables >> 5) & 31), @intCast(tables & 31) };
        g.preflag = if (mpeg1) @intCast(bs.getBits(1)) else @intFromBool(g.scalefac_compress >= 500);
        g.scalefac_scale = @intCast(bs.getBits(1));
        g.count1_table = @intCast(bs.getBits(1));
        g.scfsi = @intCast((scfsi >> 12) & 15);
        scfsi <<= 4;
    }
    if (part_23_sum + bs.pos > bs.limit + @as(i32, @intCast(main_data_begin)) * 8) return null;
    return main_data_begin;
}

pub fn readScalefactors(scf: []u8, ist_pos: []u8, scf_size: [4]u8, scf_count: []const u8, bs: *Bs, scfsi_in: i32) void {
    var scfsi = scfsi_in;
    var o: usize = 0;
    var i: usize = 0;
    while (i < 4 and scf_count[i] != 0) : ({
        i += 1;
        scfsi *%= 2;
    }) {
        const cnt = scf_count[i];
        if (scfsi & 8 != 0) {
            @memcpy(scf[o..][0..cnt], ist_pos[o..][0..cnt]);
        } else {
            const bits = scf_size[i];
            if (bits == 0) {
                @memset(scf[o..][0..cnt], 0);
                @memset(ist_pos[o..][0..cnt], 0);
            } else {
                const max_scf: i32 = if (scfsi < 0) (@as(i32, 1) << @intCast(bits)) - 1 else -1;
                for (0..cnt) |k| {
                    const s: i32 = @intCast(bs.getBits(bits));
                    ist_pos[o + k] = if (s == max_scf) 255 else @intCast(s);
                    scf[o + k] = @intCast(s);
                }
            }
        }
        o += cnt;
    }
    scf[o] = 0;
    scf[o + 1] = 0;
    scf[o + 2] = 0;
}

pub fn ldexpQ2(y_in: f32, exp_q2_in: i32) f32 {
    var y = y_in;
    var exp_q2 = exp_q2_in;
    while (true) {
        const e: i32 = std.math.clamp(exp_q2, 0, 30 * 4);
        const mul: i32 = @as(i32, 1 << 30) >> @intCast(e >> 2);
        y *= T.expfrac[@intCast(e & 3)] * @as(f32, @floatFromInt(mul));
        exp_q2 -= e;
        if (exp_q2 <= 0 or e == 0) break;
    }
    return y;
}

pub fn decodeScalefactors(hdr: []const u8, ist_pos: *[39]u8, bs: *Bs, gr: *const GrInfo, scf: *[40]f32, ch: usize) void {
    const part_row = &T.scf_partitions[@as(usize, @intFromBool(gr.n_short_sfb != 0)) + @intFromBool(gr.n_long_sfb == 0)];
    var scf_partition: []const u8 = part_row;
    var scf_size: [4]u8 = undefined;
    var iscf: [40]u8 = undefined;
    const scf_shift: u3 = @intCast(gr.scalefac_scale + 1);
    var scfsi: i32 = gr.scfsi;
    if (Header.isMpeg1(hdr)) {
        const part = T.scfc_decode[gr.scalefac_compress];
        scf_size[0] = part >> 2;
        scf_size[1] = part >> 2;
        scf_size[2] = part & 3;
        scf_size[3] = part & 3;
    } else {
        const ist: u1 = @intFromBool(Header.isIStereo(hdr) and ch != 0);
        var sfc: i32 = gr.scalefac_compress >> ist;
        var k: usize = @as(usize, ist) * 3 * 4;
        while (sfc >= 0) : (k += 4) {
            var modprod: i32 = 1;
            var i: usize = 4;
            while (i > 0) {
                i -= 1;
                const m: i32 = T.scf_mod[k + i];
                scf_size[i] = @intCast(@mod(@divTrunc(sfc, modprod), m));
                modprod *= m;
            }
            sfc -= modprod;
        }
        scf_partition = part_row[k..];
        scfsi = -16;
    }
    readScalefactors(&iscf, ist_pos, scf_size, scf_partition, bs, scfsi);
    const nl = gr.n_long_sfb;
    if (gr.n_short_sfb != 0) {
        const sh: u3 = 3 - scf_shift;
        var i: usize = 0;
        while (i < gr.n_short_sfb) : (i += 3) {
            iscf[nl + i + 0] +%= gr.subblock_gain[0] << sh;
            iscf[nl + i + 1] +%= gr.subblock_gain[1] << sh;
            iscf[nl + i + 2] +%= gr.subblock_gain[2] << sh;
        }
    } else if (gr.preflag != 0) {
        for (0..10) |i| iscf[11 + i] +%= T.preamp[i];
    }
    const gain_exp: i32 = @as(i32, gr.global_gain) + BITS_DEQUANTIZER_OUT * 4 - 210 - @as(i32, if (Header.isMsStereo(hdr)) 2 else 0);
    const gain = ldexpQ2(@floatFromInt(@as(i32, 1) << (MAX_SCFI / 4)), MAX_SCFI - gain_exp);
    for (0..@as(usize, nl) + gr.n_short_sfb) |i| {
        scf[i] = ldexpQ2(gain, @as(i32, iscf[i]) << scf_shift);
    }
}

pub fn pow43(x_in: i32) f32 {
    if (x_in < 129) return T.pow43[@intCast(16 + x_in)];
    var x = x_in;
    var mult: f32 = 256;
    if (x < 1024) {
        mult = 16;
        x <<= 3;
    }
    const sign: i32 = 2 * x & 64;
    const frac: f32 = @as(f32, @floatFromInt((x & 63) - sign)) / @as(f32, @floatFromInt((x & ~@as(i32, 63)) + sign));
    return T.pow43[@intCast(16 + ((x + sign) >> 6))] * (1 + frac * ((4.0 / 3.0) + frac * (2.0 / 9.0))) * mult;
}

pub fn huffman(dst: *[576]f32, bs: *Bs, gr: *const GrInfo, scf: []const f32, layer3gr_limit: i32) void {
    var one: f32 = 0;
    var ireg: usize = 0;
    var big_val_cnt: i32 = gr.big_values;
    const sfb = gr.sfbtab;
    var sfb_i: usize = 0;
    var scf_i: usize = 0;
    var d: usize = 0;
    const start: usize = @intCast(bs.pos >> 3);
    var br: BitCache = .{ .buf = bs.buf, .next = start, .cache = 0, .sh = (bs.pos & 7) - 8 };
    br.cache = ((((br.byte(start) * 256 + br.byte(start + 1)) * 256 + br.byte(start + 2)) * 256 + br.byte(start + 3))) << @intCast(bs.pos & 7);
    br.next += 4;
    defer bs.pos = layer3gr_limit;

    while (big_val_cnt > 0) {
        if (ireg >= 3) return;
        const tab_num = gr.table_select[ireg];
        var sfb_cnt: i32 = gr.region_count[ireg];
        ireg += 1;
        const codebook = T.huff_tabs[@intCast(T.tabindex[tab_num])..];
        const linbits: u32 = T.linbits[tab_num];
        while (true) {
            const np: i32 = sfb[sfb_i] / 2;
            sfb_i += 1;
            if (np == 0) return; // corrupt: more big values than the band table holds
            var pairs = @min(big_val_cnt, np);
            one = scf[scf_i];
            scf_i += 1;
            while (pairs > 0) : (pairs -= 1) {
                var w: u32 = 5;
                var leaf: i32 = codebook[br.peek(w)];
                while (leaf < 0) {
                    br.flush(w);
                    w = @intCast(leaf & 7);
                    leaf = codebook[@intCast(@as(i32, @intCast(br.peek(w))) - (leaf >> 3))];
                }
                br.flush(@intCast(leaf >> 8));
                for (0..2) |_| {
                    var lsb: i32 = leaf & 0x0F;
                    if (linbits != 0 and lsb == 15) {
                        lsb += @intCast(br.peek(linbits));
                        br.flush(linbits);
                        br.check();
                        dst[d] = one * pow43(lsb) * @as(f32, if (br.negative()) -1 else 1);
                    } else {
                        dst[d] = T.pow43[@intCast(16 + lsb - 16 * @as(i32, @intCast(br.cache >> 31)))] * one;
                    }
                    br.flush(@intFromBool(lsb != 0));
                    d += 1;
                    leaf >>= 4;
                }
                br.check();
            }
            big_val_cnt -= np;
            if (big_val_cnt <= 0) break;
            sfb_cnt -= 1;
            if (sfb_cnt < 0) break;
        }
    }

    var np: i32 = 1 - big_val_cnt;
    const codebook_count1: []const u8 = if (gr.count1_table != 0) &T.tab33 else &T.tab32;
    while (d + 4 <= 576) : (d += 4) {
        var leaf: u32 = codebook_count1[br.peek(4)];
        if (leaf & 8 == 0) {
            const c4: u32 = br.cache << 4;
            leaf = codebook_count1[(leaf >> 3) + @as(u32, @truncate(@as(u64, c4) >> @intCast(32 - (leaf & 3))))];
        }
        br.flush(leaf & 7);
        if (br.bitPos() > layer3gr_limit) break;
        // reload scale factor every pair
        np -= 1;
        if (np == 0) {
            np = sfb[sfb_i] / 2;
            sfb_i += 1;
            if (np == 0) break;
            one = scf[scf_i];
            scf_i += 1;
        }
        inline for (0..2) |s| {
            if (leaf & (128 >> s) != 0) {
                dst[d + s] = if (br.negative()) -one else one;
                br.flush(1);
            }
        }
        np -= 1;
        if (np == 0) {
            np = sfb[sfb_i] / 2;
            sfb_i += 1;
            if (np == 0) break;
            one = scf[scf_i];
            scf_i += 1;
        }
        inline for (2..4) |s| {
            if (leaf & (128 >> s) != 0) {
                dst[d + s] = if (br.negative()) -one else one;
                br.flush(1);
            }
        }
        br.check();
    }
}

pub fn midsideStereo(buf: *[1152]f32, off: usize, n: usize) void {
    const V = @Vector(W, f32);
    var i = off;
    while (i + W <= off + n) : (i += W) {
        const a: V = buf[i..][0..W].*;
        const b: V = buf[i + 576 ..][0..W].*;
        buf[i..][0..W].* = a + b;
        buf[i + 576 ..][0..W].* = a - b;
    }
    for (i..off + n) |k| {
        const a = buf[k];
        const b = buf[k + 576];
        buf[k] = a + b;
        buf[k + 576] = a - b;
    }
}

pub fn intensityStereoBand(buf: *[1152]f32, off: usize, n: usize, kl: f32, kr: f32) void {
    for (off..off + n) |i| {
        buf[i + 576] = buf[i] * kr;
        buf[i] = buf[i] * kl;
    }
}

pub fn stereoTopBand(buf: *const [1152]f32, sfb: []const u8, nbands: usize, max_band: *[3]i32) void {
    max_band.* = .{ -1, -1, -1 };
    var r: usize = 576;
    for (0..nbands) |i| {
        var k: usize = 0;
        while (k < sfb[i]) : (k += 2) {
            if (buf[r + k] != 0 or buf[r + k + 1] != 0) {
                max_band[i % 3] = @intCast(i);
                break;
            }
        }
        r += sfb[i];
    }
}

pub fn stereoProcess(buf: *[1152]f32, ist_pos: *const [39]u8, sfb: []const u8, hdr: []const u8, max_band: *const [3]i32, mpeg2_sh: u5) void {
    const mpeg1 = Header.isMpeg1(hdr);
    const max_pos: u32 = if (mpeg1) 7 else 64;
    var off: usize = 0;
    var i: usize = 0;
    while (sfb[i] != 0) : (i += 1) {
        const ipos: u32 = ist_pos[i];
        if (@as(i32, @intCast(i)) > max_band[i % 3] and ipos < max_pos) {
            const s: f32 = if (Header.isMsStereo(hdr)) 1.41421356 else 1;
            var kl: f32 = undefined;
            var kr: f32 = undefined;
            if (mpeg1) {
                kl = T.pan[2 * ipos];
                kr = T.pan[2 * ipos + 1];
            } else {
                kl = 1;
                kr = ldexpQ2(1, @intCast((ipos + 1) >> 1 << mpeg2_sh));
                if (ipos & 1 != 0) {
                    kl = kr;
                    kr = 1;
                }
            }
            intensityStereoBand(buf, off, sfb[i], kl * s, kr * s);
        } else if (Header.isMsStereo(hdr)) {
            midsideStereo(buf, off, sfb[i]);
        }
        off += sfb[i];
    }
}

pub fn intensityStereo(buf: *[1152]f32, ist_pos: *[39]u8, gr: *const [2]GrInfo, hdr: []const u8) void {
    var max_band: [3]i32 = undefined;
    const n_sfb: usize = @as(usize, gr[0].n_long_sfb) + gr[0].n_short_sfb;
    const max_blocks: usize = if (gr[0].n_short_sfb != 0) 3 else 1;
    stereoTopBand(buf, gr[0].sfbtab, n_sfb, &max_band);
    if (gr[0].n_long_sfb != 0) {
        const m = @max(max_band[0], max_band[1], max_band[2]);
        max_band = .{ m, m, m };
    }
    for (0..max_blocks) |i| {
        const default_pos: u8 = if (Header.isMpeg1(hdr)) 3 else 0;
        const itop = n_sfb - max_blocks + i;
        const prev = itop - max_blocks;
        ist_pos[itop] = if (max_band[i] >= @as(i32, @intCast(prev))) default_pos else ist_pos[prev];
    }
    stereoProcess(buf, ist_pos, gr[0].sfbtab, hdr, &max_band, @intCast(gr[1].scalefac_compress & 1));
}

pub fn reorder(buf: *[1152]f32, off: usize, scratch: []f32, sfb: []const u8) void {
    var src = off;
    var dst: usize = 0;
    var i: usize = 0;
    while (sfb[i] != 0) : (i += 3) {
        const len = sfb[i];
        for (0..len) |_| {
            scratch[dst + 0] = buf[src + 0 * len];
            scratch[dst + 1] = buf[src + 1 * len];
            scratch[dst + 2] = buf[src + 2 * len];
            dst += 3;
            src += 1;
        }
        src += 2 * len;
    }
    @memcpy(buf[off..][0..dst], scratch[0..dst]);
}

const rev8 = [8]i32{ 7, 6, 5, 4, 3, 2, 1, 0 };

/// Alias reduction butterflies between neighbouring subbands: the 8 per boundary are one
/// 8-lane vector (a width the algorithm dictates).
pub fn antialias(buf: *[1152]f32, off: usize, nbands: i32) void {
    const V = @Vector(8, f32);
    const cs: V = T.aa[0];
    const ca: V = T.aa[1];
    var b = off;
    var n = nbands;
    while (n > 0) : ({
        n -= 1;
        b += 18;
    }) {
        const u: V = buf[b + 18 ..][0..8].*;
        const d: V = @shuffle(f32, @as(V, buf[b + 10 ..][0..8].*), undefined, rev8); // buf[b + 17 - i]
        buf[b + 18 ..][0..8].* = u * cs - d * ca;
        buf[b + 10 ..][0..8].* = @shuffle(f32, u * ca + d * cs, undefined, rev8);
    }
}

pub fn dct3_9(y: *[9]f32) void {
    var s0 = y[0];
    var s2 = y[2];
    var s4 = y[4];
    var s6 = y[6];
    var s8 = y[8];
    var t0 = s0 + s6 * 0.5;
    s0 -= s6;
    var t4 = (s4 + s2) * 0.93969262;
    var t2 = (s8 + s2) * 0.76604444;
    s6 = (s4 - s8) * 0.17364818;
    s4 += s8 - s2;
    s2 = s0 - s4 * 0.5;
    y[4] = s4 + s0;
    s8 = t0 - t2 + s6;
    s0 = t0 - t4 + t2;
    s4 = t0 + t4 - s6;
    var s1 = y[1];
    var s3 = y[3];
    var s5 = y[5];
    var s7 = y[7];
    s3 *= 0.86602540;
    t0 = (s5 + s1) * 0.98480775;
    t4 = (s5 - s7) * 0.34202014;
    t2 = (s1 + s7) * 0.64278761;
    s1 = (s1 - s5 - s7) * 0.86602540;
    s5 = t0 - s3 - t2;
    s7 = t4 - s3 - t0;
    s3 = t4 + s3 - t2;
    y[0] = s4 - s7;
    y[1] = s2 + s1;
    y[2] = s0 - s3;
    y[3] = s8 + s5;
    y[5] = s8 - s5;
    y[6] = s0 + s3;
    y[7] = s2 - s1;
    y[8] = s4 + s7;
}

const VB = @Vector(W, f32);

/// `dct3_9` on W bands at once (lane = band).
fn dct3_9V(y: *[9]VB) void {
    const k = struct {
        inline fn f(x: f32) VB {
            return @splat(x);
        }
    }.f;
    var s0 = y[0];
    var s2 = y[2];
    var s4 = y[4];
    var s6 = y[6];
    var s8 = y[8];
    var t0 = s0 + s6 * k(0.5);
    s0 -= s6;
    var t4 = (s4 + s2) * k(0.93969262);
    var t2 = (s8 + s2) * k(0.76604444);
    s6 = (s4 - s8) * k(0.17364818);
    s4 += s8 - s2;
    s2 = s0 - s4 * k(0.5);
    y[4] = s4 + s0;
    s8 = t0 - t2 + s6;
    s0 = t0 - t4 + t2;
    s4 = t0 + t4 - s6;
    var s1 = y[1];
    var s3 = y[3];
    var s5 = y[5];
    var s7 = y[7];
    s3 *= k(0.86602540);
    t0 = (s5 + s1) * k(0.98480775);
    t4 = (s5 - s7) * k(0.34202014);
    t2 = (s1 + s7) * k(0.64278761);
    s1 = (s1 - s5 - s7) * k(0.86602540);
    s5 = t0 - s3 - t2;
    s7 = t4 - s3 - t0;
    s3 = t4 + s3 - t2;
    y[0] = s4 - s7;
    y[1] = s2 + s1;
    y[2] = s0 - s3;
    y[3] = s8 + s5;
    y[5] = s8 - s5;
    y[6] = s0 + s3;
    y[7] = s2 - s1;
    y[8] = s4 + s7;
}

/// 36-point IMDCT + window + overlap-add of `nbands` long-block subbands, W bands per
/// vector (bit-identical to the scalar oracle: every band does the same operations).
pub fn imdct36(grbuf: []f32, overlap: []f32, window: *const [18]f32, nbands: usize) void {
    var j: usize = 0;
    while (j + W <= nbands) : (j += W) {
        var g: [18]VB = undefined;
        var ov: [9]VB = undefined;
        inline for (0..W) |lane| {
            for (0..18) |idx| g[idx][lane] = grbuf[(j + lane) * 18 + idx];
            for (0..9) |idx| ov[idx][lane] = overlap[(j + lane) * 9 + idx];
        }
        var co: [9]VB = undefined;
        var si: [9]VB = undefined;
        co[0] = -g[0];
        si[0] = g[17];
        for (0..4) |i| {
            si[8 - 2 * i] = g[4 * i + 1] - g[4 * i + 2];
            co[1 + 2 * i] = g[4 * i + 1] + g[4 * i + 2];
            si[7 - 2 * i] = g[4 * i + 4] - g[4 * i + 3];
            co[2 + 2 * i] = -(g[4 * i + 3] + g[4 * i + 4]);
        }
        dct3_9V(&co);
        dct3_9V(&si);
        si[1] = -si[1];
        si[3] = -si[3];
        si[5] = -si[5];
        si[7] = -si[7];
        var out: [18]VB = undefined;
        for (0..9) |i| {
            const tw0: VB = @splat(T.twid9[0 + i]);
            const tw1: VB = @splat(T.twid9[9 + i]);
            const w0: VB = @splat(window[0 + i]);
            const w1: VB = @splat(window[9 + i]);
            const ovl = ov[i];
            const sum = co[i] * tw1 + si[i] * tw0;
            ov[i] = co[i] * tw0 - si[i] * tw1;
            out[i] = ovl * w0 - sum * w1;
            out[17 - i] = ovl * w1 + sum * w0;
        }
        inline for (0..W) |lane| {
            for (0..18) |idx| grbuf[(j + lane) * 18 + idx] = out[idx][lane];
            for (0..9) |idx| overlap[(j + lane) * 9 + idx] = ov[idx][lane];
        }
    }
    oracle.imdct36(grbuf[j * 18 ..], overlap[j * 9 ..], window, nbands - j);
}

pub fn idct3(x0: f32, x1: f32, x2: f32, dst: *[3]f32) void {
    const m1 = x1 * 0.86602540;
    const a1 = x0 - x2 * 0.5;
    dst[1] = x0 + x2;
    dst[0] = a1 + m1;
    dst[2] = a1 - m1;
}

pub fn imdct12(x: []const f32, dst: []f32, overlap: []f32) void {
    var co: [3]f32 = undefined;
    var si: [3]f32 = undefined;
    idct3(-x[0], x[6] + x[3], x[12] + x[9], &co);
    idct3(x[15], x[12] - x[9], x[6] - x[3], &si);
    si[1] = -si[1];
    for (0..3) |i| {
        const ovl = overlap[i];
        const sum = co[i] * T.twid3[3 + i] + si[i] * T.twid3[0 + i];
        overlap[i] = co[i] * T.twid3[0 + i] - si[i] * T.twid3[3 + i];
        dst[i] = ovl * T.twid3[2 - i] - sum * T.twid3[5 - i];
        dst[5 - i] = ovl * T.twid3[5 - i] + sum * T.twid3[2 - i];
    }
}

pub fn imdctShort(grbuf: []f32, overlap: []f32, nbands: usize) void {
    for (0..nbands) |j| {
        const g = grbuf[j * 18 ..][0..18];
        const ov = overlap[j * 9 ..][0..9];
        const tmp: [18]f32 = g.*;
        @memcpy(g[0..6], ov[0..6]);
        imdct12(tmp[0..], g[6..], ov[6..]);
        imdct12(tmp[1..], g[12..], ov[6..]);
        imdct12(tmp[2..], ov[0..], ov[6..]);
    }
}

pub fn changeSign(grbuf: *[576]f32) void {
    var b: usize = 0;
    while (b < 32) : (b += 2) {
        const base = 18 + b * 18;
        var i: usize = 1;
        while (i < 18) : (i += 2) grbuf[base + i] = -grbuf[base + i];
    }
}

pub fn imdctGr(grbuf: *[576]f32, overlap: *[288]f32, block_type: u8, n_long_bands: usize) void {
    if (n_long_bands != 0) imdct36(grbuf, overlap, &T.mdct_window[0], n_long_bands);
    const g = grbuf[18 * n_long_bands ..];
    const ov = overlap[9 * n_long_bands ..];
    if (block_type == SHORT_BLOCK_TYPE) {
        imdctShort(g, ov, 32 - n_long_bands);
    } else {
        imdct36(g, ov, &T.mdct_window[@intFromBool(block_type == STOP_BLOCK_TYPE)], 32 - n_long_bands);
    }
}

test "mp3 layer III kernels match the scalar oracle" {
    var prng: std.Random.DefaultPrng = .init(9);
    const r = prng.random();
    var a: [1152]f32 = undefined;
    for (&a) |*v| v.* = (r.float(f32) - 0.5) * 1000;
    var b = a;
    antialias(&a, 576, 31);
    oracle.antialias(&b, 576, 31);
    try std.testing.expectEqualSlices(f32, &b, &a);
    midsideStereo(&a, 3, 573);
    oracle.midsideStereo(&b, 3, 573);
    try std.testing.expectEqualSlices(f32, &b, &a);
    for ([_]usize{ 32, 30, 31, 3 }) |nb| {
        var ova: [288]f32 = undefined;
        for (&ova) |*v| v.* = (r.float(f32) - 0.5) * 100;
        var ovb = ova;
        imdct36(a[0..576], &ova, &T.mdct_window[0], nb);
        oracle.imdct36(b[0..576], &ovb, &T.mdct_window[0], nb);
        try std.testing.expectEqualSlices(f32, &b, &a);
        try std.testing.expectEqualSlices(f32, &ovb, &ova);
    }
}
