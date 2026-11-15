//! WAV (RIFF WAVE) and RF64.
//!
//! Read:  PCM 8/16/24/32-bit (any valid-bit count inside those containers), IEEE float 32/64,
//!        A-law and mu-law (decoded to i16), WAVE_FORMAT_EXTENSIBLE, RF64 (> 4 GiB).
//! Write: every `SampleTag` (u8/i16/i24/i32 -> PCM, f32/f64 -> IEEE float). Files with more
//!        than 2 channels use WAVE_FORMAT_EXTENSIBLE; data past 4 GiB is written as RF64.
const std = @import("std");
const native_endian = @import("builtin").cpu.arch.endian();
const Error = @import("../error.zig").Error;
const Audio = @import("../../root.zig");
const Info = @import("../../info.zig");
const simd = @import("../../Samples/simd.zig");
pub const Header = @import("header.zig");
pub const g711 = @import("g711.zig");
const FormatCode = Header.FormatCode;

pub fn info(data: []const u8) !Info {
    const hdr: Header = try .parse(data);
    return .{
        .sample_rate = hdr.sample_rate,
        .channels = hdr.channels,
        .frames = hdr.frames(),
        .tag = try hdr.sampleTag(),
    };
}

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    _ = scratch;
    const hdr: Header = try .parse(data);
    const tag = try hdr.sampleTag();
    if (tag != inf.tag or hdr.frames() != inf.frames or hdr.channels != inf.channels) return Error.InconsistentFrames;
    const n = try inf.nSamples();
    const src = data[hdr.data_offset..][0..hdr.data_len];
    switch (hdr.format) {
        .alaw => g711.expand(&g711.alaw_table, src[0..n], std.mem.bytesAsSlice(i16, out)),
        .mulaw => g711.expand(&g711.mulaw_table, src[0..n], std.mem.bytesAsSlice(i16, out)),
        else => switch (tag) {
            .u8 => @memcpy(out, src[0..n]),
            .i24 => simd.unpackI24Little(src[0 .. 3 * n], @alignCast(std.mem.bytesAsSlice(i24, out))),
            inline .i16, .i32, .f32, .f64 => |t| simd.copyLittle(t.Type(), src[0..out.len], @alignCast(std.mem.bytesAsSlice(t.Type(), out))),
        },
    }
}

