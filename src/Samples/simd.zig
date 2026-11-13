//! Vector load/store helpers and byte-layout kernels shared by the sample conversions
//! and the format codecs.
const std = @import("std");
const native_endian = @import("builtin").cpu.arch.endian();
const N = @import("misc.zig").N;

/// `L` native-endian `T`s from the start of `bytes`. A pointer cast compiles to one
/// unaligned load, where `@bitCast` of a byte array becomes a byte-by-byte loop.
pub inline fn load(comptime L: usize, comptime T: type, bytes: []const u8) @Vector(L, T) {
    return @as(*align(1) const [L]T, @ptrCast(bytes[0 .. L * @sizeOf(T)])).*;
}

/// Like `load`, for little-endian file data.
pub inline fn loadLittle(comptime L: usize, comptime T: type, bytes: []const u8) @Vector(L, T) {
    const v = load(L, T, bytes);
    return if (native_endian == .big) @byteSwap(v) else v;
}

pub inline fn store(comptime L: usize, comptime T: type, bytes: []u8, v: @Vector(L, T)) void {
    @as(*align(1) [L]T, @ptrCast(bytes[0 .. L * @sizeOf(T)])).* = v;
}

// ── i24 ──
// An `i24` occupies 4 bytes in memory (only the low 3 are its value), so a run of them
// can be read and written as i32 words: sign-extend on load, the 4th byte is ignored.

/// `L` i24 samples as sign-extended i32 lanes.
pub inline fn loadI24(comptime L: usize, src: []const i24) @Vector(L, i32) {
    const words: *const [L]i32 = @ptrCast(src[0..L]);
    const v: @Vector(L, i32) = words.*;
    return (v << @splat(8)) >> @splat(8);
}

/// Stores the low 24 bits of each lane as an i24 sample.
pub inline fn storeI24(comptime L: usize, dst: []i24, v: @Vector(L, i32)) void {
    const words: *[L]i32 = @ptrCast(dst[0..L]);
    words.* = v;
}

/// Packed 3-byte little-endian samples (WAV) -> i24.
pub fn unpackI24Little(src: []const u8, dst: []i24) void {
    std.debug.assert(src.len == dst.len * 3);
    const L = N / 4;
    // byte k of lane i takes file byte 3i + k - 1: the sample lands in the top 3 bytes,
    // then an arithmetic shift sign-extends it
    const mask = comptime blk: {
        var m: [4 * L]i32 = undefined;
        for (0..L) |i| {
            m[4 * i] = 3 * i; // any byte: shifted out
            for (1..4) |k| m[4 * i + k] = 3 * i + k - 1;
        }
        break :blk m;
    };
    var i: usize = 0;
    // the 3L-byte load must not run past the end: keep one extra sample of slack
    while (i + L + 1 <= dst.len) : (i += L) {
        const bytes: @Vector(3 * L, u8) = src[3 * i ..][0 .. 3 * L].*;
        const words: @Vector(L, i32) = @bitCast(@shuffle(u8, bytes, undefined, mask));
        const le = if (native_endian == .big) @byteSwap(words) else words;
        storeI24(L, dst[i..], le >> @splat(8));
    }
    for (dst[i..], i..) |*d, k| d.* = std.mem.readInt(i24, src[3 * k ..][0..3], .little);
}

/// i24 -> packed 3-byte little-endian samples (WAV).
pub fn packI24Little(src: []const i24, dst: []u8) void {
    std.debug.assert(dst.len == src.len * 3);
    const L = N / 4;
    const mask = comptime blk: {
        var m: [3 * L]i32 = undefined;
        for (0..L) |i| for (0..3) |k| {
            m[3 * i + k] = 4 * i + k;
        };
        break :blk m;
    };
    var i: usize = 0;
    while (i + L <= src.len) : (i += L) {
        const v = loadI24(L, src[i..]);
        const le = if (native_endian == .big) @byteSwap(v) else v;
        const bytes: @Vector(4 * L, u8) = @bitCast(le);
        dst[3 * i ..][0 .. 3 * L].* = @shuffle(u8, bytes, undefined, mask);
    }
    for (src[i..], i..) |s, k| std.mem.writeInt(i24, dst[3 * k ..][0..3], s, .little);
}

/// Little-endian file samples -> native `T`s (a copy on little-endian hosts).
pub fn copyLittle(comptime T: type, src: []const u8, dst: []T) void {
    std.debug.assert(src.len == dst.len * @sizeOf(T));
    const out = std.mem.sliceAsBytes(dst);
    if (native_endian == .little) return @memcpy(out, src);
    const U = @Int(.unsigned, @bitSizeOf(T));
    const L = N / @sizeOf(T);
    var i: usize = 0;
    while (i + L <= dst.len) : (i += L) store(L, U, out[i * @sizeOf(T) ..], @byteSwap(load(L, U, src[i * @sizeOf(T) ..])));
    for (i..dst.len) |k| store(1, U, out[k * @sizeOf(T) ..], @byteSwap(load(1, U, src[k * @sizeOf(T) ..])));
}

test "i24 pack / unpack" {
    const L = N / 4;
    var prng: std.Random.DefaultPrng = .init(24);
    const r = prng.random();
    for ([_]usize{ 0, 1, L - 1, L, L + 1, 3 * L + 5 }) |n| {
        var samples: [3 * N + 8]i24 = undefined;
        for (samples[0..n]) |*s| s.* = r.int(i24);
        if (n > 1) {
            samples[0] = std.math.minInt(i24);
            samples[1] = std.math.maxInt(i24);
        }
        var bytes: [3 * samples.len]u8 = undefined;
        packI24Little(samples[0..n], bytes[0 .. 3 * n]);
        for (samples[0..n], 0..) |s, k| try std.testing.expectEqual(s, std.mem.readInt(i24, bytes[3 * k ..][0..3], .little));
        var back: [samples.len]i24 = undefined;
        unpackI24Little(bytes[0 .. 3 * n], back[0..n]);
        try std.testing.expectEqualSlices(i24, samples[0..n], back[0..n]);
    }
}
