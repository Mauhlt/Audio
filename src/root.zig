//! Audio = interleaved samples + sample rate + channel count.
//!
//! Every supported format lives in `Formats/<fmt>/<fmt>.zig` and exposes the same fns:
//!     info(data: []const u8) !Info                                  -- parse headers only
//!     decodeInto(scratch, data, info: Info, out: []u8) !void        -- decode into caller memory
//!     encode(audio: *const Audio, w: *std.Io.Writer, gpa) !void     -- (only if writable)
//! `decode` / `read` below are thin wrappers that allocate the output for you.
const std = @import("std");
const misc = @import("misc.zig");

pub const samples_mod = @import("Samples/samples.zig");
pub const Samples = samples_mod.Samples;
pub const SampleTag = samples_mod.SampleTag;
pub const Info = @import("info.zig");
pub const AudioTag = misc.AudioTag;
pub const tagFromExt = misc.tagFromExt;
pub const tagFromMagic = misc.tagFromMagic;

pub const WAV = @import("Formats/wav/wav.zig");
pub const QOA = @import("Formats/qoa/qoa.zig");
pub const MP3 = @import("Formats/mp3/mp3.zig");

const Audio = @This();

sample_rate: u32,
channels: u16,
/// Interleaved: frame `i`, channel `c` is at `i * channels + c`.
samples: Samples,

/// Codec module for a format, or null if unsupported.
pub fn Codec(comptime tag: AudioTag) ?type {
    return switch (tag) {
        .wav => WAV,
        .qoa => QOA,
        .mp3 => MP3,
        .aac, .aiff, .flac, .ogg, .opus => null,
    };
}

pub fn canDecode(tag: AudioTag) bool {
    return switch (tag) {
        inline else => |t| Codec(t) != null,
    };
}

pub fn canEncode(tag: AudioTag) bool {
    return switch (tag) {
        inline else => |t| if (Codec(t)) |C| @hasDecl(C, "encode") else false,
    };
}

pub fn info(tag: AudioTag, data: []const u8) !Info {
    switch (tag) {
        inline else => |t| {
            const C = Codec(t) orelse return error.Unsupported;
            return C.info(data);
        },
    }
}

/// Decodes into `out` (length must be `inf.byteLen()`), laid out as `inf.tag` samples.
/// `scratch` holds temporaries only and is NOT freed piecewise: pass an arena.
pub fn decodeInto(
    tag: AudioTag,
    scratch: std.mem.Allocator,
    data: []const u8,
    inf: Info,
    out: []u8,
) !void {
    if (out.len != try inf.byteLen()) return error.InvalidBufferLen;
    switch (tag) {
        inline else => |t| {
            const C = Codec(t) orelse return error.Unsupported;
            return C.decodeInto(scratch, data, inf, out);
        },
    }
}

pub fn decode(tag: AudioTag, gpa: std.mem.Allocator, data: []const u8) !Audio {
    const inf = try info(tag, data);
    const samples: Samples = try .alloc(inf.tag, gpa, try inf.nSamples());
    errdefer samples.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try decodeInto(tag, arena.allocator(), data, inf, samples.asBytes());
    return .{ .sample_rate = inf.sample_rate, .channels = inf.channels, .samples = samples };
}

/// Like `decode`, but the format is detected from the file's first bytes.
pub fn decodeAny(gpa: std.mem.Allocator, data: []const u8) !Audio {
    const tag = tagFromMagic(data) orelse return error.UnknownFormat;
    return decode(tag, gpa, data);
}

pub fn encode(self: *const Audio, tag: AudioTag, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    switch (tag) {
        inline else => |t| {
            const C = Codec(t) orelse return error.Unsupported;
            if (!@hasDecl(C, "encode")) return error.UnsupportedEncode;
            try C.encode(self, w, gpa);
            try w.flush();
        },
    }
}

/// Samples per channel.
pub fn frames(self: *const Audio) usize {
    return if (self.channels == 0) 0 else self.samples.len() / self.channels;
}

/// Duration in seconds.
pub fn seconds(self: *const Audio) f64 {
    return @as(f64, @floatFromInt(self.frames())) / @as(f64, @floatFromInt(self.sample_rate));
}

pub fn copy(self: *const Audio, gpa: std.mem.Allocator) !Audio {
    return .{ .sample_rate = self.sample_rate, .channels = self.channels, .samples = try self.samples.dupe(gpa) };
}

/// Returns a new audio buffer with samples converted to `tag`.
pub fn convert(self: *const Audio, tag: SampleTag, gpa: std.mem.Allocator) !Audio {
    return .{ .sample_rate = self.sample_rate, .channels = self.channels, .samples = try self.samples.convert(tag, gpa) };
}

pub fn deinit(self: Audio, gpa: std.mem.Allocator) void {
    self.samples.deinit(gpa);
}

pub fn format(self: *const Audio, w: *std.Io.Writer) !void {
    try w.print("\nAudio:\n", .{});
    try w.print("Sample rate: {} Hz\n", .{self.sample_rate});
    try w.print("Channels: {}\n", .{self.channels});
    try w.print("Frames: {} ({d:.3} s)\n", .{ self.frames(), self.seconds() });
    try w.print("Samples: {t}\n", .{self.samples});
}

