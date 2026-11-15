//! Test data, generated in memory at test time: the repository ships no audio files.
//!
//!   - `signal`: tones, a sweep and noise from a seeded PRNG (same seed, same samples)
//!   - `packWav`: RIFF / RF64 WAVE files packed field by field from the Microsoft RIFF WAVE
//!     and EBU RF64 layouts, independently of the library's WAV encoder
//!   - `mp3Header`, `silentFrame`, `xingFrame`, `id3v2`, `apev2`, `id3v1`: MPEG audio frames
//!     and tags built from ISO/IEC 11172-3 / 13818-3. A frame whose side info and main data
//!     are all zero holds no audio, so it decodes to exact silence.
//!
//! Test helpers only, not part of the API.
const std = @import("std");
const Audio = @import("root.zig");

// ───────────────────────────── signals ─────────────────────────────

/// Interleaved f64 samples in [-1, 1]: a tone per channel (220 Hz times the channel number),
/// a linear sweep from 100 Hz to 0.45 * the sample rate over the whole signal, and white
/// noise from `std.Random.DefaultPrng` seeded with `seed`. The first two samples are full
/// scale (+1, -1) so integer conversions clamp.
pub fn signal(gpa: std.mem.Allocator, sample_rate: u32, channels: u16, frames: usize, seed: u64) !Audio {
    const s = try gpa.alloc(f64, frames * channels);
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();
    const rate: f64 = @floatFromInt(sample_rate);
    const duration = @as(f64, @floatFromInt(@max(frames, 1))) / rate;
    const f_start = 100.0;
    const slope = (0.45 * rate - f_start) / duration; // Hz per second
    for (0..frames) |i| {
        const t = @as(f64, @floatFromInt(i)) / rate;
        const sweep = 0.2 * @sin(2 * std.math.pi * (f_start * t + 0.5 * slope * t * t));
        for (0..channels) |c| {
            const f0 = 220.0 * @as(f64, @floatFromInt(c + 1));
            const noise = 0.05 * (2 * random.float(f64) - 1);
            s[i * channels + c] = 0.4 * @sin(2 * std.math.pi * f0 * t) + sweep + noise;
        }
    }
    if (s.len > 0) s[0] = 1.0;
    if (s.len > 1) s[1] = -1.0;
    return .{ .sample_rate = sample_rate, .channels = channels, .samples = .{ .f64 = s } };
}

// ───────────────────────────── WAV ─────────────────────────────

pub const WavFormat = struct {
    /// 1 = PCM, 3 = IEEE float, 6 = A-law, 7 = mu-law
    code: u16,
    channels: u16,
    sample_rate: u32,
    /// container bytes per sample
    bytes: u16,
    /// set: WAVE_FORMAT_EXTENSIBLE carrying this many valid bits
    valid_bits: ?u16 = null,
    /// RF64 with a ds64 chunk (the RIFF and data sizes say 0xFFFFFFFF)
    rf64: bool = false,
};

