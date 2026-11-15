//! `zig build bench` (ReleaseFast). Median time per operation, plus speed as a
//! multiple of real time (seconds of audio processed per second).
const std = @import("std");
const Audio = @import("Audio");

const N_ITERS = 9;
const SECONDS = 10; // length of the synthetic test signal

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

/// Median wall time of `N_ITERS` calls to `func(ctx)`, in ms.
fn timeMs(io: std.Io, ctx: anytype, comptime func: anytype) !f64 {
    var times: [N_ITERS]f64 = undefined;
    for (&times) |*t| {
        const start = nowNs(io);
        try func(ctx);
        t.* = @as(f64, @floatFromInt(nowNs(io) - start)) / 1e6;
    }
    std.mem.sort(f64, &times, {}, std.sort.asc(f64));
    return times[N_ITERS / 2];
}

fn report(name: []const u8, ms: f64, audio_seconds: f64) void {
    std.debug.print("{s:<36} {d:>9.3} {d:>10.0}x\n", .{ name, ms, audio_seconds / (ms / 1000) });
}

/// 10 s of synthetic "music": a few partials, an envelope and some noise (seeded PRNG).
fn signal(gpa: std.mem.Allocator, rate: u32, channels: u16) !Audio {
    const n = rate * SECONDS;
    const s = try gpa.alloc(f32, n * channels);
    var prng: std.Random.DefaultPrng = .init(1);
    const r = prng.random();
    const rate_f: f32 = @floatFromInt(rate);
    for (0..n) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / rate_f;
        const env = @exp(-@mod(t, 0.5) * 4);
        for (0..channels) |c| {
            const f: f32 = if (c == 0) 220 else 330;
            var v = 0.4 * env * @sin(2 * std.math.pi * f * t) + 0.2 * @sin(2 * std.math.pi * 2 * f * t + 1);
            v += 0.02 * (r.float(f32) - 0.5);
            s[channels * i + c] = v;
        }
    }
    return .{ .sample_rate = rate, .channels = channels, .samples = .{ .f32 = s } };
}

const ConvertCtx = struct { src: *const Audio, tag: Audio.SampleTag, gpa: std.mem.Allocator };
fn convertOnce(c: ConvertCtx) !void {
    const out = try c.src.convert(c.tag, c.gpa);
    out.deinit(c.gpa);
}

const EncodeCtx = struct { src: *const Audio, tag: Audio.AudioTag, gpa: std.mem.Allocator, out: *std.Io.Writer.Allocating };
fn encodeOnce(c: EncodeCtx) !void {
    c.out.clearRetainingCapacity();
    try c.src.encode(c.tag, &c.out.writer, c.gpa);
}

const DecodeCtx = struct { tag: Audio.AudioTag, data: []const u8, inf: Audio.Info, out: []u8, arena: *std.heap.ArenaAllocator };
fn decodeOnce(c: DecodeCtx) !void {
    try Audio.decodeInto(c.tag, c.arena.allocator(), c.data, c.inf, c.out);
    _ = c.arena.reset(.retain_capacity);
}

fn benchDecode(io: std.Io, gpa: std.mem.Allocator, name: []const u8, tag: Audio.AudioTag, data: []const u8) !void {
    const inf = try Audio.info(tag, data);
    const out = try gpa.alloc(u8, try inf.byteLen());
    defer gpa.free(out);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ms = try timeMs(io, DecodeCtx{ .tag = tag, .data = data, .inf = inf, .out = out, .arena = &arena }, decodeOnce);
    report(name, ms, inf.seconds());
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;

    const f32_src = try signal(gpa, 44100, 2);
    defer f32_src.deinit(gpa);
    const secs = f32_src.seconds();
    std.debug.print("{s:<36} {s:>9} {s:>11}\n", .{ "10 s stereo 44.1 kHz", "ms", "realtime" });

    // sample conversions
    var srcs: [6]Audio = undefined;
    for (std.enums.values(Audio.SampleTag), &srcs) |t, *s| s.* = try f32_src.convert(t, gpa);
    defer for (srcs) |s| s.deinit(gpa);
    const pairs = [_][2]Audio.SampleTag{
        .{ .i16, .f32 }, .{ .f32, .i16 }, .{ .i24, .f32 }, .{ .f32, .i24 },
        .{ .u8, .f32 },  .{ .i16, .i24 }, .{ .i32, .i16 }, .{ .f64, .f32 },
    };
    for (pairs) |p| {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "convert {t} -> {t}", .{ p[0], p[1] });
        const ms = try timeMs(io, ConvertCtx{ .src = &srcs[@backingInt(p[0])], .tag = p[1], .gpa = gpa }, convertOnce);
        report(name, ms, secs);
    }

    // encode + decode
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const cases = [_]struct { tag: Audio.AudioTag, samples: Audio.SampleTag }{
        .{ .tag = .wav, .samples = .i16 },
        .{ .tag = .wav, .samples = .i24 },
        .{ .tag = .wav, .samples = .f32 },
        .{ .tag = .qoa, .samples = .i16 },
    };
    for (cases) |c| {
        const src = &srcs[@backingInt(c.samples)];
        var name_buf: [64]u8 = undefined;
        const ms = try timeMs(io, EncodeCtx{ .src = src, .tag = c.tag, .gpa = gpa, .out = &out }, encodeOnce);
        report(try std.fmt.bufPrint(&name_buf, "encode {t} ({t})", .{ c.tag, c.samples }), ms, secs);
        const data = try gpa.dupe(u8, out.written());
        defer gpa.free(data);
        try benchDecode(io, gpa, try std.fmt.bufPrint(&name_buf, "decode {t} ({t})", .{ c.tag, c.samples }), c.tag, data);
    }
    if (Audio.canEncode(.mp3)) {
        const ms = try timeMs(io, EncodeCtx{ .src = &srcs[@backingInt(Audio.SampleTag.f32)], .tag = .mp3, .gpa = gpa, .out = &out }, encodeOnce);
        report("encode mp3 (128 kbps)", ms, secs);
        const data = try gpa.dupe(u8, out.written());
        defer gpa.free(data);
        try benchDecode(io, gpa, "decode mp3 (ours, 128 kbps)", .mp3, data);
    }

    // MP3 decode at other rates / channel counts (generated, encoded by this library)
    const mp3_cases = [_]struct { rate: u32, channels: u16, kbps: u16 }{
        .{ .rate = 48000, .channels = 2, .kbps = 320 },
        .{ .rate = 44100, .channels = 1, .kbps = 64 },
    };
    for (mp3_cases) |c| {
        const src = try signal(gpa, c.rate, c.channels);
        defer src.deinit(gpa);
        out.clearRetainingCapacity();
        try Audio.MP3.encodeWith(&src, &out.writer, gpa, .{ .bitrate_kbps = c.kbps });
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "decode mp3 ({} Hz {}ch {} kbps)", .{ c.rate, c.channels, c.kbps });
        try benchDecode(io, gpa, name, .mp3, out.written());
    }
}