pub const PathType = enum(u8) {
    cwd, // path = path from cwd/terminal to file
    dir, // path = path from starting dir to file
    abs, // path = abs path from root to file
};

pub const ReadArgs = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir = undefined,
    filepath: []const u8,
    path_type: PathType = .cwd,
};

pub fn openFile(io: std.Io, dir: std.Io.Dir, path: []const u8, path_type: PathType) !std.Io.File {
    return switch (path_type) {
        .abs => std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }),
        .cwd => std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }),
        .dir => dir.openFile(io, path, .{ .mode = .read_only }),
    };
}

/// Reads + decodes a file; format is chosen from the extension.
pub fn read(args: ReadArgs) !Audio {
    const tag = try tagFromExt(args.filepath);
    if (!canDecode(tag)) return error.Unsupported;
    var file = try openFile(args.io, args.dir, args.filepath, args.path_type);
    defer file.close(args.io);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(args.gpa);
    const data = try misc.readFileInto(args.io, args.gpa, file, &buf);
    return decode(tag, args.gpa, data);
}

/// Encodes + writes a file; format is chosen from the extension.
pub fn write(self: *const Audio, io: std.Io, gpa: std.mem.Allocator, filepath: []const u8) !void {
    const tag = try tagFromExt(filepath);
    if (!canEncode(tag)) return error.UnsupportedEncode;
    var file = try std.Io.Dir.cwd().createFile(io, filepath, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try self.encode(tag, &writer.interface, gpa);
}

// ───────────────────────────── Tests ─────────────────────────────

test {
    _ = @import("misc.zig");
    _ = @import("Samples/samples.zig");
    _ = @import("Samples/simd.zig");
    _ = @import("Formats/wav/header.zig");
    _ = @import("Formats/wav/g711.zig");
    _ = @import("Formats/qoa/lms.zig");
    _ = @import("Formats/qoa/search.zig");
    _ = @import("Formats/mp3/decoder.zig");
    _ = @import("Formats/mp3/header.zig");
    _ = @import("Formats/mp3/synth.zig");
    _ = @import("Formats/mp3/layer3.zig");
    _ = @import("Formats/mp3/analysis.zig");
    _ = @import("Formats/mp3/bitwriter.zig");
    _ = @import("Formats/mp3/huffman.zig");
    _ = @import("Formats/mp3/quantize.zig");
    _ = @import("Formats/mp3/psy.zig");
    _ = @import("testdata.zig");
    inline for (.{ WAV, QOA, MP3 }) |C| std.testing.refAllDecls(C);
}

// Test data is generated in memory (`testdata.zig`); the repository ships no audio files.
const testdata = @import("testdata.zig");

/// Test helper (not API): max and mean absolute difference between two buffers, as floats.
fn diff(a: Samples, b: Samples) struct { max: f64, mean: f64 } {
    std.debug.assert(a.len() == b.len());
    var max: f64 = 0;
    var total: f64 = 0;
    for (0..a.len()) |i| {
        const d = @abs(a.getF64(i) - b.getF64(i));
        max = @max(max, d);
        total += d;
    }
    return .{ .max = max, .mean = if (a.len() == 0) 0 else total / @as(f64, @floatFromInt(a.len())) };
}

// encode -> file -> decode, for every sample type WAV can store
test "WAV - write round trip, every sample type" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_]u16{ 1, 2, 6 }) |channels| {
        const tone = try testdata.signal(gpa, 44100, channels, 1001, channels);
        defer tone.deinit(gpa);
        inline for (comptime std.enums.values(SampleTag)) |tag| {
            const a = try tone.convert(tag, gpa);
            defer a.deinit(gpa);
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            try a.encode(.wav, &aw.writer, gpa);
            try tmp.dir.writeFile(io, .{ .sub_path = "t.wav", .data = aw.written() });
            const b = try read(.{ .io = io, .gpa = gpa, .dir = tmp.dir, .filepath = "t.wav", .path_type = .dir });
            defer b.deinit(gpa);
            try std.testing.expectEqual(a.sample_rate, b.sample_rate);
            try std.testing.expectEqual(a.channels, b.channels);
            try std.testing.expectEqual(tag, std.meta.activeTag(b.samples));
            try std.testing.expectEqualSlices(u8, a.samples.asBytes(), b.samples.asBytes());
        }
    }
}

