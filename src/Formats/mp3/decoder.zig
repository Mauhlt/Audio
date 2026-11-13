//! MPEG-1/2/2.5 audio frame decoder (Layer I, II and III), output as 32-bit float.
//!
//! A Zig port of minimp3 by lieff (CC0 / public domain, https://github.com/lieff/minimp3),
//! as bundled in dr_mp3. Scalar code only; where minimp3's SSE path associates float
//! additions differently from its scalar path, this follows the SSE order so the output
//! matches what dr_mp3 produces on x86-64.
//!
//! Differences from minimp3, all for malformed input only:
//!   - bit reads past the end of the buffer return zeros instead of reading stale memory
//!   - private bits are masked out of MPEG-1 scfsi
//!   - intensity / mid-side stereo are only applied in joint-stereo mode
const std = @import("std");
const header = @import("header.zig");
const Header = header.Header;
const Sync = header.Sync;
const HDR_SIZE = header.HDR_SIZE;
const MAX_FREE_FORMAT_FRAME_SIZE = header.MAX_FREE_FORMAT_FRAME_SIZE;
const MAX_BITRESERVOIR_BYTES = header.MAX_BITRESERVOIR_BYTES;
pub const MAX_FRAME_SAMPLES = header.MAX_FRAME_SAMPLES;
const Bs = @import("bits.zig").Bs;
const l3 = @import("layer3.zig");
const GrInfo = l3.GrInfo;
const l12 = @import("layer12.zig");
const synthGranule = @import("synth.zig").synthGranule;

pub const FrameInfo = struct {
    frame_bytes: usize = 0,
    channels: u8 = 0,
    sample_rate: u32 = 0,
    /// 0 = no frame found
    layer: u8 = 0,
    bitrate_kbps: u32 = 0,
    /// samples per channel this frame holds (even when it could not be decoded)
    frame_samples: u32 = 0,
};

