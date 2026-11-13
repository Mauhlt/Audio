//! QOA - "Quite OK Audio" (https://qoaformat.org), the audio sibling of QOI.
//! Lossy, fixed 3.2 bits per sample, 16-bit PCM in and out, 1..255 channels.
//! The encoder's output is byte-identical to the reference encoder (qoa.h).
//! Layout: see header.zig.
const std = @import("std");
const Error = @import("../error.zig").Error;
const Audio = @import("../../root.zig");
const Info = @import("../../info.zig");
const Samples = @import("../../Samples/samples.zig").Samples;
pub const Header = @import("header.zig");
pub const lms = @import("lms.zig");
const search = @import("search.zig");
const Lms = lms.Lms;

const SLICE_LEN = Header.SLICE_LEN;
const FRAME_LEN = Header.FRAME_LEN;
const MAX_CHANNELS = Header.MAX_CHANNELS;

pub fn info(data: []const u8) !Info {
    if (data.len < Header.SIZE) return Error.UnexpectedEndOfData;
    if (!std.mem.eql(u8, data[0..4], Header.MAGIC)) return Error.UnexpectedSignature;
    var frames: u64 = std.mem.readInt(u32, data[4..8], .big);
    const first: Header.Frame = try .parse(data[Header.SIZE..]);
    if (frames == 0) {
        // streaming file: count samples frame by frame
        var pos: usize = Header.SIZE;
        while (pos < data.len) {
            const fh: Header.Frame = try .parse(data[pos..]);
            if (fh.channels != first.channels or fh.sample_rate != first.sample_rate) return Error.UnsupportedFeature;
            frames += fh.samples;
            pos += fh.size;
        }
    } else {
        // the claimed length must fit in the file (don't let a bad header size the output)
        const full: u64 = frames / FRAME_LEN;
        const rest: u64 = frames % FRAME_LEN;
        const need = Header.SIZE + full * Header.frameSize(first.channels, FRAME_LEN) +
            (if (rest != 0) Header.frameSize(first.channels, @intCast(rest)) else 0);
        if (need > data.len) return Error.UnexpectedEndOfData;
    }
    return .{ .sample_rate = first.sample_rate, .channels = first.channels, .frames = frames, .tag = .i16 };
}

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    _ = scratch;
    if (inf.tag != .i16) return Error.UnsupportedFormat;
    const dst = std.mem.bytesAsSlice(i16, out);
    const channels: usize = inf.channels;
    var state: [MAX_CHANNELS]Lms = undefined;
    var pos: usize = Header.SIZE;
    var frame_start: usize = 0; // in samples per channel
    while (frame_start < inf.frames) {
        const fh: Header.Frame = try .parse(data[pos..]);
        if (fh.channels != channels or fh.sample_rate != inf.sample_rate) return Error.UnsupportedFeature;
        const frame_samples = @min(fh.samples, inf.frames - frame_start);
        var p = pos + 8;
        for (state[0..channels]) |*l| {
            l.history = Lms.unpack16(std.mem.readInt(u64, data[p..][0..8], .big));
            l.weights = Lms.unpack16(std.mem.readInt(u64, data[p + 8 ..][0..8], .big));
            p += 16;
        }
        var s: usize = 0;
        while (s < frame_samples) : (s += SLICE_LEN) {
            const end = @min(s + SLICE_LEN, frame_samples);
            for (state[0..channels], 0..) |*l, c| {
                decodeSlice(std.mem.readInt(u64, data[p..][0..8], .big), l, dst[(frame_start + s) * channels + c ..], channels, end - s);
                p += 8;
            }
        }
        frame_start += frame_samples;
        pos += fh.size;
    }
}

/// One slice. Every sample depends on the previous one through the predictor, so this is a
/// latency-bound chain: plain scalar code beats 4-lane vectors here (measured).
fn decodeSlice(slice_in: u64, l: *Lms, dst: []align(1) i16, stride: usize, len: usize) void {
    var st = l.*;
    const row = &lms.dequant_tab[@intCast(slice_in >> 60)];
    var slice = slice_in << 4;
    var i: usize = 0;
    for (0..len) |_| {
        const dq = row[@intCast(slice >> 61)];
        const r = lms.clampS16(st.predict() +% dq);
        dst[i] = @intCast(r);
        st.update(r, dq);
        slice <<= 3;
        i += stride;
    }
    l.* = st;
}