pub fn encode(audio: *const Audio, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    _ = gpa;
    const tag = std.meta.activeTag(audio.samples);
    if (audio.channels == 0) return Error.InvalidChannels;
    if (audio.sample_rate == 0) return Error.InvalidSampleRate;
    if (audio.samples.len() % audio.channels != 0) return Error.InvalidBufferLen;
    const file_bytes: u16 = switch (tag) {
        .i24 => 3,
        else => @intCast(tag.bytesPerSample()),
    };
    const block_align = std.math.mul(u16, audio.channels, file_bytes) catch return Error.UnsupportedChannels;
    // caller-supplied: rate * block_align can overflow the u32 field (checked before writing)
    const byte_rate = std.math.mul(u32, audio.sample_rate, block_align) catch return Error.UnsupportedSampleRate;
    const data_len: u64 = @as(u64, audio.samples.len()) * file_bytes;
    const format: FormatCode = if (tag.isFloat()) .ieee_float else .pcm;
    const extensible = audio.channels > 2;
    const fmt_len: u32 = if (extensible) 40 else if (format == .pcm) 16 else 18;
    const has_fact = format != .pcm;
    const pad = data_len & 1;
    const header_len: u64 = 4 + (8 + fmt_len) + @as(u64, if (has_fact) 12 else 0) + 8;
    const riff_len = header_len + data_len + pad;
    const rf64 = riff_len > 0xFFFF_FFFF;
    const frames = audio.samples.len() / audio.channels;

    try w.writeAll(if (rf64) "RF64" else "RIFF");
    try w.writeInt(u32, if (rf64) 0xFFFF_FFFF else @intCast(riff_len), .little);
    try w.writeAll("WAVE");
    if (rf64) {
        try w.writeAll("ds64");
        try w.writeInt(u32, 28, .little);
        try w.writeInt(u64, riff_len + 36, .little);
        try w.writeInt(u64, data_len, .little);
        try w.writeInt(u64, frames, .little);
        try w.writeInt(u32, 0, .little); // no table entries
    }
    try w.writeAll("fmt ");
    try w.writeInt(u32, fmt_len, .little);
    try w.writeInt(u16, @backingInt(if (extensible) .extensible else format), .little);
    try w.writeInt(u16, audio.channels, .little);
    try w.writeInt(u32, audio.sample_rate, .little);
    try w.writeInt(u32, byte_rate, .little);
    try w.writeInt(u16, block_align, .little);
    try w.writeInt(u16, file_bytes * 8, .little);
    if (extensible) {
        try w.writeInt(u16, 22, .little);
        try w.writeInt(u16, file_bytes * 8, .little); // valid bits
        try w.writeInt(u32, Header.defaultChannelMask(audio.channels), .little);
        try w.writeInt(u16, @backingInt(format), .little);
        try w.writeAll(&Header.guid_tail);
    } else if (fmt_len == 18) {
        try w.writeInt(u16, 0, .little);
    }
    if (has_fact) {
        try w.writeAll("fact");
        try w.writeInt(u32, 4, .little);
        try w.writeInt(u32, @intCast(@min(frames, 0xFFFF_FFFF)), .little);
    }
    try w.writeAll("data");
    try w.writeInt(u32, if (rf64) 0xFFFF_FFFF else @intCast(data_len), .little);
    switch (audio.samples) {
        .u8 => |s| try w.writeAll(s),
        .i24 => |s| {
            // pack a chunk at a time
            const chunk_len = 4096;
            var buf: [3 * chunk_len]u8 = undefined;
            var i: usize = 0;
            while (i < s.len) : (i += chunk_len) {
                const chunk = s[i..@min(s.len, i + chunk_len)];
                simd.packI24Little(chunk, buf[0 .. 3 * chunk.len]);
                try w.writeAll(buf[0 .. 3 * chunk.len]);
            }
        },
        inline else => |s| if (native_endian == .little) {
            try w.writeAll(std.mem.sliceAsBytes(s));
        } else for (s) |v| {
            const U = @Int(.unsigned, @bitSizeOf(@TypeOf(v)));
            try w.writeInt(U, @bitCast(v), .little);
        },
    }
    if (pad != 0) try w.writeByte(0);
}

test "WAV - decode edge cases" {
    // streamed data chunk (size 0xFFFFFFFF) with a trailing odd byte
    const bytes = "RIFF\x00\x00\x00\x00WAVE" ++
        "fmt \x10\x00\x00\x00\x01\x00\x01\x00\x44\xAC\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00" ++
        "data\xFF\xFF\xFF\xFF\x01\x00\xFF\xFF\x07";
    const inf = try info(bytes);
    var out: [4]u8 align(2) = undefined;
    try decodeInto(std.testing.allocator, bytes, inf, &out);
    try std.testing.expectEqualSlices(i16, &.{ 1, -1 }, std.mem.bytesAsSlice(i16, &out));
}

test "WAV - encode rejects a byte rate that overflows u32" {
    const gpa = std.testing.allocator;
    var s = [_]f64{ 0, 0 };
    // 0xFFFF_FFFF Hz * 16 bytes per frame (2 x f64) does not fit the u32 byte-rate field
    const a: Audio = .{ .sample_rate = 0xFFFF_FFFF, .channels = 2, .samples = .{ .f64 = &s } };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.testing.expectError(Error.UnsupportedSampleRate, encode(&a, &aw.writer, gpa));
    try std.testing.expectEqual(@as(usize, 0), aw.written().len); // nothing written
}
