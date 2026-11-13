//! MP3 (MPEG-1/2/2.5 Layer III) encoder: constant bit rate, mono or joint stereo (mid/side
//! chosen per frame). A LAME-style "Info" frame carries the encoder delay and padding so
//! gapless decoders return exactly the input samples.
//!
//!   - psychoacoustic model (psy.zig): allowed noise per scale factor band, which the
//!     quantizer's outer loop shapes the noise to (scale factors), and a perceptual entropy
//!     that decides how many bits each granule gets
//!   - block switching: short blocks around attacks (start / short / stop windows) against
//!     pre-echo, decided with one granule of look-ahead; both channels switch together
//!   - bit reservoir: granules that need few bits leave them to later, harder ones (frames
//!     are held back until no later frame can still write into them)
//! Each can be turned off in `Options` (to compare, or for speed).
const std = @import("std");
const Error = @import("../error.zig").Error;
const T = @import("tables.zig");
const analysis = @import("analysis.zig");
const quant = @import("quantize.zig");
const BitWriter = @import("bitwriter.zig");
const psy_mod = @import("psy.zig");
const Psy = psy_mod.Psy;
const V32 = analysis.V32;
const BlockType = analysis.BlockType;

pub const Options = struct {
    /// CBR bit rate; null picks one from the sample rate and channel count.
    bitrate_kbps: ?u16 = null,
    stereo: enum { auto, left_right, mid_side } = .auto,
    /// Low-pass in Hz; null picks one from the bit rate per channel.
    lowpass_hz: ?u32 = null,
    /// Shape the noise under a psychoacoustic masking threshold (else: just fill the bits).
    psy: bool = true,
    /// Switch to short blocks around attacks.
    short_blocks: bool = true,
    /// Let granules borrow bits from earlier frames.
    reservoir: bool = true,
};

const Version = enum(u2) { mpeg25 = 0, mpeg2 = 2, mpeg1 = 3 };

const rates = [_]struct { hz: u32, version: Version, idx: u2 }{
    .{ .hz = 44100, .version = .mpeg1, .idx = 0 },  .{ .hz = 48000, .version = .mpeg1, .idx = 1 },
    .{ .hz = 32000, .version = .mpeg1, .idx = 2 },  .{ .hz = 22050, .version = .mpeg2, .idx = 0 },
    .{ .hz = 24000, .version = .mpeg2, .idx = 1 },  .{ .hz = 16000, .version = .mpeg2, .idx = 2 },
    .{ .hz = 11025, .version = .mpeg25, .idx = 0 }, .{ .hz = 12000, .version = .mpeg25, .idx = 1 },
    .{ .hz = 8000, .version = .mpeg25, .idx = 2 },
};
const bitrates_mpeg1 = [15]u16{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 };
const bitrates_mpeg2 = [15]u16{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 };

/// Encoder delay written to the Info frame; the decoder adds its own 529.
const ENC_DELAY = 576;
/// Leading silence the encoder inserts: what gapless decoders drop again.
const LEAD = ENC_DELAY + 529;

const Config = struct {
    version: Version,
    sr_idx: u2,
    br_idx: u4,
    kbps: u16,
    sample_rate: u32,
    channels: u8,
    granules: u8, // per frame
    side_bytes: u8,
    edges: [23]u16,
    short_widths: [13]u8, // one short window's band widths
    lowpass_line: usize, // first MDCT line zeroed (long block numbering)
    max_reservoir: u32, // bytes main_data_begin can reach back

    fn frameSamples(c: Config) u32 {
        return @as(u32, c.granules) * 576;
    }

    /// Bytes per frame without padding, and the remainder that padding spreads out.
    const FrameBytes = struct { bytes: u32, rem: u32 };

    fn frameBytes(c: Config) FrameBytes {
        return c.frameBytesAt(c.kbps);
    }

    fn frameBytesAt(c: Config, kbps: u32) FrameBytes {
        const num = c.frameSamples() / 8 * kbps * 1000;
        return .{ .bytes = num / c.sample_rate, .rem = num % c.sample_rate };
    }

    fn bitrates(c: Config) *const [15]u16 {
        return if (c.version == .mpeg1) &bitrates_mpeg1 else &bitrates_mpeg2;
    }
};