// Files packed field by field (`testdata.packWav`, not this library's encoder) decode to exactly
// the samples packed into them: every PCM / float layout, WAVE_FORMAT_EXTENSIBLE (also with
// fewer valid bits than the container), RF64, odd-sized chunks and the data pad byte.
test "WAV - decode hand-packed files" {
    const gpa = std.testing.allocator;
    const src = try testdata.signal(gpa, 44100, 3, 999, 1); // 3 x 999: odd data sizes
    defer src.deinit(gpa);
    const Case = struct { tag: SampleTag, code: u16, valid_bits: ?u16 = null, rf64: bool = false };
    const cases = [_]Case{
        .{ .tag = .u8, .code = 1 },
        .{ .tag = .i16, .code = 1 },
        .{ .tag = .i24, .code = 1 },
        .{ .tag = .i32, .code = 1 },
        .{ .tag = .f32, .code = 3 },
        .{ .tag = .f64, .code = 3 },
        .{ .tag = .i24, .code = 1, .valid_bits = 24 },
        .{ .tag = .i24, .code = 1, .valid_bits = 20 }, // 20 bits, left-justified in 3 bytes
        .{ .tag = .f32, .code = 3, .valid_bits = 32 },
        .{ .tag = .i16, .code = 1, .rf64 = true },
        .{ .tag = .f64, .code = 3, .valid_bits = 64, .rf64 = true },
    };
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    for (cases) |case| {
        // quantize here (not with the library's conversions) and pack little-endian
        const expected: Samples = try .alloc(case.tag, gpa, src.samples.len());
        defer expected.deinit(gpa);
        bytes.clearRetainingCapacity();
        switch (expected) {
            inline else => |e, t| for (e, src.samples.f64) |*d, x| {
                const D = @TypeOf(d.*);
                d.* = switch (t) {
                    .u8 => @intFromFloat(@round(x * 127) + 128),
                    .f32 => @floatCast(x),
                    .f64 => x,
                    .i16, .i24, .i32 => blk: {
                        const bits: u6 = @intCast(case.valid_bits orelse @bitSizeOf(D));
                        const full: f64 = @floatFromInt((@as(i64, 1) << (bits - 1)) - 1);
                        const q: i64 = @intFromFloat(@round(x * full));
                        break :blk @intCast(q << (@bitSizeOf(D) - bits));
                    },
                };
                var le: [@bitSizeOf(D) / 8]u8 = undefined;
                std.mem.writeInt(@Int(.unsigned, @bitSizeOf(D)), &le, @bitCast(d.*), .little);
                try bytes.appendSlice(gpa, &le);
            },
        }
        const file = try testdata.packWav(gpa, .{
            .code = case.code,
            .channels = src.channels,
            .sample_rate = src.sample_rate,
            .bytes = case.tag.bits() / 8, // file container: i24 takes 3 bytes
            .valid_bits = case.valid_bits,
            .rf64 = case.rf64,
        }, bytes.items);
        defer gpa.free(file);
        const a = try decode(.wav, gpa, file);
        defer a.deinit(gpa);
        try std.testing.expectEqual(src.sample_rate, a.sample_rate);
        try std.testing.expectEqual(src.channels, a.channels);
        try std.testing.expectEqual(case.tag, std.meta.activeTag(a.samples));
        try std.testing.expectEqual(expected.len(), a.samples.len());
        const d = diff(expected, a.samples);
        if (d.max != 0) {
            std.debug.print("{t} (code {}, valid bits {?}, rf64 {}): max diff {e}\n", .{ case.tag, case.code, case.valid_bits, case.rf64, d.max });
            return error.TestExpectedEqual;
        }
    }
}

// Every A-law / mu-law code, against the expansion written the way ITU-T G.711 tabulates it
// (sign, 3-bit segment, 4-bit step), not the way `g711.zig` computes it.
test "WAV - decode hand-packed G.711 files" {
    const gpa = std.testing.allocator;
    var codes: [2 * 256 + 2 * 61]u8 = undefined; // stereo: every code, then seeded random ones
    for (codes[0..512], 0..) |*c, i| c.* = @truncate(i);
    var prng: std.Random.DefaultPrng = .init(711);
    prng.random().bytes(codes[512..]);
    for ([_]u16{ 6, 7 }) |code| {
        const file = try testdata.packWav(gpa, .{ .code = code, .channels = 2, .sample_rate = 8000, .bytes = 1 }, &codes);
        defer gpa.free(file);
        const a = try decode(.wav, gpa, file);
        defer a.deinit(gpa);
        try std.testing.expectEqual(@as(usize, codes.len), a.samples.i16.len);
        for (codes, a.samples.i16) |c, got| {
            const want: i32 = if (code == 6) blk: { // A-law: even bits inverted, sign 1 = positive
                const v = c ^ 0x55;
                const seg: u5 = @intCast((v >> 4) & 7);
                const step: i32 = v & 0x0F;
                const mag = if (seg == 0) 2 * step + 1 else (2 * step + 33) << (seg - 1); // 12-bit
                break :blk if (v & 0x80 != 0) 8 * mag else -8 * mag;
            } else blk: { // mu-law: all bits inverted, sign 1 = negative
                const v = ~c;
                const seg: u5 = @intCast((v >> 4) & 7);
                const step: i32 = v & 0x0F;
                const mag = ((2 * step + 33) << seg) - 33; // 13-bit
                break :blk if (v & 0x80 != 0) -4 * mag else 4 * mag;
            };
            try std.testing.expectEqual(want, got);
        }
    }
}