/// A WAVE file around `data` (the sample bytes, already little-endian). Before `fmt ` sits a
/// LIST chunk of odd size (word padding), non-PCM formats get a `fact` chunk, and an odd-sized
/// data chunk gets its pad byte.
pub fn packWav(gpa: std.mem.Allocator, f: WavFormat, data: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    const block_align: u16 = f.channels * f.bytes;
    const frames: u32 = @intCast(data.len / block_align);
    const extensible = f.valid_bits != null;
    const fmt_len: u32 = if (extensible) 40 else if (f.code == 1) 16 else 18;
    const has_fact = f.code != 1;
    const list = "INFOx"; // 5 bytes: odd
    const pad = data.len & 1;
    const riff_len: u64 = 4 + (if (f.rf64) @as(u64, 8 + 28) else 0) + (8 + list.len + 1) + (8 + fmt_len) +
        (if (has_fact) @as(u64, 12) else 0) + 8 + data.len + pad;

    try w.writeAll(if (f.rf64) "RF64" else "RIFF");
    try w.writeInt(u32, if (f.rf64) 0xFFFF_FFFF else @intCast(riff_len), .little);
    try w.writeAll("WAVE");
    if (f.rf64) {
        try w.writeAll("ds64");
        try w.writeInt(u32, 28, .little);
        try w.writeInt(u64, riff_len, .little);
        try w.writeInt(u64, data.len, .little);
        try w.writeInt(u64, frames, .little);
        try w.writeInt(u32, 0, .little); // no table entries
    }
    try w.writeAll("LIST");
    try w.writeInt(u32, list.len, .little);
    try w.writeAll(list ++ "\x00");
    try w.writeAll("fmt ");
    try w.writeInt(u32, fmt_len, .little);
    try w.writeInt(u16, if (extensible) 0xFFFE else f.code, .little);
    try w.writeInt(u16, f.channels, .little);
    try w.writeInt(u32, f.sample_rate, .little);
    try w.writeInt(u32, f.sample_rate * block_align, .little);
    try w.writeInt(u16, block_align, .little);
    try w.writeInt(u16, f.bytes * 8, .little);
    if (f.valid_bits) |valid| {
        try w.writeInt(u16, 22, .little); // cbSize
        try w.writeInt(u16, valid, .little);
        try w.writeInt(u32, 0, .little); // channel mask: unspecified
        // KSDATAFORMAT_SUBTYPE_PCM / _IEEE_FLOAT / ...: the format code, then a fixed tail
        try w.writeInt(u16, f.code, .little);
        try w.writeAll("\x00\x00\x00\x00\x10\x00\x80\x00\x00\xAA\x00\x38\x9B\x71");
    } else if (fmt_len == 18) {
        try w.writeInt(u16, 0, .little); // cbSize
    }
    if (has_fact) {
        try w.writeAll("fact");
        try w.writeInt(u32, 4, .little);
        try w.writeInt(u32, frames, .little);
    }
    try w.writeAll("data");
    try w.writeInt(u32, if (f.rf64) 0xFFFF_FFFF else @intCast(data.len), .little);
    try w.writeAll(data);
    if (pad != 0) try w.writeByte(0);
    return aw.toOwnedSlice();
}

// ───────────────────────────── MP3 ─────────────────────────────

pub const MpegVersion = enum { mpeg1, mpeg2, mpeg25 };

pub const Frame = struct {
    version: MpegVersion = .mpeg1,
    layer: u2 = 3,
    /// 0 = free format (then `free_bytes` is the frame length without padding)
    kbps: u16,
    sample_rate: u32,
    mono: bool = false,
    padding: bool = false,
    /// protection bit 0: a 16-bit CRC follows the header (decoders may ignore it)
    crc: bool = false,
    free_bytes: u32 = 0,
};

// ISO/IEC 11172-3 2.4.2.3 and ISO/IEC 13818-3 2.4.2.3 bit rate tables (index 1..14)
const kbps_v1 = [3][14]u16{
    .{ 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448 }, // Layer I
    .{ 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384 }, // Layer II
    .{ 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320 }, // Layer III
};
const kbps_v2 = [3][14]u16{
    .{ 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256 }, // Layer I
    .{ 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 }, // Layer II
    .{ 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160 }, // Layer III
};

fn sampleRates(v: MpegVersion) [3]u32 {
    return switch (v) {
        .mpeg1 => .{ 44100, 48000, 32000 },
        .mpeg2 => .{ 22050, 24000, 16000 },
        .mpeg25 => .{ 11025, 12000, 8000 },
    };
}

/// The 4 header bytes. Panics on a bit rate / sample rate the version does not have.
pub fn mp3Header(f: Frame) [4]u8 {
    const rates = sampleRates(f.version);
    const sr_idx: u8 = @intCast(std.mem.indexOfScalar(u32, &rates, f.sample_rate).?);
    const table = if (f.version == .mpeg1) &kbps_v1 else &kbps_v2;
    const br_idx: u8 = if (f.kbps == 0) 0 else @intCast(std.mem.indexOfScalar(u16, &table[@as(usize, f.layer) - 1], f.kbps).? + 1);
    const version_bits: u8 = switch (f.version) {
        .mpeg1 => 0b11,
        .mpeg2 => 0b10,
        .mpeg25 => 0b00,
    };
    const layer_bits: u8 = 4 - @as(u8, f.layer); // Layer I = 0b11 ... Layer III = 0b01
    return .{
        0xFF,
        0xE0 | (version_bits << 3) | (layer_bits << 1) | @intFromBool(!f.crc),
        (br_idx << 4) | (sr_idx << 2) | (@as(u8, @intFromBool(f.padding)) << 1),
        // mono (0b11) or stereo (0b00); no mode extension, not copyrighted, original
        ((if (f.mono) @as(u8, 0b11) else 0b00) << 6) | 0x04,
    };
}

