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
    inline for (.{ WAV, QOA, MP3 }) |C| std.testing.refAllDecls(C);
}

/// Test helper: max and mean absolute difference between two buffers, as floats.
pub fn diff(a: Samples, b: Samples) struct { max: f64, mean: f64 } {
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

fn testRead(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Audio {
    return read(.{ .io = io, .gpa = gpa, .filepath = path }) catch |err| {
        std.debug.print("failed reading {s}: {t}\n", .{ path, err });
        return err;
    };
}

fn testTone(gpa: std.mem.Allocator, channels: u16, n_frames: usize) !Audio {
    const s = try gpa.alloc(f64, n_frames * channels);
    for (s, 0..) |*v, i| {
        const t: f64 = @floatFromInt(i / channels);
        const c: f64 = @floatFromInt(i % channels);
        v.* = 0.6 * @sin(t * (0.02 + 0.01 * c)) + 0.3 * @sin(t * 0.37);
    }
    // full scale, to exercise clamping in the integer conversions
    s[0] = 1.0;
    if (s.len > 1) s[1] = -1.0;
    return .{ .sample_rate = 44100, .channels = channels, .samples = .{ .f64 = s } };
}

// encode -> file -> decode, for every sample type WAV can store
test "WAV - write round trip, every sample type" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_]u16{ 1, 2, 6 }) |channels| {
        const tone = try testTone(gpa, channels, 1001);
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

// Reference files written by an independent encoder (Python) must decode to the same
// samples as the 16-bit original.
test "WAV - decode reference files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const ref = try testRead(io, gpa, "src/Data/Read/Tone16.wav");
    defer ref.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 44100), ref.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), ref.channels);
    const Case = struct { path: []const u8, tag: SampleTag, tol: f64 = 0, ref: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .path = "src/Data/Read/Tone8.wav", .tag = .u8, .tol = 1.0 / 128.0 },
        .{ .path = "src/Data/Read/Tone24.wav", .tag = .i24 },
        .{ .path = "src/Data/Read/Tone32.wav", .tag = .i32 },
        .{ .path = "src/Data/Read/ToneFloat32.wav", .tag = .f32 },
        .{ .path = "src/Data/Read/ToneFloat64.wav", .tag = .f64 },
        .{ .path = "src/Data/Read/Tone24Extensible.wav", .tag = .i24 },
        // G.711 is lossy: compare against the reference decoder's output instead
        .{ .path = "src/Data/Read/ToneMulaw.wav", .tag = .i16, .ref = "src/Data/Read/ToneMulaw.ref.wav" },
        .{ .path = "src/Data/Read/ToneAlaw.wav", .tag = .i16, .ref = "src/Data/Read/ToneAlaw.ref.wav" },
    };
    for (cases) |case| {
        const a = try testRead(io, gpa, case.path);
        defer a.deinit(gpa);
        const other = if (case.ref) |p| try testRead(io, gpa, p) else null;
        defer if (other) |o| o.deinit(gpa);
        const expected = other orelse ref;
        try std.testing.expectEqual(case.tag, std.meta.activeTag(a.samples));
        try std.testing.expectEqual(expected.channels, a.channels);
        try std.testing.expectEqual(expected.samples.len(), a.samples.len());
        const d = diff(expected.samples, a.samples);
        if (d.max > case.tol) {
            std.debug.print("{s}: max diff {d:.6} > {d:.6}\n", .{ case.path, d.max, case.tol });
            return error.TestExpectedSimilar;
        }
    }
}

test "QOA - reference encoder file, and write round trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Tone.qoa was written by the reference qoa.h encoder; Tone.qoa.wav is its decode
    const qoa = try testRead(io, gpa, "src/Data/Read/Tone.qoa");
    defer qoa.deinit(gpa);
    const ref = try testRead(io, gpa, "src/Data/Read/Tone.qoa.wav");
    defer ref.deinit(gpa);
    try std.testing.expectEqual(ref.sample_rate, qoa.sample_rate);
    try std.testing.expectEqual(ref.channels, qoa.channels);
    try std.testing.expectEqualSlices(u8, ref.samples.asBytes(), qoa.samples.asBytes());

    // our encoder must produce byte-identical output to the reference encoder
    const src = try testRead(io, gpa, "src/Data/Read/Tone16.wav");
    defer src.deinit(gpa);
    try src.write(io, gpa, "src/Data/Write/Tone.qoa");
    var file = try std.Io.Dir.cwd().openFile(io, "src/Data/Write/Tone.qoa", .{});
    defer file.close(io);
    var ours: std.ArrayList(u8) = .empty;
    defer ours.deinit(gpa);
    _ = try misc.readFileInto(io, gpa, file, &ours);
    var file2 = try std.Io.Dir.cwd().openFile(io, "src/Data/Read/Tone.qoa", .{});
    defer file2.close(io);
    var theirs: std.ArrayList(u8) = .empty;
    defer theirs.deinit(gpa);
    _ = try misc.readFileInto(io, gpa, file2, &theirs);
    try std.testing.expectEqualSlices(u8, theirs.items, ours.items);
}