// The encoder against a whole-file oracle: the frame layout of the reference qoa.h written out
// here, with every slice from `Formats/qoa/scalar.zig` (the line-by-line port of the reference
// slice search) one channel at a time. Then through `write` / `read` on a file.
test "QOA - encoder matches the scalar reference, write / read round trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const qh = @import("Formats/qoa/header.zig");
    const scalar = @import("Formats/qoa/scalar.zig");
    const Lms = @import("Formats/qoa/lms.zig").Lms;
    const channels = 3;
    const n_frames = 2 * qh.FRAME_LEN + 37; // the last frame ends in a short slice
    const generated = try testdata.signal(gpa, 44100, channels, n_frames, 2);
    defer generated.deinit(gpa);
    const src = try generated.convert(.i16, gpa);
    defer src.deinit(gpa);
    const pcm = src.samples.i16;

    var oracle: std.Io.Writer.Allocating = .init(gpa);
    defer oracle.deinit();
    const w = &oracle.writer;
    try w.writeAll("qoaf");
    try w.writeInt(u32, n_frames, .big);
    var lms: [channels]Lms = @splat(Lms.initial);
    var start: usize = 0;
    while (start < n_frames) : (start += qh.FRAME_LEN) {
        const len = @min(qh.FRAME_LEN, n_frames - start);
        const slices = (len + qh.SLICE_LEN - 1) / qh.SLICE_LEN;
        try w.writeInt(u8, channels, .big);
        try w.writeInt(u24, 44100, .big);
        try w.writeInt(u16, @intCast(len), .big);
        try w.writeInt(u16, @intCast(8 + 16 * channels + 8 * slices * channels), .big);
        for (lms) |l| {
            try w.writeInt(u64, Lms.packed16(l.history), .big);
            try w.writeInt(u64, Lms.packed16(l.weights), .big);
        }
        var prev_sf: [channels]usize = @splat(0); // the reference restarts the search per frame
        var s: usize = 0;
        while (s < len) : (s += qh.SLICE_LEN) {
            const slice_len = @min(qh.SLICE_LEN, len - s);
            for (0..channels) |c| {
                const r = scalar.encodeSlice(pcm, (start + s) * channels + c, channels, slice_len, lms[c], prev_sf[c]);
                lms[c] = r.lms;
                prev_sf[c] = r.sf;
                try w.writeInt(u64, r.slice << @intCast((qh.SLICE_LEN - slice_len) * 3), .big);
            }
        }
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(gpa, &.{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path, "t.qoa" });
    defer gpa.free(path);
    try src.write(io, gpa, path);
    const ours = try tmp.dir.readFileAlloc(io, "t.qoa", gpa, .unlimited);
    defer gpa.free(ours);
    try std.testing.expectEqualSlices(u8, oracle.written(), ours);

    const back = try read(.{ .io = io, .gpa = gpa, .dir = tmp.dir, .filepath = "t.qoa", .path_type = .dir });
    defer back.deinit(gpa);
    try std.testing.expectEqual(src.sample_rate, back.sample_rate);
    try std.testing.expectEqual(src.channels, back.channels);
    try std.testing.expectEqual(src.samples.len(), back.samples.len());
    var sig: f64 = 0;
    var noise: f64 = 0;
    for (pcm, back.samples.i16) |a, b| {
        const fa: f64 = @floatFromInt(a);
        const d: f64 = @floatFromInt(@as(i32, a) - b);
        sig += fa * fa;
        noise += d * d;
    }
    try std.testing.expect(10 * @log10(sig / noise) > 25);
}

// SKIPPED, on purpose. This compared the decoder with dr_mp3's output on MP3s encoded by LAME
// from music. Those files had no recorded origin or licence and were removed; replacing them
// needs MP3s from an independent encoder and an independent decoder's output, which the tests
// cannot produce in Zig without a second MP3 implementation. Still covered: the decoder's
// kernels against the scalar oracles (layer3.zig, synth.zig), encode -> decode round trips with
// SNR limits (below), and hand-built frames of every MPEG version and layer (silence).
test "MP3 - decode matches reference decoder" {
    return error.SkipZigTest;
}

test "decodeAny / unsupported formats" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnknownFormat, decodeAny(gpa, "nope"));
    try std.testing.expect(canEncode(.mp3));
    try std.testing.expect(!canEncode(.flac));
    try std.testing.expect(canDecode(.mp3));
    try std.testing.expect(canEncode(.qoa));
    try std.testing.expect(!canDecode(.flac));
    const a: Audio = .{ .sample_rate = 8000, .channels = 1, .samples = try .init(.i16, gpa, &.{ 1, 2, 3 }) };
    defer a.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.testing.expectError(error.Unsupported, a.encode(.flac, &aw.writer, gpa));
}