/// ~20 KiB; allocate it rather than putting it on a small stack.
pub const Decoder = struct {
    mdct_overlap: [2][9 * 32]f32 = @splat(@splat(0)),
    qmf_state: [15 * 2 * 32]f32 = @splat(0),
    reserv: usize = 0,
    sync: Sync = .{},
    reserv_buf: [MAX_BITRESERVOIR_BYTES]u8 = @splat(0),
    // scratch
    bs: Bs = .{ .buf = &.{}, .limit = 0 },
    maindata: [MAX_BITRESERVOIR_BYTES + MAX_FREE_FORMAT_FRAME_SIZE]u8 = @splat(0),
    gr_info: [4]GrInfo = @splat(.{}),
    grbuf: [2 * 576]f32 = @splat(0),
    scf: [40]f32 = @splat(0),
    syn: [(18 + 15) * 2 * 32]f32 = @splat(0),
    ist_pos: [2][39]u8 = @splat(@splat(0)),

    /// Forget the stream: the next frame is located from scratch.
    pub fn reset(dec: *Decoder) void {
        dec.sync.header[0] = 0;
    }

    /// Decodes the first frame in `mp3` into `pcm` (interleaved, up to 1152 * 2 floats).
    /// Returns samples per channel written (0 if the frame was skipped: see `info.layer`
    /// to tell "no frame" from "frame could not be decoded"). `info.frame_bytes` is how far
    /// to advance `mp3`.
    pub fn decodeFrame(dec: *Decoder, mp3: []const u8, pcm: []f32, info: *FrameInfo) usize {
        info.* = .{};
        const found = dec.sync.next(mp3);
        if (found.resync) {
            const sync = dec.sync;
            dec.* = .{};
            dec.sync = sync;
        }
        if (found.len == 0) {
            info.frame_bytes = found.skip;
            return 0;
        }
        const frame = mp3[found.skip..][0..found.len];
        const hdr = frame[0..4];
        info.frame_bytes = found.skip + found.len;
        info.channels = if (Header.isMono(hdr)) 1 else 2;
        info.sample_rate = Header.sampleRateHz(hdr);
        info.layer = Header.layer(hdr);
        info.bitrate_kbps = Header.bitrateKbps(hdr);
        info.frame_samples = Header.frameSamples(hdr);
        const nch: usize = info.channels;

        var bs_frame: Bs = .init(frame[HDR_SIZE..]);
        if (Header.isCrc(hdr)) _ = bs_frame.getBits(16);

        if (info.layer == 3) {
            const main_data_begin = l3.readSideInfo(&bs_frame, &dec.gr_info, hdr) orelse {
                dec.reset();
                return 0;
            };
            if (bs_frame.pos > bs_frame.limit) {
                dec.reset();
                return 0;
            }
            const success = dec.restoreReservoir(&bs_frame, main_data_begin);
            if (success) {
                const n_gr: usize = if (Header.isMpeg1(hdr)) 2 else 1;
                for (0..n_gr) |igr| {
                    @memset(&dec.grbuf, 0);
                    dec.l3Decode(hdr, dec.gr_info[igr * nch ..][0..2], nch);
                    synthGranule(&dec.qmf_state, &dec.grbuf, 18, nch, pcm[igr * 576 * nch ..], &dec.syn);
                }
            }
            dec.saveReservoir();
            return if (success) Header.frameSamples(hdr) else 0;
        }

        var sci: l12.L12ScaleInfo = undefined;
        l12.l12ReadScaleInfo(hdr, &bs_frame, &sci);
        @memset(&dec.grbuf, 0);
        var i: usize = 0;
        var out: usize = 0;
        for (0..3) |igr| {
            i += l12.l12DequantizeGranule(&dec.grbuf, i, &bs_frame, &sci, info.layer | 1);
            if (i == 12) {
                i = 0;
                l12.l12ApplyScf384(&sci, sci.scf[igr..], &dec.grbuf);
                synthGranule(&dec.qmf_state, &dec.grbuf, 12, nch, pcm[out..], &dec.syn);
                @memset(&dec.grbuf, 0);
                out += 384 * nch;
            }
            if (bs_frame.pos > bs_frame.limit) {
                dec.reset();
                return 0;
            }
        }
        return Header.frameSamples(hdr);
    }

    fn saveReservoir(dec: *Decoder) void {
        var pos: i32 = @divTrunc(dec.bs.pos + 7, 8);
        var remains: i32 = @divTrunc(dec.bs.limit, 8) - pos;
        if (remains > MAX_BITRESERVOIR_BYTES) {
            pos += remains - MAX_BITRESERVOIR_BYTES;
            remains = MAX_BITRESERVOIR_BYTES;
        }
        if (remains > 0) {
            const p: usize = @intCast(pos);
            const r: usize = @intCast(remains);
            std.mem.copyForwards(u8, dec.reserv_buf[0..r], dec.maindata[p..][0..r]);
        }
        dec.reserv = @intCast(@max(remains, 0));
    }

    fn restoreReservoir(dec: *Decoder, bs: *const Bs, main_data_begin: u32) bool {
        const frame_bytes: usize = @min(@as(usize, @intCast(@divTrunc(bs.limit - bs.pos, 8))), MAX_FREE_FORMAT_FRAME_SIZE);
        const bytes_have = @min(dec.reserv, main_data_begin);
        const from = dec.reserv - bytes_have;
        @memcpy(dec.maindata[0..bytes_have], dec.reserv_buf[from..][0..bytes_have]);
        const start: usize = @intCast(@divTrunc(bs.pos, 8));
        @memcpy(dec.maindata[bytes_have..][0..frame_bytes], bs.buf[start..][0..frame_bytes]);
        dec.bs = .init(dec.maindata[0 .. bytes_have + frame_bytes]);
        return dec.reserv >= main_data_begin;
    }

    fn l3Decode(dec: *Decoder, hdr: []const u8, gr: *[2]GrInfo, nch: usize) void {
        for (0..nch) |ch| {
            const limit = dec.bs.pos + gr[ch].part_23_length;
            l3.decodeScalefactors(hdr, &dec.ist_pos[ch], &dec.bs, &gr[ch], &dec.scf, ch);
            l3.huffman(dec.grbuf[ch * 576 ..][0..576], &dec.bs, &gr[ch], &dec.scf, limit);
        }
        if (nch == 2 and Header.isIStereo(hdr)) {
            l3.intensityStereo(&dec.grbuf, &dec.ist_pos[1], gr, hdr);
        } else if (Header.isMsStereo(hdr)) {
            l3.midsideStereo(&dec.grbuf, 0, 576);
        }
        for (0..nch) |ch| {
            const g = &gr[ch];
            const base = ch * 576;
            var aa_bands: i32 = 31;
            const n_long_bands: usize = @as(usize, if (g.mixed_block_flag != 0) 2 else 0) << @intFromBool(Header.mySampleRate(hdr) == 2);
            if (g.n_short_sfb != 0) {
                aa_bands = @as(i32, @intCast(n_long_bands)) - 1;
                l3.reorder(&dec.grbuf, base + n_long_bands * 18, &dec.syn, g.sfbtab[g.n_long_sfb..]);
            }
            l3.antialias(&dec.grbuf, base, aa_bands);
            l3.imdctGr(dec.grbuf[base..][0..576], &dec.mdct_overlap[ch], g.block_type, n_long_bands);
            l3.changeSign(dec.grbuf[base..][0..576]);
        }
    }
};
