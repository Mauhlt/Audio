//! MP3 (MPEG-1/2/2.5 Layer III; Layer I and II streams decode too).
//! Encoding: CBR Layer III, see encoder.zig (`encodeWith` takes bit rate / stereo options).
//!
//! Output is interleaved f32. ID3v2 / ID3v1 / APEv2 tags are skipped, and the encoder
//! delay + padding stored in a LAME/Xing "Info" frame is trimmed (gapless), so a LAME
//! encode decodes to exactly as many samples as went in.
//!
//! Streams that switch between mono and stereo keep the first frame's channel count
//! (mono frames are duplicated, stereo frames are averaged).
const std = @import("std");
const Error = @import("../error.zig").Error;
const Info = @import("../../info.zig");
pub const decoder = @import("decoder.zig");
pub const encoder = @import("encoder.zig");
pub const EncodeOptions = encoder.Options;
const Audio = @import("../../root.zig");
const Decoder = decoder.Decoder;
const Header = @import("header.zig").Header;

/// Where the audio frames are, plus the gapless trim, found by scanning headers only.
pub const Stream = struct {
    /// first audio frame (after tags and the Xing/Info frame)
    start: usize,
    /// end of audio (before trailing tags)
    end: usize,
    sample_rate: u32,
    channels: u8,
    layer: u8,
    /// samples per channel the frames decode to, before trimming
    raw_frames: u64,
    /// samples per channel to drop at the start / end
    delay: u64 = 0,
    padding: u64 = 0,

    pub fn frames(self: Stream) u64 {
        return self.raw_frames -| (self.delay + self.padding);
    }

    pub fn scan(data: []const u8) !Stream {
        var start = skipId3v2(data);
        const end = trailingTagsStart(data, start);
        const audio = data[0..end];

        var sync: @import("header.zig").Sync = .{};
        var first = sync.next(audio[start..]);
        if (first.len == 0) return Error.MissingFrame;
        start += first.skip;
        const hdr = audio[start..][0..4];
        var s: Stream = .{
            .start = start,
            .end = end,
            .sample_rate = Header.sampleRateHz(hdr),
            .channels = if (Header.isMono(hdr)) 1 else 2,
            .layer = Header.layer(hdr),
            .raw_frames = 0,
        };
        if (parseXing(audio[start..][0..first.len])) |x| {
            s.delay = x.delay;
            s.padding = x.padding;
            start += first.len;
            s.start = start;
            sync = .{};
            first = sync.next(audio[start..]);
        }
        var pos = start;
        var found = first;
        while (found.len != 0) {
            pos += found.skip;
            s.raw_frames += Header.frameSamples(audio[pos..][0..4]);
            pos += found.len;
            found = sync.next(audio[pos..]);
        }
        if (s.raw_frames == 0) return Error.MissingFrame;
        return s;
    }
};

pub fn info(data: []const u8) !Info {
    const s: Stream = try .scan(data);
    return .{ .sample_rate = s.sample_rate, .channels = s.channels, .frames = s.frames(), .tag = .f32 };
}

/// `scratch` holds the ~20 KiB decoder state.
pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out_bytes: []u8) !void {
    if (inf.tag != .f32) return Error.UnsupportedFormat;
    const s: Stream = try .scan(data);
    if (s.channels != inf.channels or s.frames() != inf.frames) return Error.InconsistentFrames;
    const out = std.mem.bytesAsSlice(f32, out_bytes);
    const nch: usize = s.channels;

    const dec = try scratch.create(Decoder);
    defer scratch.destroy(dec);
    dec.* = .{};
    var pcm: [decoder.MAX_FRAME_SAMPLES * 2]f32 = undefined;

    const audio = data[s.start..s.end];
    var pos: usize = 0;
    var t: u64 = 0; // sample index (per channel) in the untrimmed stream
    var written: usize = 0; // samples written to `out`
    const keep_end = s.raw_frames - s.padding;
    while (pos < audio.len and written < out.len) {
        var fi: decoder.FrameInfo = undefined;
        const n = dec.decodeFrame(audio[pos..], &pcm, &fi);
        if (fi.frame_bytes == 0) break;
        pos += fi.frame_bytes;
        if (fi.layer == 0) break; // no more frames
        const frame_samples: usize = fi.frame_samples;
        const fch: usize = fi.channels;
        // undecodable frame (e.g. missing bit reservoir): silence keeps the timing
        if (n == 0) @memset(pcm[0 .. frame_samples * fch], 0);
        for (0..frame_samples) |k| {
            const ti = t + k;
            if (ti < s.delay) continue;
            if (ti >= keep_end or written >= out.len) break;
            const src = pcm[k * fch ..][0..fch];
            if (fch == nch) {
                @memcpy(out[written..][0..nch], src);
            } else if (fch == 1) {
                out[written] = src[0];
                out[written + 1] = src[0];
            } else {
                out[written] = (src[0] + src[1]) * 0.5;
            }
            written += nch;
        }
        t += frame_samples;
    }
    @memset(out[written..], 0);
}