fn configure(sample_rate: u32, channels: u16, opts: Options) !Config {
    if (channels == 0) return Error.InvalidChannels;
    if (channels > 2) return Error.UnsupportedChannels;
    const rate = for (rates) |r| {
        if (r.hz == sample_rate) break r;
    } else return Error.UnsupportedSampleRate;
    const table: *const [15]u16 = if (rate.version == .mpeg1) &bitrates_mpeg1 else &bitrates_mpeg2;
    const kbps = opts.bitrate_kbps orelse defaultBitrate(rate.version, sample_rate, channels);
    const br_idx = std.mem.indexOfScalar(u16, table[1..], kbps) orelse return Error.UnsupportedFeature;
    const mpeg1 = rate.version == .mpeg1;
    const per_ch = kbps / channels;
    const lowpass = opts.lowpass_hz orelse defaultLowpass(per_ch, channels == 2);
    const nyquist = sample_rate / 2;
    // band table row, as the decoder picks it: MPEG-2.5, MPEG-2, MPEG-1 rates in that order,
    // with the first two rows shared
    var sr_row: usize = rate.idx + @as(usize, switch (rate.version) {
        .mpeg25 => 0,
        .mpeg2 => 3,
        .mpeg1 => 6,
    });
    sr_row -= @intFromBool(sr_row != 0);
    return .{
        .version = rate.version,
        .sr_idx = rate.idx,
        .br_idx = @intCast(br_idx + 1),
        .kbps = kbps,
        .sample_rate = sample_rate,
        .channels = @intCast(channels),
        .granules = if (mpeg1) 2 else 1,
        .side_bytes = if (mpeg1) (if (channels == 1) 17 else 32) else (if (channels == 1) 9 else 17),
        .edges = quant.bandEdges(&T.scf_long[sr_row]),
        .short_widths = blk: {
            var sw: [13]u8 = undefined;
            for (&sw, 0..) |*v, b| v.* = T.scf_short[sr_row][3 * b];
            break :blk sw;
        },
        .lowpass_line = @min(576, @as(usize, lowpass) * 576 / nyquist),
        .max_reservoir = if (opts.reservoir) (if (mpeg1) 511 else 255) else 0,
    };
}

fn defaultBitrate(version: Version, sample_rate: u32, channels: u16) u16 {
    return switch (version) {
        .mpeg1 => if (channels == 2) 192 else 96,
        .mpeg2 => if (channels == 2) (if (sample_rate >= 22050) 96 else 64) else 48,
        .mpeg25 => if (channels == 2) 32 else 24,
    };
}

/// Low-pass by bit rate per channel (roughly what LAME picks).
fn defaultLowpass(kbps_per_channel: u32, joint: bool) u32 {
    // joint stereo spends fewer bits on the side channel
    const b = if (joint) kbps_per_channel * 5 / 4 else kbps_per_channel;
    const table = [_][2]u32{
        .{ 8, 3000 },   .{ 12, 4000 },   .{ 16, 5500 },   .{ 24, 7000 },   .{ 32, 9000 },
        .{ 40, 11000 }, .{ 48, 13000 },  .{ 56, 15000 },  .{ 64, 16000 },  .{ 80, 17500 },
        .{ 96, 18500 }, .{ 112, 19000 }, .{ 128, 19500 }, .{ 160, 20000 },
    };
    for (table) |e| if (b <= e[0]) return e[1];
    return 20500;
}

/// Per-channel analysis state: input with the leading silence, and a sliding window of
/// 36 subband slots (this granule and the next).
const Channel = struct {
    x: []f32,
    slots: [36]V32 = @splat(@splat(0)),
};

/// Block type of the next granule, from the previous one and whether this granule / the next
/// holds an attack (start must be followed by short, short by short or stop).
fn nextBlockType(prev: BlockType, attack_now: bool, attack_next: bool) BlockType {
    return switch (prev) {
        .start => .short,
        .short => if (attack_now or attack_next) .short else .stop,
        .normal, .stop => if (attack_next) .start else .normal,
    };
}