/// Samples per channel in one frame.
pub fn frameSamples(f: Frame) u32 {
    return switch (f.layer) {
        1 => 384,
        2 => 1152,
        3 => if (f.version == .mpeg1) 1152 else 576,
        0 => unreachable,
    };
}

/// Frame length in bytes, padding included (ISO/IEC 11172-3 2.4.3.1).
pub fn frameLen(f: Frame) u32 {
    if (f.kbps == 0) return f.free_bytes + @as(u32, if (f.padding) (if (f.layer == 1) 4 else 1) else 0);
    const bps = @as(u32, f.kbps) * 1000;
    return switch (f.layer) {
        1 => (12 * bps / f.sample_rate + @intFromBool(f.padding)) * 4,
        2 => 144 * bps / f.sample_rate + @intFromBool(f.padding),
        3 => (if (f.version == .mpeg1) @as(u32, 144) else 72) * bps / f.sample_rate + @intFromBool(f.padding),
        0 => unreachable,
    };
}

/// Layer III side info bytes.
pub fn sideInfoLen(f: Frame) u32 {
    return if (f.version == .mpeg1) (if (f.mono) 17 else 32) else (if (f.mono) 9 else 17);
}

/// A frame with all-zero side info / allocation and main data: no audio, decodes to silence.
pub fn silentFrame(w: *std.Io.Writer, f: Frame) !void {
    try w.writeAll(&mp3Header(f));
    try w.splatByteAll(0, frameLen(f) - 4);
}

pub const Xing = struct {
    /// "Xing" (VBR) or "Info" (CBR)
    tag: *const [4]u8 = "Info",
    frames: ?u32 = null,
    bytes: ?u32 = null,
    toc: bool = false,
    quality: ?u32 = null,
    /// LAME extension: encoder delay and padding (12 bits each)
    lame: ?struct { delay: u12, padding: u12 } = null,
};

/// A Layer III frame holding a Xing / Info header (and the LAME extension) after zero side
/// info: it carries no audio. The frame must be long enough for what `x` asks for.
pub fn xingFrame(w: *std.Io.Writer, f: Frame, x: Xing) !void {
    var buf: [2048]u8 = @splat(0);
    const len = frameLen(f);
    @memcpy(buf[0..4], &mp3Header(f));
    var p: usize = 4 + sideInfoLen(f) + @as(usize, if (f.crc) 2 else 0);
    @memcpy(buf[p..][0..4], x.tag);
    const flags: u32 = @as(u32, @intFromBool(x.frames != null)) | (@as(u32, @intFromBool(x.bytes != null)) << 1) |
        (@as(u32, @intFromBool(x.toc)) << 2) | (@as(u32, @intFromBool(x.quality != null)) << 3);
    std.mem.writeInt(u32, buf[p + 4 ..][0..4], flags, .big);
    p += 8;
    if (x.frames) |v| {
        std.mem.writeInt(u32, buf[p..][0..4], v, .big);
        p += 4;
    }
    if (x.bytes) |v| {
        std.mem.writeInt(u32, buf[p..][0..4], v, .big);
        p += 4;
    }
    if (x.toc) {
        for (buf[p..][0..100], 0..) |*b, i| b.* = @intCast(i * 255 / 99);
        p += 100;
    }
    if (x.quality) |v| {
        std.mem.writeInt(u32, buf[p..][0..4], v, .big);
        p += 4;
    }
    if (x.lame) |l| {
        @memcpy(buf[p..][0..9], "LAME3.100"); // the version string LAME writes (a format field)
        buf[p + 21] = @intCast(l.delay >> 4);
        buf[p + 22] = @intCast((@as(u32, l.delay & 0xF) << 4) | (l.padding >> 8));
        buf[p + 23] = @intCast(l.padding & 0xFF);
        p += 36;
    }
    std.debug.assert(p <= len);
    try w.writeAll(buf[0..len]);
}