// Silent frames built from the standard (`testdata.silentFrame`): every MPEG version and layer,
// mono / stereo, CRC, padding and free format. Header parsing and frame sync must find every
// frame, and all-zero side info / allocation must decode to exact silence.
test "MP3 - hand-built silent frames, every version and layer" {
    const gpa = std.testing.allocator;
    const cases = [_]testdata.Frame{
        .{ .kbps = 128, .sample_rate = 44100, .padding = true },
        .{ .kbps = 320, .sample_rate = 48000, .mono = true, .crc = true },
        .{ .kbps = 32, .sample_rate = 32000 },
        .{ .kbps = 0, .sample_rate = 44100, .free_bytes = 300 }, // free format
        .{ .version = .mpeg2, .kbps = 64, .sample_rate = 22050 },
        .{ .version = .mpeg2, .kbps = 32, .sample_rate = 24000, .mono = true, .crc = true },
        .{ .version = .mpeg2, .kbps = 8, .sample_rate = 16000 },
        .{ .version = .mpeg25, .kbps = 32, .sample_rate = 11025, .padding = true },
        .{ .version = .mpeg25, .kbps = 16, .sample_rate = 12000, .mono = true },
        .{ .version = .mpeg25, .kbps = 8, .sample_rate = 8000, .mono = true },
        .{ .layer = 2, .kbps = 192, .sample_rate = 48000 },
        .{ .layer = 2, .version = .mpeg2, .kbps = 64, .sample_rate = 24000, .mono = true },
        .{ .layer = 1, .kbps = 384, .sample_rate = 44100, .padding = true },
        .{ .layer = 1, .version = .mpeg2, .kbps = 32, .sample_rate = 16000, .mono = true, .crc = true },
    };
    const count = 12;
    for (cases) |f| {
        errdefer std.debug.print("failed: {any}\n", .{f});
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        for (0..count) |_| try testdata.silentFrame(&aw.writer, f);
        const inf = try MP3.info(aw.written());
        const a = try decode(.mp3, gpa, aw.written());
        defer a.deinit(gpa);
        try std.testing.expectEqual(f.sample_rate, a.sample_rate);
        try std.testing.expectEqual(@as(u16, if (f.mono) 1 else 2), a.channels);
        try std.testing.expectEqual(@as(u64, count * testdata.frameSamples(f)), inf.frames);
        try std.testing.expectEqual(@as(usize, count * testdata.frameSamples(f)), a.frames());
        for (a.samples.f32) |v| try std.testing.expectEqual(@as(f32, 0), v);
    }
}

/// Silent MPEG-1 Layer III stream at 48 kHz with everything around it a decoder must skip:
/// ID3v2 (with footer), junk holding a fake frame header, a Xing frame (VBR, every optional
/// field, `lame` delay / padding when given), frames whose bit rate changes every frame (VBR),
/// then APEv2 and ID3v1 tags. `n_frames` silent frames of 1152 samples.
fn taggedSilentStream(gpa: std.mem.Allocator, n_frames: usize, lame: ?[2]u12) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try testdata.id3v2(w, "TIT2 hand-built, not parsed", true);
    var junk: [300]u8 = @splat(0x55);
    // a header of the same stream: the frame after it is not where it says, so it is rejected
    @memcpy(junk[10..][0..4], &testdata.mp3Header(.{ .kbps = 128, .sample_rate = 48000 }));
    try w.writeAll(&junk);
    try testdata.xingFrame(w, .{ .kbps = 128, .sample_rate = 48000 }, .{
        .tag = "Xing",
        .frames = @intCast(n_frames),
        .bytes = 12345,
        .toc = true,
        .quality = 100,
        .lame = if (lame) |l| .{ .delay = l[0], .padding = l[1] } else null,
    });
    const rates = [_]u16{ 64, 128, 320, 96, 32 };
    for (0..n_frames) |i| try testdata.silentFrame(w, .{ .kbps = rates[i % rates.len], .sample_rate = 48000 });
    try testdata.apev2(w);
    try testdata.id3v1(w);
    return aw.toOwnedSlice();
}

test "MP3 - hand-built tags, junk, Xing / LAME frame and VBR frame sizes" {
    const gpa = std.testing.allocator;
    const n_frames = 10;
    for ([_]?[2]u12{ null, .{ 576, 1500 } }) |lame| {
        const file = try taggedSilentStream(gpa, n_frames, lame);
        defer gpa.free(file);
        // the decoder adds 528 + 1 samples of delay to the encoder's
        const trim: usize = if (lame) |l| (@as(usize, l[0]) + 529) + (@as(usize, l[1]) - 529) else 0;
        const inf = try MP3.info(file);
        try std.testing.expectEqual(@as(u32, 48000), inf.sample_rate);
        try std.testing.expectEqual(@as(u16, 2), inf.channels);
        try std.testing.expectEqual(@as(u64, n_frames * 1152 - trim), inf.frames);
        const a = try decodeAny(gpa, file); // sniffed from the ID3v2 tag
        defer a.deinit(gpa);
        try std.testing.expectEqual(n_frames * 1152 - trim, a.frames());
        for (a.samples.f32) |v| try std.testing.expectEqual(@as(f32, 0), v);
    }
}

/// `n_frames` samples per channel of `testdata.signal` through this library's MP3 encoder,
/// without its Info frame: audio frames only, so the decoder returns every sample they hold
/// (no gapless trim).
fn testMp3Frames(gpa: std.mem.Allocator, sample_rate: u32, channels: u16, kbps: u16, n_frames: usize) ![]u8 {
    const src = try testdata.signal(gpa, sample_rate, channels, n_frames, sample_rate + kbps);
    defer src.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try MP3.encodeWith(&src, &aw.writer, gpa, .{ .bitrate_kbps = kbps });
    return gpa.dupe(u8, testdata.withoutInfoFrame(aw.written()));
}

