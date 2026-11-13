//! RIFF / RF64 chunk walking and the `fmt ` chunk.
const std = @import("std");
const Error = @import("../error.zig").Error;
const SampleTag = @import("../../Samples/samples.zig").SampleTag;

pub const FormatCode = enum(u16) {
    pcm = 0x0001,
    ieee_float = 0x0003,
    alaw = 0x0006,
    mulaw = 0x0007,
    extensible = 0xFFFE,
    _,
};

/// Bytes 2..16 of every KSDATAFORMAT_SUBTYPE_* GUID; bytes 0..2 hold the format code.
pub const guid_tail = [14]u8{ 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 };

const Header = @This();

format: FormatCode, // never .extensible: resolved to the sub-format
channels: u16,
sample_rate: u32,
block_align: u16,
/// container size of one sample, in bits
bits_per_sample: u16,
/// meaningful bits (<= bits_per_sample)
valid_bits: u16,
channel_mask: u32 = 0,
/// location of the sample data
data_offset: usize,
data_len: usize,

pub fn frames(self: Header) u64 {
    return self.data_len / self.block_align;
}

/// Layout the samples decode to.
pub fn sampleTag(self: Header) !SampleTag {
    return switch (self.format) {
        .pcm => switch (self.bits_per_sample) {
            8 => .u8,
            16 => .i16,
            24 => .i24,
            32 => .i32,
            else => Error.UnsupportedBitsPerSample,
        },
        .ieee_float => switch (self.bits_per_sample) {
            32 => .f32,
            64 => .f64,
            else => Error.UnsupportedBitsPerSample,
        },
        .alaw, .mulaw => if (self.bits_per_sample == 8) .i16 else Error.UnsupportedBitsPerSample,
        else => Error.UnsupportedFormat,
    };
}

pub fn parse(data: []const u8) !Header {
    if (data.len < 12) return Error.UnexpectedEndOfData;
    const rf64 = std.mem.eql(u8, data[0..4], "RF64");
    if (!rf64 and !std.mem.eql(u8, data[0..4], "RIFF")) return Error.UnexpectedSignature;
    if (!std.mem.eql(u8, data[8..12], "WAVE")) return Error.UnexpectedSignature;

    var hdr: ?Header = null;
    var ds64_data_len: ?u64 = null;
    var pos: usize = 12;
    while (data.len - pos >= 8) {
        const id = data[pos..][0..4];
        const size32 = readLe(u32, data[pos + 4 ..]);
        const body = pos + 8;
        const remaining = data.len - body;
        var size: u64 = size32;
        if (std.mem.eql(u8, id, "data")) {
            var h = hdr orelse return Error.MissingFormatChunk;
            if (size32 == 0xFFFF_FFFF) size = ds64_data_len orelse remaining;
            // truncated / still-being-written files: keep whole blocks only
            const len: usize = @intCast(@min(size, remaining));
            h.data_offset = body;
            h.data_len = len - len % h.block_align;
            return h;
        }
        if (size > remaining) return Error.InvalidChunkLen;
        const chunk = data[body..][0..@intCast(size)];
        if (std.mem.eql(u8, id, "fmt ")) {
            hdr = try parseFmt(chunk);
        } else if (rf64 and std.mem.eql(u8, id, "ds64")) {
            if (chunk.len < 24) return Error.InvalidChunkLen;
            ds64_data_len = readLe(u64, chunk[8..]);
        }
        pos = body + @as(usize, @intCast(size));
        pos += pos & 1; // chunks are word aligned
        if (pos > data.len) break;
    }
    return if (hdr == null) Error.MissingFormatChunk else Error.MissingDataChunk;
}

fn parseFmt(chunk: []const u8) !Header {
    if (chunk.len < 16) return Error.InvalidChunkLen;
    var format: FormatCode = @fromBackingInt(@intCast(readLe(u16, chunk[0..])));
    const channels = readLe(u16, chunk[2..]);
    const sample_rate = readLe(u32, chunk[4..]);
    const block_align = readLe(u16, chunk[12..]);
    const bits = readLe(u16, chunk[14..]);
    var valid_bits = bits;
    var mask: u32 = 0;
    if (format == .extensible) {
        if (chunk.len < 40) return Error.InvalidChunkLen;
        valid_bits = readLe(u16, chunk[18..]);
        mask = readLe(u32, chunk[20..]);
        if (!std.mem.eql(u8, chunk[26..40], &guid_tail)) return Error.UnsupportedFormat;
        format = @fromBackingInt(@intCast(readLe(u16, chunk[24..])));
        if (valid_bits == 0) valid_bits = bits;
    }
    if (channels == 0) return Error.InvalidChannels;
    if (sample_rate == 0) return Error.InvalidSampleRate;
    if (bits == 0 or valid_bits > bits) return Error.InvalidBitsPerSample;
    // Some writers store e.g. 20 bits in 3 bytes but report bits=20: trust block_align.
    if (block_align == 0 or block_align % channels != 0) return Error.InvalidBlockAlign;
    const container: u16 = (block_align / channels) * 8;
    if (container < bits) return Error.InvalidBlockAlign;
    return .{
        .format = format,
        .channels = channels,
        .sample_rate = sample_rate,
        .block_align = block_align,
        .bits_per_sample = container,
        .valid_bits = @min(valid_bits, container),
        .channel_mask = mask,
        .data_offset = 0,
        .data_len = 0,
    };
}

/// Speaker layout WAVE_FORMAT_EXTENSIBLE files get by default (0 = unspecified).
pub fn defaultChannelMask(channels: u16) u32 {
    return switch (channels) {
        1 => 0x4, // FC
        2 => 0x3, // FL FR
        3 => 0x7, // FL FR FC
        4 => 0x33, // FL FR BL BR
        5 => 0x37, // FL FR FC BL BR
        6 => 0x3F, // 5.1
        7 => 0x13F, // 6.1
        8 => 0x63F, // 7.1
        else => 0,
    };
}

pub fn readLe(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0 .. @bitSizeOf(T) / 8], .little);
}

test "WAV header - edge cases" {
    // odd-sized chunk before fmt (word padding), data chunk with size 0xFFFFFFFF (streamed)
    const bytes = "RIFF\x00\x00\x00\x00WAVE" ++
        "LIST\x03\x00\x00\x00abc\x00" ++
        "fmt \x10\x00\x00\x00\x01\x00\x01\x00\x44\xAC\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00" ++
        "data\xFF\xFF\xFF\xFF\x01\x00\xFF\xFF\x07";
    const h = try parse(bytes);
    try std.testing.expectEqual(@as(u64, 2), h.frames()); // trailing odd byte dropped
    try std.testing.expectEqual(SampleTag.i16, try h.sampleTag());

    try std.testing.expectError(Error.UnexpectedSignature, parse("RIFX\x00\x00\x00\x00WAVE"));
    try std.testing.expectError(Error.MissingFormatChunk, parse("RIFF\x00\x00\x00\x00WAVEdata\x00\x00\x00\x00"));
    try std.testing.expectError(Error.MissingDataChunk, parse("RIFF\x00\x00\x00\x00WAVE" ++
        "fmt \x10\x00\x00\x00\x01\x00\x01\x00\x44\xAC\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00"));
}