// MP3s encoded by LAME; references decoded by dr_mp3 (miniaudio) to f32.
test "MP3 - decode matches reference decoder" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const Case = struct { mp3: []const u8, ref: []const u8 };
    const cases = [_]Case{
        .{ .mp3 = "src/Data/Read/Music128.mp3", .ref = "src/Data/Read/Music128.mp3.wav" },
        .{ .mp3 = "src/Data/Read/MusicVbr.mp3", .ref = "src/Data/Read/MusicVbr.mp3.wav" },
        .{ .mp3 = "src/Data/Read/MusicMono64.mp3", .ref = "src/Data/Read/MusicMono64.mp3.wav" },
        .{ .mp3 = "src/Data/Read/Music22k.mp3", .ref = "src/Data/Read/Music22k.mp3.wav" },
        .{ .mp3 = "src/Data/Read/Music11k.mp3", .ref = "src/Data/Read/Music11k.mp3.wav" },
        .{ .mp3 = "src/Data/Read/Music48k320.mp3", .ref = "src/Data/Read/Music48k320.mp3.wav" },
    };
    for (cases) |case| {
        const a = try testRead(io, gpa, case.mp3);
        defer a.deinit(gpa);
        const ref = try testRead(io, gpa, case.ref);
        defer ref.deinit(gpa);
        try std.testing.expectEqual(ref.sample_rate, a.sample_rate);
        try std.testing.expectEqual(ref.channels, a.channels);
        std.testing.expectEqual(ref.samples.len(), a.samples.len()) catch |err| {
            std.debug.print("{s}: {} samples, reference has {}\n", .{ case.mp3, a.samples.len(), ref.samples.len() });
            return err;
        };
        const d = diff(ref.samples, a.samples);
        if (d.max > 1e-5) { // float rounding only: measured < 1e-6 on x86-64
            std.debug.print("{s}: max diff {e} mean {e}\n", .{ case.mp3, d.max, d.mean });
            return error.TestExpectedSimilar;
        }
    }
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

fn testReadBytes(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    _ = try misc.readFileInto(io, gpa, file, &buf);
    return buf.toOwnedSlice(gpa);
}

// A LAME "Info" frame (as written by `lame`) carries the encoder delay and padding.
// Splice one, plus ID3v2 / ID3v1 tags, around a stream and check the trimmed output.
test "MP3 - LAME gapless info and tags" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const data = try testReadBytes(io, gpa, "src/Data/Read/Music128.mp3");
    defer gpa.free(data);
    const ref = try testRead(io, gpa, "src/Data/Read/Music128.mp3.wav");
    defer ref.deinit(gpa);

    var info_frame: [417]u8 = @splat(0); // 128 kbps @ 44.1 kHz, no padding
    @memcpy(info_frame[0..4], data[0..4]);
    try std.testing.expectEqual(@as(u8, 0), info_frame[2] & 2);
    const p = 4 + 32; // MPEG-1 stereo side info
    @memcpy(info_frame[p..][0..4], "Info"); // flags = 0: no optional fields
    @memcpy(info_frame[p + 8 ..][0..9], "LAME3.100");
    const enc_delay = 576;
    const enc_padding = 1000;
    info_frame[p + 8 + 21] = enc_delay >> 4;
    info_frame[p + 8 + 22] = ((enc_delay & 0xF) << 4) | (enc_padding >> 8);
    info_frame[p + 8 + 23] = enc_padding & 0xFF;
    const id3v2 = "ID3\x03\x00\x00\x00\x00\x00\x04" ++ "abcd";
    const id3v1 = "TAG" ++ @as([125]u8, @splat(0));
    const file = try std.mem.concat(gpa, u8, &.{ id3v2, &info_frame, data, id3v1 });
    defer gpa.free(file);

    const a = try decode(.mp3, gpa, file);
    defer a.deinit(gpa);
    const delay = enc_delay + 529;
    const padding = enc_padding - 529;
    const raw = ref.frames();
    try std.testing.expectEqual(raw - delay - padding, a.frames());
    const want = ref.samples.f32[delay * 2 ..][0 .. a.frames() * 2];
    const d = diff(.{ .f32 = want }, a.samples);
    try std.testing.expect(d.max < 1e-5);
}

// Damaged files must fail with an error (or decode garbage), never crash: run in Debug
// so every slice access is bounds checked.
test "corrupt files never crash" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const files = [_]struct { path: []const u8, tag: AudioTag }{
        .{ .path = "src/Data/Read/Music22k.mp3", .tag = .mp3 },
        .{ .path = "src/Data/Read/MusicMono64.mp3", .tag = .mp3 },
        .{ .path = "src/Data/Read/Tone.qoa", .tag = .qoa },
        .{ .path = "src/Data/Read/Tone24Extensible.wav", .tag = .wav },
    };
    var prng: std.Random.DefaultPrng = .init(0x5EED);
    const random = prng.random();
    for (files) |f| {
        const orig = try testReadBytes(io, gpa, f.path);
        defer gpa.free(orig);
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