/// Frames waiting for main data: with a bit reservoir a frame's slot can still receive the
/// start of a later frame's main data, so it is written out only once nothing can.
const Stream = struct {
    const Frame = struct { buf: [1441]u8, len: u32, slot_off: u32, slot_start: u64, slot_len: u32 };

    pending: [8]Frame = undefined,
    n: usize = 0,
    /// stream position (in main data bytes) of the next frame's slot
    next_slot: u64 = 0,
    /// end of the main data written so far
    data_end: u64 = 0,

    /// Bytes before the next frame's slot that its main data may use.
    fn reservoir(self: *const Stream, max: u32) u32 {
        return @intCast(@min(self.next_slot - self.data_end, max));
    }

    /// Queues a frame (header + side info already in `head`) with `main` as its main data,
    /// starting `main_data_begin` bytes before its own slot.
    fn push(self: *Stream, w: *std.Io.Writer, head: []const u8, frame_len: u32, main: []const u8, main_data_begin: u32) !void {
        const f = &self.pending[self.n];
        self.n += 1;
        @memset(f.buf[0..frame_len], 0);
        @memcpy(f.buf[0..head.len], head);
        f.len = frame_len;
        f.slot_off = @intCast(head.len);
        f.slot_start = self.next_slot;
        f.slot_len = frame_len - f.slot_off;
        // copy main data into whichever slots its stream range covers
        const start = self.next_slot - main_data_begin;
        for (self.pending[0..self.n]) |*p| {
            const lo = @max(start, p.slot_start);
            const hi = @min(start + main.len, p.slot_start + p.slot_len);
            if (lo >= hi) continue;
            @memcpy(p.buf[p.slot_off + (lo - p.slot_start) ..][0 .. hi - lo], main[lo - start .. hi - start]);
        }
        self.data_end = start + main.len;
        self.next_slot += f.slot_len;
        // frames whose slots end before the data end can no longer change
        var done: usize = 0;
        while (done < self.n and (self.pending[done].slot_start + self.pending[done].slot_len <= self.data_end or self.n - done == self.pending.len)) : (done += 1) {
            try w.writeAll(self.pending[done].buf[0..self.pending[done].len]);
        }
        std.mem.copyForwards(Frame, self.pending[0 .. self.n - done], self.pending[done..self.n]);
        self.n -= done;
    }

    fn finish(self: *Stream, w: *std.Io.Writer) !void {
        for (self.pending[0..self.n]) |*p| try w.writeAll(p.buf[0..p.len]);
        self.n = 0;
    }
};