// A LAME "Info" / "Xing" frame carries the encoder delay and padding. Splice one, plus ID3v2,
// APEv2 and ID3v1 tags, around a stream and check the trimmed output.
test "MP3 - LAME gapless info and tags" {
    const gpa = std.testing.allocator;
    const data = try testMp3Frames(gpa, 44100, 2, 128, 44100 / 2);
    defer gpa.free(data);
    const ref = try decode(.mp3, gpa, data); // every sample the frames hold
    defer ref.deinit(gpa);

    const enc_delay = 576;
    const enc_padding = 1000;
    const variants = [_]testdata.Xing{
        .{ .tag = "Info", .lame = .{ .delay = enc_delay, .padding = enc_padding } },
        .{ .tag = "Xing", .frames = 20, .bytes = @intCast(data.len), .toc = true, .quality = 50, .lame = .{ .delay = enc_delay, .padding = enc_padding } },
    };
    for (variants) |x| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try testdata.id3v2(&aw.writer, "abcd", false);
        try testdata.xingFrame(&aw.writer, .{ .kbps = 128, .sample_rate = 44100 }, x);
        try aw.writer.writeAll(data);
        try testdata.apev2(&aw.writer);
        try testdata.id3v1(&aw.writer);

        const a = try decode(.mp3, gpa, aw.written());
        defer a.deinit(gpa);
        const delay = enc_delay + 529;
        const padding = enc_padding - 529;
        try std.testing.expectEqual(ref.frames() - delay - padding, a.frames());
        try std.testing.expectEqualSlices(f32, ref.samples.f32[delay * 2 ..][0 .. a.frames() * 2], a.samples.f32);
    }
}

// The LAME padding is read from the file: a padding larger than the samples the frames hold
// must not underflow (it used to panic in Debug / ReleaseSafe).
test "MP3 - gapless padding larger than the stream" {
    const gpa = std.testing.allocator;
    const data = try testMp3Frames(gpa, 44100, 2, 128, 4000);
    defer gpa.free(data);
    var sync: @import("Formats/mp3/header.zig").Sync = .{};
    const first = sync.next(data);
    try std.testing.expect(first.len != 0);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    // delay 0, padding 0xFFF (4095 - 529 = 3566 samples, more than one 1152-sample frame)
    try testdata.xingFrame(&aw.writer, .{ .kbps = 128, .sample_rate = 44100 }, .{ .lame = .{ .delay = 0, .padding = 0xFFF } });
    try aw.writer.writeAll(data[0 .. first.skip + first.len]);

    const a = try decode(.mp3, gpa, aw.written());
    defer a.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), a.frames());
}

// Junk before the first frame (no Xing/Info frame) is skipped once: it used to be skipped
// twice, which miscounted the frames and could index past the end of a short file.
test "MP3 - junk before the first frame" {
    const gpa = std.testing.allocator;
    const data = try testMp3Frames(gpa, 44100, 2, 128, 44100 / 2);
    defer gpa.free(data);
    const junk: [300]u8 = @splat(0x55);

    // a junk-prefixed file cut after its first frame: the second skip ran past the end
    var sync: @import("Formats/mp3/header.zig").Sync = .{};
    const first = sync.next(data);
    const short = try std.mem.concat(gpa, u8, &.{ &junk, data[0 .. first.len + 100] });
    defer gpa.free(short);
    if (decode(.mp3, gpa, short)) |s| s.deinit(gpa) else |_| {}

    // the whole file: same frame count and samples as without the junk
    const clean = try MP3.info(data);
    const file = try std.mem.concat(gpa, u8, &.{ &junk, data });
    defer gpa.free(file);
    const inf = try MP3.info(file);
    try std.testing.expectEqual(clean.frames, inf.frames);
    const a = try decode(.mp3, gpa, file);
    defer a.deinit(gpa);
    const b = try decode(.mp3, gpa, data);
    defer b.deinit(gpa);
    try std.testing.expectEqualSlices(u8, b.samples.asBytes(), a.samples.asBytes());
}

// Damaged files must fail with an error (or decode garbage), never crash: run in Debug
// so every slice access is bounds checked.
test "corrupt files never crash" {
    const gpa = std.testing.allocator;
    var files: [5]struct { data: []u8, tag: AudioTag } = undefined;
    var made: usize = 0;
    defer for (files[0..made]) |f| gpa.free(f.data);
    files[made] = .{ .data = try testMp3Frames(gpa, 22050, 2, 64, 22050), .tag = .mp3 };
    made += 1;
    files[made] = .{ .data = try testMp3Frames(gpa, 48000, 1, 96, 24000), .tag = .mp3 };
    made += 1;
    files[made] = .{ .data = try taggedSilentStream(gpa, 6, .{ 576, 1000 }), .tag = .mp3 };
    made += 1;
    for ([_]AudioTag{ .qoa, .wav }) |tag| {
        // QOA stereo; WAV 3-channel 24-bit, which the encoder writes as WAVE_FORMAT_EXTENSIBLE
        const channels: u16 = if (tag == .qoa) 2 else 3;
        const src = try testdata.signal(gpa, 44100, channels, 8000, 3);
        defer src.deinit(gpa);
        const conv = try src.convert(if (tag == .qoa) .i16 else .i24, gpa);
        defer conv.deinit(gpa);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try conv.encode(tag, &aw.writer, gpa);
        files[made] = .{ .data = try aw.toOwnedSlice(), .tag = tag };
        made += 1;
    }
    var prng: std.Random.DefaultPrng = .init(0x5EED);
    const random = prng.random();
    for (files) |f| {
        const orig = f.data;
        const buf = try gpa.alloc(u8, orig.len);
        defer gpa.free(buf);
        for (0..60) |iter| {
            @memcpy(buf, orig);
            // early iterations hit the headers, later ones anywhere
            const span = if (iter < 30) @min(buf.len, 256) else buf.len;
            for (0..random.intRangeAtMost(usize, 1, 16)) |_| buf[random.uintLessThan(usize, span)] = random.int(u8);
            const len = if (iter % 3 == 0) random.uintAtMost(usize, buf.len) else buf.len;
            if (decode(f.tag, gpa, buf[0..len])) |a| a.deinit(gpa) else |_| {}
        }
    }
}