/// An ID3v2.4 tag with `body` as its (opaque) content, optionally with the 10-byte footer.
pub fn id3v2(w: *std.Io.Writer, body: []const u8, footer: bool) !void {
    const n: u32 = @intCast(body.len);
    const size = [4]u8{ @intCast((n >> 21) & 0x7F), @intCast((n >> 14) & 0x7F), @intCast((n >> 7) & 0x7F), @intCast(n & 0x7F) };
    try w.writeAll("ID3\x04\x00");
    try w.writeByte(if (footer) 0x10 else 0);
    try w.writeAll(&size);
    try w.writeAll(body);
    if (footer) {
        try w.writeAll("3DI\x04\x00\x10");
        try w.writeAll(&size);
    }
}

/// An ID3v1 tag (128 bytes at the end of the file).
pub fn id3v1(w: *std.Io.Writer) !void {
    var tag: [128]u8 = @splat(0);
    @memcpy(tag[0..3], "TAG");
    @memcpy(tag[3..][0..5], "title");
    try w.writeAll(&tag);
}

/// An APEv2 tag with header, one text item and footer; its size field counts items + footer.
pub fn apev2(w: *std.Io.Writer) !void {
    const item = "\x05\x00\x00\x00" ++ "\x00\x00\x00\x00" ++ "Title\x00" ++ "hello";
    const header_flags: u32 = (1 << 31) | (1 << 29); // contains header, this is the header
    const footer_flags: u32 = 1 << 31; // contains header
    for ([_]u32{ header_flags, footer_flags }, 0..) |flags, k| {
        if (k == 1) try w.writeAll(item);
        try w.writeAll("APETAGEX");
        try w.writeInt(u32, 2000, .little); // version
        try w.writeInt(u32, item.len + 32, .little);
        try w.writeInt(u32, 1, .little); // item count
        try w.writeInt(u32, flags, .little);
        try w.splatByteAll(0, 8);
    }
}

/// The frames of an MP3 written by the library's encoder, without its leading Info frame.
pub fn withoutInfoFrame(mp3: []const u8) []const u8 {
    var sync: @import("Formats/mp3/header.zig").Sync = .{};
    const first = sync.next(mp3);
    std.debug.assert(first.len != 0 and first.skip == 0);
    return mp3[first.len..];
}

test "testdata: headers match the library's header reader" {
    const Header = @import("Formats/mp3/header.zig").Header;
    const cases = [_]Frame{
        .{ .kbps = 128, .sample_rate = 44100, .padding = true },
        .{ .kbps = 320, .sample_rate = 48000, .mono = true },
        .{ .version = .mpeg2, .kbps = 64, .sample_rate = 22050 },
        .{ .version = .mpeg25, .kbps = 8, .sample_rate = 8000, .mono = true },
        .{ .layer = 2, .kbps = 192, .sample_rate = 48000 },
        .{ .layer = 1, .kbps = 384, .sample_rate = 44100, .padding = true, .crc = true },
    };
    for (cases) |f| {
        const h = mp3Header(f);
        try std.testing.expect(Header.valid(&h));
        try std.testing.expectEqual(@as(u8, f.layer), Header.layer(&h));
        try std.testing.expectEqual(f.sample_rate, Header.sampleRateHz(&h));
        try std.testing.expectEqual(@as(u32, f.kbps), Header.bitrateKbps(&h));
        try std.testing.expectEqual(f.mono, Header.isMono(&h));
        try std.testing.expectEqual(f.crc, Header.isCrc(&h));
        try std.testing.expectEqual(frameSamples(f), Header.frameSamples(&h));
        try std.testing.expectEqual(frameLen(f), Header.frameBytes(&h, 0) + Header.padding(&h));
    }
}