pub fn encode(gpa: std.mem.Allocator, w: *std.Io.Writer, pcm: []const f32, sample_rate: u32, channels: u16, opts: Options) !void {
    const cfg = try configure(sample_rate, channels, opts);
    const nch: usize = cfg.channels;
    if (pcm.len % nch != 0) return Error.InvalidBufferLen;
    const frames_in = pcm.len / nch;
    const mpeg1 = cfg.version == .mpeg1;

    const n_granules = (LEAD + frames_in + 575) / 576;
    const n_frames = (n_granules + cfg.granules - 1) / cfg.granules;
    const raw = n_frames * cfg.frameSamples();
    const enc_padding = raw - ENC_DELAY - frames_in;
    if (enc_padding > 4095) return Error.TooLarge;

    // deinterleaved input, with silence before (LEAD) and after (analysis look-ahead)
    const padded_len = 576 * (n_frames * cfg.granules + 3) + 1056;
    var chans: [2]Channel = undefined;
    var allocated: usize = 0;
    defer for (chans[0..allocated]) |c| gpa.free(c.x);
    for (chans[0..nch]) |*c| {
        c.* = .{ .x = try gpa.alloc(f32, padded_len) };
        allocated += 1;
        @memset(c.x, 0);
    }
    for (0..frames_in) |i| for (0..nch) |ch| {
        chans[ch].x[LEAD + i] = pcm[i * nch + ch];
    };

    const win = analysis.window();
    const long_bands = quant.Bands.long(&cfg.edges);
    const short_bands = quant.Bands.short_(&cfg.short_widths);
    const p43 = try gpa.create(quant.Pow43);
    defer gpa.destroy(p43);
    quant.pow43Table(p43);
    var psy: Psy = .init(sample_rate, &cfg.edges, &cfg.short_widths);

    // prime the slot window with granule 0
    for (chans[0..nch]) |*c| for (0..18) |t| {
        c.slots[18 + t] = slot(&win, c.x, t);
    };

    // frame sizes (padding spreads the remainder), needed up front for the Info frame
    const fb = cfg.frameBytes();
    var total_bytes: u64 = infoFrameBytes(cfg);
    {
        var acc: u32 = 0;
        for (0..n_frames) |_| {
            acc += fb.rem;
            const pad = acc >= cfg.sample_rate;
            if (pad) acc -= cfg.sample_rate;
            total_bytes += fb.bytes + @intFromBool(pad);
        }
    }
    try writeInfoFrame(w, cfg, @intCast(n_frames), total_bytes, enc_padding);

    var stream: Stream = .{};
    var pad_acc: u32 = 0;
    var granule: usize = 0;
    var block: BlockType = .normal;
    for (0..n_frames) |_| {
        pad_acc += fb.rem;
        const pad = pad_acc >= cfg.sample_rate;
        if (pad) pad_acc -= cfg.sample_rate;
        const frame_len = fb.bytes + @intFromBool(pad);

        // spectra, block types and allowed noise of this frame's granules
        var xr: [2][2][576]f32 = undefined; // [gr][ch]
        var xmin: [2][2][39]f32 = undefined;
        var pe: [2][2]f32 = @splat(@splat(0));
        var types: [2]BlockType = undefined;
        for (0..cfg.granules) |gr| {
            if (opts.short_blocks) {
                var now = false;
                var next = false;
                for (chans[0..nch]) |*c| {
                    now = now or psy_mod.attack(c.x, granule);
                    next = next or psy_mod.attack(c.x, granule + 1);
                }
                block = nextBlockType(block, now, next);
            }
            types[gr] = block;
            for (chans[0..nch], 0..) |*c, ch| {
                // slide: the old "next" granule becomes "this" one, analyze the new next
                @memcpy(c.slots[0..18], c.slots[18..36]);
                for (0..18) |t| c.slots[18 + t] = slot(&win, c.x, 18 * (granule + 1) + t);
                analysis.hybrid(&c.slots, block, &cfg.short_widths, &xr[gr][ch]);
                applyLowpass(&xr[gr][ch], block, &cfg.short_widths, cfg.lowpass_line);
                if (opts.psy) pe[gr][ch] = if (block == .short)
                    psy.shortThresholds(ch, &xr[gr][ch], xmin[gr][ch][0..39])
                else
                    psy.longThresholds(ch, &xr[gr][ch], xmin[gr][ch][0..22]);
            }
            granule += 1;
        }

        const ms = nch == 2 and switch (opts.stereo) {
            .left_right => false,
            .mid_side => true,
            .auto => preferMidSide(xr[0..cfg.granules]),
        };
        if (ms) for (xr[0..cfg.granules], xmin[0..cfg.granules], pe[0..cfg.granules]) |*g, *m, *e| {
            for (&g[0], &g[1]) |*l, *r| {
                const mid = (l.* + r.*) * 0.5;
                const side = (l.* - r.*) * 0.5;
                l.* = mid;
                r.* = side;
            }
            // noise in M and S both lands in L and R: each may have half the smaller threshold
            for (&m[0], &m[1]) |*a, *b| {
                const t = @min(a.*, b.*) * 0.5;
                a.* = t;
                b.* = t;
            }
            const avg = (e[0] + e[1]) / 2;
            e.* = .{ avg, avg };
        };

        // bits: this frame's slot plus what the reservoir holds; perceptual entropy above the
        // average asks for more, the reservoir pays for it
        const slot_bytes = frame_len - 4 - cfg.side_bytes;
        const resv = stream.reservoir(cfg.max_reservoir);
        const units: u32 = @as(u32, cfg.granules) * @as(u32, @intCast(nch));
        const mean = slot_bytes * 8 / units;
        var left: u32 = (resv + slot_bytes) * 8;
        // a nearly full reservoir would overflow: spend some of it
        const drain: u32 = if (resv * 10 > cfg.max_reservoir * 8) (resv * 8 - cfg.max_reservoir * 8 * 8 / 10) / units else 0;
        var gi: [2][2]quant.Granule = undefined;
        var done: u32 = 0;
        for (0..cfg.granules) |gr| for (0..nch) |ch| {
            const after = units - done - 1;
            const extra: u32 = if (opts.psy) @intFromFloat(@max(0, (pe[gr][ch] - 750) / 1.4) * (if (types[gr] == .short) @as(f32, 1.5) else 1)) else 0;
            const floor = after * (mean / 2); // leave the rest of the frame at least half its share
            const want = if (opts.psy) mean + extra + drain else left / (units - done);
            const max_bits = @min(want, left -| floor, 4095);
            var xr34: [576]f32 = undefined;
            quant.pow34(&xr[gr][ch], &xr34);
            quant.encode(.{
                .xr = &xr[gr][ch],
                .xr34 = &xr34,
                .bands = if (types[gr] == .short) &short_bands else &long_bands,
                .block_type = types[gr],
                .ms = ms,
                .mpeg1 = mpeg1,
                .max_bits = max_bits,
                .xmin = if (opts.psy) &xmin[gr][ch] else null,
                .pow43 = p43,
            }, &gi[gr][ch]);
            left -= gi[gr][ch].part2_3_length;
            done += 1;
        };

        var head_buf: [36]u8 = undefined;
        var hw: BitWriter = .init(head_buf[0 .. 4 + cfg.side_bytes]);
        writeHeader(&hw, cfg, pad, ms);
        writeSideInfo(&hw, cfg, &gi, resv);
        var main_buf: [511 + 1441]u8 = undefined;
        var bw: BitWriter = .init(&main_buf);
        for (0..cfg.granules) |gr| for (0..nch) |ch| quant.write(&bw, &gi[gr][ch], &xr[gr][ch]);
        try stream.push(w, head_buf[0 .. 4 + cfg.side_bytes], frame_len, main_buf[0 .. (bw.pos + 7) / 8], resv);
    }
    try stream.finish(w);
}