// Encoder correctness: a chirp is easy to code, so at these rates any filterbank, bitstream
// or table mistake shows as a collapse in SNR. Every MPEG version, mono and stereo, L/R and
// mid/side. The output must be exactly as long as the input (gapless Info frame).
// The psychoacoustic model is off here (it deliberately leaves masked noise in); the tests
// after this one cover the full encoder.
test "MP3 - encode round trip" {
    const gpa = std.testing.allocator;
    const Stereo = @FieldType(MP3.EncodeOptions, "stereo");
    const Case = struct { rate: u32, nch: u16, kbps: u16, stereo: Stereo = .auto, min_snr: f64 };
    const cases = [_]Case{
        .{ .rate = 44100, .nch = 2, .kbps = 256, .stereo = .left_right, .min_snr = 45 },
        .{ .rate = 44100, .nch = 2, .kbps = 256, .stereo = .mid_side, .min_snr = 45 },
        .{ .rate = 48000, .nch = 1, .kbps = 128, .min_snr = 45 },
        .{ .rate = 32000, .nch = 2, .kbps = 192, .min_snr = 45 },
        .{ .rate = 22050, .nch = 2, .kbps = 128, .min_snr = 45 },
        .{ .rate = 16000, .nch = 1, .kbps = 64, .min_snr = 45 },
        .{ .rate = 11025, .nch = 1, .kbps = 32, .min_snr = 45 },
        .{ .rate = 8000, .nch = 1, .kbps = 8, .min_snr = 15 }, // tiny frames: Info frame at a higher rate
    };
    for (cases) |c| {
        const n = c.rate / 2 + 13; // ends mid-frame
        const s = try gpa.alloc(f32, n * c.nch);
        defer gpa.free(s);
        const rate: f32 = @floatFromInt(c.rate);
        for (0..n) |i| for (0..c.nch) |ch| {
            const t = @as(f32, @floatFromInt(i)) / rate;
            const f0 = 200 + 150 * @as(f32, @floatFromInt(ch));
            s[c.nch * i + ch] = 0.5 * @sin(2 * std.math.pi * (f0 + 0.05 * rate * t) * t);
        };
        const a: Audio = .{ .sample_rate = c.rate, .channels = c.nch, .samples = .{ .f32 = s } };
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try MP3.encodeWith(&a, &aw.writer, gpa, .{ .bitrate_kbps = c.kbps, .stereo = c.stereo, .psy = false });
        const b = try decodeAny(gpa, aw.written());
        defer b.deinit(gpa);
        try std.testing.expectEqual(c.rate, b.sample_rate);
        try std.testing.expectEqual(c.nch, b.channels);
        try std.testing.expectEqual(@as(usize, n), b.frames());
        var sig: f64 = 0;
        var err: f64 = 0;
        for (s, b.samples.f32) |x, y| {
            sig += x * x;
            err += (x - y) * (x - y);
        }
        const snr = 10 * @log10(sig / err);
        if (snr < c.min_snr) {
            std.debug.print("{} Hz {} ch {} kbps {t}: snr {d:.1} dB < {d}\n", .{ c.rate, c.nch, c.kbps, c.stereo, snr, c.min_snr });
            return error.TestUnexpectedResult;
        }
    }
    // unsupported inputs
    const one: Audio = .{ .sample_rate = 44100, .channels = 3, .samples = try .init(.f32, gpa, &.{ 0, 0, 0 }) };
    defer one.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.testing.expectError(error.UnsupportedChannels, one.encode(.mp3, &aw.writer, gpa));
    const odd_rate: Audio = .{ .sample_rate = 44000, .channels = 1, .samples = try .init(.f32, gpa, &.{0}) };
    defer odd_rate.deinit(gpa);
    try std.testing.expectError(error.UnsupportedSampleRate, odd_rate.encode(.mp3, &aw.writer, gpa));
}

/// Per-frame side info of an MP3 we wrote: block types, reservoir use, mid/side.
const FrameStats = struct { frames: usize = 0, borrowed: usize = 0, max_main_data_begin: u32 = 0, ms: usize = 0, blocks: [4]usize = @splat(0) };

fn scanFrames(data: []const u8) !FrameStats {
    const header = @import("Formats/mp3/header.zig");
    const l3 = @import("Formats/mp3/layer3.zig");
    const Bs = @import("Formats/mp3/bits.zig").Bs;
    var st: FrameStats = .{};
    var sync: header.Sync = .{};
    var pos: usize = 0;
    while (pos < data.len) {
        const f = sync.next(data[pos..]);
        if (f.len == 0) break;
        const frame = data[pos + f.skip ..][0..f.len];
        pos += f.skip + f.len;
        var bs: Bs = .init(frame[4..]);
        var gr: [4]l3.GrInfo = undefined;
        const mdb = l3.readSideInfo(&bs, &gr, frame) orelse return error.TestUnexpectedResult;
        st.frames += 1;
        if (mdb > 0) st.borrowed += 1;
        st.max_main_data_begin = @max(st.max_main_data_begin, mdb);
        if ((frame[3] & 0xE0) == 0x60) st.ms += 1;
        const n: usize = (if (header.Header.isMpeg1(frame)) @as(usize, 2) else 1) * (if (header.Header.isMono(frame)) @as(usize, 1) else 2);
        for (gr[0..n]) |g| st.blocks[g.block_type] += 1;
    }
    return st;
}

