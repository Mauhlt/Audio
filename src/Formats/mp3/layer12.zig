//! Layer I and II: bit allocation, scale factors and sample dequantization.
const std = @import("std");
const T = @import("tables.zig");
const header = @import("header.zig");
const Header = header.Header;
const MODE_MONO = header.MODE_MONO;
const MODE_JOINT_STEREO = header.MODE_JOINT_STEREO;
const Bs = @import("bits.zig").Bs;

pub const L12ScaleInfo = struct {
    scf: [3 * 64]f32,
    total_bands: u8,
    stereo_bands: u8,
    bitalloc: [64]u8,
    scfcod: [64]u8,
};

pub const SubbandAlloc = struct { tab_offset: u8, code_tab_width: u8, band_count: u8 };

pub fn l12SubbandAllocTable(hdr: []const u8, sci: *L12ScaleInfo) []const SubbandAlloc {
    const mode = Header.stereoMode(hdr);
    const stereo_bands: u32 = if (mode == MODE_MONO) 0 else if (mode == MODE_JOINT_STEREO) (@as(u32, Header.stereoModeExt(hdr)) << 2) + 4 else 32;
    var alloc: []const SubbandAlloc = undefined;
    var nbands: u32 = undefined;
    if (Header.isLayer1(hdr)) {
        alloc = &.{.{ .tab_offset = 76, .code_tab_width = 4, .band_count = 32 }};
        nbands = 32;
    } else if (!Header.isMpeg1(hdr)) {
        alloc = &.{ .{ .tab_offset = 60, .code_tab_width = 4, .band_count = 4 }, .{ .tab_offset = 44, .code_tab_width = 3, .band_count = 7 }, .{ .tab_offset = 44, .code_tab_width = 2, .band_count = 19 } };
        nbands = 30;
    } else {
        const sample_rate_idx = Header.sampleRateIdx(hdr);
        var kbps = Header.bitrateKbps(hdr) >> @intFromBool(mode != MODE_MONO);
        if (kbps == 0) kbps = 192;
        alloc = &.{ .{ .tab_offset = 0, .code_tab_width = 4, .band_count = 3 }, .{ .tab_offset = 16, .code_tab_width = 4, .band_count = 8 }, .{ .tab_offset = 32, .code_tab_width = 3, .band_count = 12 }, .{ .tab_offset = 40, .code_tab_width = 2, .band_count = 7 } };
        nbands = 27;
        if (kbps < 56) {
            alloc = &.{ .{ .tab_offset = 44, .code_tab_width = 4, .band_count = 2 }, .{ .tab_offset = 44, .code_tab_width = 3, .band_count = 10 } };
            nbands = if (sample_rate_idx == 2) 12 else 8;
        } else if (kbps >= 96 and sample_rate_idx != 1) {
            nbands = 30;
        }
    }
    sci.total_bands = @intCast(nbands);
    sci.stereo_bands = @intCast(@min(stereo_bands, nbands));
    return alloc;
}

pub const deq_l12: [18 * 3]f32 = blk: {
    const div = [18]f32{ 3, 7, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767, 65535, 3, 5, 9 };
    var t: [18 * 3]f32 = undefined;
    for (div, 0..) |x, i| {
        t[3 * i + 0] = @as(f32, 9.53674316e-07) / x;
        t[3 * i + 1] = @as(f32, 7.56931807e-07) / x;
        t[3 * i + 2] = @as(f32, 6.00777173e-07) / x;
    }
    break :blk t;
};

pub fn l12ReadScalefactors(bs: *Bs, pba: []const u8, scfcod: []const u8, bands: usize, scf: []f32) void {
    var o: usize = 0;
    for (0..bands) |i| {
        var s: f32 = 0;
        const ba: u32 = pba[i];
        const mask: u32 = if (ba != 0) 4 + ((@as(u32, 19) >> @intCast(scfcod[i])) & 3) else 0;
        var m: u32 = 4;
        while (m != 0) : (m >>= 1) {
            if (mask & m != 0) {
                const b = bs.getBits(6);
                s = deq_l12[ba * 3 - 6 + b % 3] * @as(f32, @floatFromInt(@as(i32, 1 << 21) >> @intCast(b / 3)));
            }
            scf[o] = s;
            o += 1;
        }
    }
}

pub fn l12ReadScaleInfo(hdr: []const u8, bs: *Bs, sci: *L12ScaleInfo) void {
    const subband_alloc = l12SubbandAllocTable(hdr, sci);
    var sa: usize = 0;
    var k: usize = 0;
    var ba_bits: u32 = 0;
    var ba_code_tab: []const u8 = &T.bitalloc_code_tab;
    for (0..sci.total_bands) |i| {
        if (i == k) {
            k += subband_alloc[sa].band_count;
            ba_bits = subband_alloc[sa].code_tab_width;
            ba_code_tab = T.bitalloc_code_tab[subband_alloc[sa].tab_offset..];
            sa += 1;
        }
        var ba = ba_code_tab[bs.getBits(ba_bits)];
        sci.bitalloc[2 * i] = ba;
        if (i < sci.stereo_bands) ba = ba_code_tab[bs.getBits(ba_bits)];
        sci.bitalloc[2 * i + 1] = if (sci.stereo_bands != 0) ba else 0;
    }
    for (0..2 * @as(usize, sci.total_bands)) |i| {
        sci.scfcod[i] = if (sci.bitalloc[i] != 0) (if (Header.isLayer1(hdr)) 2 else @intCast(bs.getBits(2))) else 6;
    }
    l12ReadScalefactors(bs, &sci.bitalloc, &sci.scfcod, @as(usize, sci.total_bands) * 2, &sci.scf);
    for (sci.stereo_bands..sci.total_bands) |i| sci.bitalloc[2 * i + 1] = 0;
}

pub fn l12DequantizeGranule(grbuf: *[1152]f32, off: usize, bs: *Bs, sci: *const L12ScaleInfo, group_size: usize) usize {
    for (0..4) |j| {
        const base = off + group_size * j;
        for (0..2 * @as(usize, sci.total_bands)) |i| {
            const dst = base + (i >> 1) * 18 + (i & 1) * 576;
            const ba: u32 = sci.bitalloc[i];
            if (ba == 0) continue;
            if (ba < 17) {
                const half: i32 = (@as(i32, 1) << @intCast(ba - 1)) - 1;
                for (0..group_size) |kk| grbuf[dst + kk] = @floatFromInt(@as(i32, @intCast(bs.getBits(ba))) - half);
            } else {
                const mod: u32 = (@as(u32, 2) << @intCast(ba - 17)) + 1;
                var code = bs.getBits(mod + 2 - (mod >> 3));
                for (0..group_size) |kk| {
                    grbuf[dst + kk] = @floatFromInt(@as(i32, @intCast(code % mod)) - @as(i32, @intCast(mod / 2)));
                    code /= mod;
                }
            }
        }
    }
    return group_size * 4;
}

pub fn l12ApplyScf384(sci: *const L12ScaleInfo, scf: []const f32, dst: *[1152]f32) void {
    const sb: usize = sci.stereo_bands;
    const tb: usize = sci.total_bands;
    @memcpy(dst[576 + sb * 18 ..][0 .. (tb - sb) * 18], dst[sb * 18 ..][0 .. (tb - sb) * 18]);
    for (0..tb) |i| {
        for (0..12) |k| {
            dst[i * 18 + k] *= scf[i * 6 + 0];
            dst[i * 18 + k + 576] *= scf[i * 6 + 3];
        }
    }
}