/// Zeroes the lines above the low-pass (short blocks: per window, in bitstream order).
fn applyLowpass(xr: *[576]f32, block: BlockType, short_widths: *const [13]u8, line: usize) void {
    if (block != .short) return @memset(xr[line..], 0);
    const cut = (line + 2) / 3; // lines per window
    var edge: usize = 0;
    for (short_widths) |width| {
        for (0..3) |w| for (0..width) |j| {
            if (edge + j >= cut) xr[3 * edge + w * width + j] = 0;
        };
        edge += width;
    }
}

fn slot(win: *const analysis.Window, x: []const f32, t: usize) V32 {
    const s = analysis.analyzeSlot(win, x[32 * t ..]);
    return if (t % 2 == 1) s * analysis.odd_subbands else s;
}

/// Mid/side when the channels are similar enough that the side signal is small.
fn preferMidSide(granules: []const [2][576]f32) bool {
    var mid: f64 = 0;
    var side: f64 = 0;
    for (granules) |g| for (g[0], g[1]) |l, r| {
        mid += (l + r) * (l + r);
        side += (l - r) * (l - r);
    };
    return side < 0.5 * mid;
}

fn writeHeader(bw: *BitWriter, cfg: Config, pad: bool, ms: bool) void {
    bw.write(0x7FF, 11);
    bw.write(@backingInt(cfg.version), 2);
    bw.write(0b01, 2); // Layer III
    bw.write(1, 1); // no CRC
    bw.write(cfg.br_idx, 4);
    bw.write(cfg.sr_idx, 2);
    bw.write(@intFromBool(pad), 1);
    bw.write(0, 1); // private
    bw.write(if (cfg.channels == 1) 0b11 else 0b01, 2); // mono / joint stereo
    bw.write(if (ms) 0b10 else 0b00, 2); // mode extension: M/S on, intensity off
    bw.write(0, 1); // copyright
    bw.write(1, 1); // original
    bw.write(0, 2); // emphasis
}