pub fn encode(audio: *const Audio, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    const channels: usize = audio.channels;
    if (channels == 0) return Error.InvalidChannels;
    if (channels > MAX_CHANNELS) return Error.UnsupportedChannels;
    if (audio.sample_rate == 0 or audio.sample_rate > std.math.maxInt(u24)) return Error.UnsupportedSampleRate;
    if (audio.samples.len() % channels != 0) return Error.InvalidBufferLen;
    const frames = audio.samples.len() / channels;
    if (frames > std.math.maxInt(u32)) return Error.TooLarge;

    const converted: ?Samples = if (audio.samples == .i16) null else try audio.samples.convert(.i16, gpa);
    defer if (converted) |c| c.deinit(gpa);
    const pcm = (converted orelse audio.samples).i16;

    try w.writeAll(Header.MAGIC);
    try w.writeInt(u32, @intCast(frames), .big);

    var state: [MAX_CHANNELS]Lms = @splat(Lms.initial);
    var frame_start: usize = 0;
    while (frame_start < frames) : (frame_start += FRAME_LEN) {
        const frame_samples: usize = @min(FRAME_LEN, frames - frame_start);
        // like the reference encoder, the scale factor search restarts at 0 every frame
        var prev_sf: [MAX_CHANNELS]usize = @splat(0);
        const fh: Header.Frame = .{
            .channels = @intCast(channels),
            .sample_rate = @intCast(audio.sample_rate),
            .samples = @intCast(frame_samples),
            .size = @intCast(Header.frameSize(channels, frame_samples)),
        };
        try fh.write(w);
        for (state[0..channels]) |l| {
            try w.writeInt(u64, Lms.packed16(l.history), .big);
            try w.writeInt(u64, Lms.packed16(l.weights), .big);
        }
        var s: usize = 0;
        while (s < frame_samples) : (s += SLICE_LEN) {
            const slice_len: usize = @min(SLICE_LEN, frame_samples - s);
            const shift: u6 = @intCast((SLICE_LEN - slice_len) * 3); // short final slices are left-justified
            var c: usize = 0;
            while (c + 2 <= channels) : (c += 2) {
                // channel pairs at once: independent predictors overlap well
                const first = (frame_start + s) * channels + c;
                const best = search.encodeSlicePair(pcm, .{ first, first + 1 }, channels, slice_len, state[c..][0..2].*, prev_sf[c..][0..2].*);
                for (best, c..) |b, ch| {
                    state[ch] = b.lms;
                    prev_sf[ch] = b.sf;
                    try w.writeInt(u64, b.slice << shift, .big);
                }
            }
            if (c < channels) {
                const best = search.encodeSlice(pcm, (frame_start + s) * channels + c, channels, slice_len, state[c], prev_sf[c]);
                state[c] = best.lms;
                prev_sf[c] = best.sf;
                try w.writeInt(u64, best.slice << shift, .big);
            }
        }
    }
}

// ───────────────────────────── Tests ─────────────────────────────

test "QOA - encode/decode round trip" {
    const gpa = std.testing.allocator;
    for ([_]u16{ 1, 2, 3 }) |channels| for ([_]usize{ 1, 19, 20, 21, FRAME_LEN, FRAME_LEN + 7, 3 * FRAME_LEN - 1 }) |frames| {
        const n = frames * channels;
        const pcm = try gpa.alloc(i16, n);
        defer gpa.free(pcm);
        var prng: std.Random.DefaultPrng = .init(n);
        const random = prng.random();
        for (pcm, 0..) |*s, i| {
            const t: f64 = @floatFromInt(i / channels);
            const c: f64 = @floatFromInt(i % channels + 1);
            const tone = 12000 * @sin(t * 0.03 * c) + 4000 * @sin(t * 0.21);
            s.* = @intFromFloat(tone + @as(f64, @floatFromInt(random.intRangeAtMost(i16, -300, 300))));
        }
        const src: Audio = .{ .sample_rate = 44100, .channels = channels, .samples = .{ .i16 = pcm } };
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try encode(&src, &aw.writer, gpa);
        const bytes = aw.written();

        const slices = (frames + SLICE_LEN - 1) / SLICE_LEN;
        const n_frames = (frames + FRAME_LEN - 1) / FRAME_LEN;
        try std.testing.expectEqual(Header.SIZE + n_frames * (8 + 16 * channels) + slices * 8 * channels, bytes.len);

        const inf = try info(bytes);
        try std.testing.expectEqual(@as(u64, frames), inf.frames);
        try std.testing.expectEqual(channels, inf.channels);
        const out = try gpa.alloc(i16, n);
        defer gpa.free(out);
        try decodeInto(gpa, bytes, inf, std.mem.sliceAsBytes(out));

        // lossy: check signal-to-noise ratio
        var sig: f64 = 0;
        var noise: f64 = 0;
        for (pcm, out) |a, b| {
            const fa: f64 = @floatFromInt(a);
            const d: f64 = @floatFromInt(@as(i32, a) - b);
            sig += fa * fa;
            noise += d * d;
        }
        if (frames >= 100) {
            const snr = 10 * @log10(sig / @max(noise, 1));
            if (snr < 25) {
                std.debug.print("channels={} frames={} snr={d:.1} dB\n", .{ channels, frames, snr });
                return error.TestUnexpectedResult;
            }
        }
    };
}