/// Encodes with default options (bit rate from the sample rate and channel count).
pub fn encode(audio: *const Audio, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    return encodeWith(audio, w, gpa, .{});
}

pub fn encodeWith(audio: *const Audio, w: *std.Io.Writer, gpa: std.mem.Allocator, opts: EncodeOptions) !void {
    const converted = if (audio.samples == .f32) null else try audio.samples.convert(.f32, gpa);
    defer if (converted) |c| c.deinit(gpa);
    const pcm = (converted orelse audio.samples).f32;
    try encoder.encode(gpa, w, pcm, audio.sample_rate, audio.channels, opts);
}

// ───────────────────────────── tags ─────────────────────────────

/// Offset of the first byte after any leading ID3v2 tags.
fn skipId3v2(data: []const u8) usize {
    var pos: usize = 0;
    while (data.len - pos >= 10 and std.mem.eql(u8, data[pos..][0..3], "ID3")) {
        const h = data[pos..][0..10];
        var size: usize = (@as(usize, h[6] & 0x7F) << 21) | (@as(usize, h[7] & 0x7F) << 14) |
            (@as(usize, h[8] & 0x7F) << 7) | (h[9] & 0x7F);
        if (h[5] & 0x10 != 0) size += 10; // footer
        pos = @min(data.len, pos + 10 + size);
    }
    return pos;
}

/// Start of trailing ID3v1 / APEv2 tags (or `data.len`).
fn trailingTagsStart(data: []const u8, min: usize) usize {
    var end = data.len;
    if (end - min > 128 and std.mem.eql(u8, data[end - 128 ..][0..3], "TAG")) end -= 128;
    if (end - min > 32 and std.mem.eql(u8, data[end - 32 ..][0..8], "APETAGEX")) {
        const tag_size = std.mem.readInt(u32, data[end - 32 + 12 ..][0..4], .little);
        if (32 + @as(u64, tag_size) < end - min) end -= 32 + tag_size;
    }
    return end;
}

const Xing = struct { delay: u64, padding: u64 };

/// A Xing/Info frame carries no audio. Returns the LAME gapless info if `frame` is one.
fn parseXing(frame: []const u8) ?Xing {
    if (frame.len < 4 or Header.layer(frame) != 3) return null;
    const side_info: usize = if (Header.isMpeg1(frame))
        (if (Header.isMono(frame)) 17 else 32)
    else
        (if (Header.isMono(frame)) 9 else 17);
    var p: usize = 4 + side_info + @as(usize, if (Header.isCrc(frame)) 2 else 0);
    if (frame.len < p + 8) return null;
    const tag = frame[p..][0..4];
    if (!std.mem.eql(u8, tag, "Xing") and !std.mem.eql(u8, tag, "Info")) return null;
    const flags = frame[p + 7];
    p += 8;
    if (flags & 0x01 != 0) p += 4; // frames
    if (flags & 0x02 != 0) p += 4; // bytes
    if (flags & 0x04 != 0) p += 100; // TOC
    if (flags & 0x08 != 0) p += 4; // quality
    var x: Xing = .{ .delay = 0, .padding = 0 };
    // LAME extension: 9-byte encoder version, then (at +21) 12-bit delay and 12-bit padding
    if (frame.len >= p + 36 and frame[p] != 0) {
        const d = frame[p + 21 ..][0..3];
        const enc_delay = (@as(u64, d[0]) << 4) | (d[1] >> 4);
        const enc_padding = (@as(u64, d[1] & 0xF) << 8) | d[2];
        // the decoder itself adds 528 + 1 samples of delay
        x.delay = enc_delay + 529;
        x.padding = enc_padding -| 529;
    }
    return x;
}

test "skip tags" {
    const id3 = "ID3\x04\x00\x00\x00\x00\x00\x05" ++ "abcde";
    try std.testing.expectEqual(@as(usize, 15), skipId3v2(id3 ++ "\xFF\xFB"));
    var buf: [300]u8 = @splat(0);
    @memcpy(buf[300 - 128 ..][0..3], "TAG");
    try std.testing.expectEqual(@as(usize, 172), trailingTagsStart(&buf, 0));
}