fn writeSideInfo(bw: *BitWriter, cfg: Config, gi: *const [2][2]quant.Granule, main_data_begin: u32) void {
    const mpeg1 = cfg.version == .mpeg1;
    const nch: usize = cfg.channels;
    if (mpeg1) {
        bw.write(main_data_begin, 9);
        bw.write(0, if (nch == 1) 5 else 3); // private bits
        bw.write(0, @intCast(4 * nch)); // scfsi: scale factors always sent
    } else {
        bw.write(main_data_begin, 8);
        bw.write(0, if (nch == 1) 1 else 2);
    }
    for (0..cfg.granules) |gr| for (0..nch) |ch| {
        const g = &gi[gr][ch];
        bw.write(g.part2_3_length, 12);
        bw.write(g.big_values, 9);
        bw.write(g.global_gain, 8);
        bw.write(g.scalefac_compress, if (mpeg1) 4 else 9);
        if (g.block_type == .normal) {
            bw.write(0, 1); // window switching
            for (g.table_select) |t| bw.write(t, 5);
            bw.write(g.region0_count, 4);
            bw.write(g.region1_count, 3);
        } else {
            bw.write(1, 1);
            bw.write(@backingInt(g.block_type), 2);
            bw.write(0, 1); // mixed blocks
            for (g.table_select[0..2]) |t| bw.write(t, 5);
            for (g.subblock_gain) |sg| bw.write(sg, 3);
        }
        if (mpeg1) bw.write(0, 1); // preflag
        bw.write(g.scalefac_scale, 1);
        bw.write(g.count1table_select, 1);
    };
}

fn infoFrameBytes(cfg: Config) u32 {
    var c = cfg;
    while (c.frameBytes().bytes < 4 + @as(u32, cfg.side_bytes) + 16 + 36) {
        c.br_idx += 1;
        c.kbps = cfg.bitrates()[c.br_idx];
    }
    return c.frameBytes().bytes;
}

/// A silent first frame holding a Xing "Info" header (frame and byte counts) and the LAME
/// extension with the encoder delay and padding, which gapless decoders use to trim.
fn writeInfoFrame(w: *std.Io.Writer, cfg: Config, frames: u32, total_bytes: u64, enc_padding: usize) !void {
    var buf: [2881]u8 = undefined;
    // the tag needs side info + 16 + 36 bytes: use a higher bit rate for this frame if the
    // stream's frames are too small (decoders only require version / layer / rate to match)
    var info_cfg = cfg;
    while (info_cfg.frameBytes().bytes < 4 + @as(u32, cfg.side_bytes) + 16 + 36) {
        info_cfg.br_idx += 1;
        info_cfg.kbps = cfg.bitrates()[info_cfg.br_idx];
    }
    const len = info_cfg.frameBytes().bytes;
    var bw: BitWriter = .init(buf[0..len]);
    writeHeader(&bw, info_cfg, false, false);
    var p: usize = 4 + @as(usize, cfg.side_bytes); // side info all zeros
    @memcpy(buf[p..][0..4], "Info");
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], 0x3, .big); // frames + bytes fields present
    std.mem.writeInt(u32, buf[p + 8 ..][0..4], frames, .big);
    std.mem.writeInt(u32, buf[p + 12 ..][0..4], @intCast(@min(total_bytes, std.math.maxInt(u32))), .big);
    p += 16;
    // LAME extension (36 bytes): version string, ..., delay/padding at +21
    @memcpy(buf[p..][0..9], "ZigAudio1");
    const d: u32 = ENC_DELAY;
    const pd: u32 = @intCast(enc_padding);
    buf[p + 21] = @intCast(d >> 4);
    buf[p + 22] = @intCast(((d & 0xF) << 4) | (pd >> 8));
    buf[p + 23] = @intCast(pd & 0xFF);
    std.mem.writeInt(u32, buf[p + 28 ..][0..4], @intCast(@min(total_bytes, std.math.maxInt(u32))), .big); // music length
    try w.writeAll(buf[0..len]);
}