fn testSnr(a: []const f32, b: []const f32) f64 {
    var sig: f64 = 0;
    var err: f64 = 0;
    for (a, b) |x, y| {
        sig += x * x;
        err += (x - y) * (x - y);
    }
    return 10 * @log10(sig / err);
}

// The full encoder (psychoacoustic model, short blocks, bit reservoir) on music-like material
// with attacks, at every MPEG version: exact length, every feature actually engaged, and a
// sane SNR (noise is shaped under the masking threshold, so SNR is not the goal).
test "MP3 - encoder features" {
    const gpa = std.testing.allocator;
    const Case = struct { rate: u32, nch: u16, kbps: u16 };
    const cases = [_]Case{
        .{ .rate = 44100, .nch = 2, .kbps = 128 },
        .{ .rate = 48000, .nch = 1, .kbps = 96 },
        .{ .rate = 22050, .nch = 2, .kbps = 64 },
        .{ .rate = 11025, .nch = 1, .kbps = 24 },
    };
    for (cases) |c| {
        const n = c.rate * 2;
        const s = try gpa.alloc(f32, n * c.nch);
        defer gpa.free(s);
        var prng: std.Random.DefaultPrng = .init(c.rate);
        const r = prng.random();
        const rate: f32 = @floatFromInt(c.rate);
        for (0..n) |i| for (0..c.nch) |ch| {
            const t = @as(f32, @floatFromInt(i)) / rate;
            const beat = @mod(t, 0.5);
            const env = @exp(-beat * 6);
            const f0: f32 = if (ch == 0) 220 else 277;
            var v = 0.3 * env * (@sin(2 * std.math.pi * f0 * t) + 0.5 * @sin(2 * std.math.pi * 3 * f0 * t));
            if (beat < 0.01) v += 0.5 * (r.float(f32) - 0.5); // drum hit
            s[c.nch * i + ch] = v;
        };
        const a: Audio = .{ .sample_rate = c.rate, .channels = c.nch, .samples = .{ .f32 = s } };
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try MP3.encodeWith(&a, &aw.writer, gpa, .{ .bitrate_kbps = c.kbps });
        const b = try decode(.mp3, gpa, aw.written());
        defer b.deinit(gpa);
        try std.testing.expectEqual(@as(usize, n), b.frames());
        const snr = testSnr(s, b.samples.f32);
        const st = try scanFrames(aw.written());
        if (snr < 12 or st.borrowed == 0 or st.blocks[2] == 0 or st.blocks[1] == 0 or st.blocks[3] == 0) {
            std.debug.print("{} Hz {} ch {} kbps: snr {d:.1} dB, {any}\n", .{ c.rate, c.nch, c.kbps, snr, st });
            return error.TestUnexpectedResult;
        }
    }
}

// Short blocks exist against pre-echo: the quantization noise of a long block spreads over its
// whole 1152-sample window, so it is audible before an attack. With short blocks the noise
// before each click must be much lower. Measured from 1000 to 220 samples (5 ms) before the
// click: closer than that, the ear's pre-masking hides it either way.
test "MP3 - short blocks reduce pre-echo" {
    const gpa = std.testing.allocator;
    const n = 44100 * 2;
    const s = try gpa.alloc(f32, n);
    defer gpa.free(s);
    var prng: std.Random.DefaultPrng = .init(4);
    const r = prng.random();
    const period = 11025;
    for (s, 0..) |*v, i| {
        const k = i % period;
        v.* = 0.005 * @sin(@as(f32, @floatFromInt(i)) * 0.07); // quiet background
        if (k >= period / 2 and k < period / 2 + 200) v.* += 0.7 * (r.float(f32) - 0.5); // click
    }
    var pre_echo: [2]f64 = undefined;
    for ([_]bool{ false, true }, 0..) |short, k| {
        const a: Audio = .{ .sample_rate = 44100, .channels = 1, .samples = .{ .f32 = s } };
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try MP3.encodeWith(&a, &aw.writer, gpa, .{ .bitrate_kbps = 64, .short_blocks = short });
        const b = try decode(.mp3, gpa, aw.written());
        defer b.deinit(gpa);
        var e: f64 = 0;
        var c: usize = period / 2;
        while (c < n) : (c += period) {
            for (c - 1000..c - 220) |i| {
                const d = b.samples.f32[i] - s[i];
                e += d * d;
            }
        }
        pre_echo[k] = e;
    }
    const gain_db = 10 * @log10(pre_echo[0] / pre_echo[1]);
    if (gain_db < 6) {
        std.debug.print("pre-echo: long only {e}, with short blocks {e} ({d:.1} dB)\n", .{ pre_echo[0], pre_echo[1], gain_db });
        return error.TestUnexpectedResult;
    }
}
