//! Interleaved PCM sample storage: one tagged slice per sample type.
//! Frame `i`, channel `c` lives at index `i * channels + c`.
//!
//! Conversions follow the usual audio conventions:
//!   - integers are signed and full scale is 2^(bits-1), except `u8` (WAV 8-bit) which is offset by 128
//!   - floats are nominally in [-1, 1]; converting to an integer rounds and clamps
const std = @import("std");
const misc = @import("misc.zig");
const simd = @import("simd.zig");
const lanes = misc.lanes;

pub const SampleTag = enum(u8) {
    u8,
    i16,
    i24,
    i32,
    f32,
    f64,

    pub fn Type(comptime tag: SampleTag) type {
        return switch (tag) {
            .u8 => u8,
            .i16 => i16,
            .i24 => i24,
            .i32 => i32,
            .f32 => f32,
            .f64 => f64,
        };
    }

    /// In-memory size of one sample (i24 occupies 4 bytes in memory, 3 in files).
    pub fn bytesPerSample(tag: SampleTag) usize {
        return switch (tag) {
            inline else => |t| @sizeOf(t.Type()),
        };
    }

    /// Significant bits per sample.
    pub fn bits(tag: SampleTag) u16 {
        return switch (tag) {
            .u8 => 8,
            .i16 => 16,
            .i24 => 24,
            .i32, .f32 => 32,
            .f64 => 64,
        };
    }

    pub fn isFloat(tag: SampleTag) bool {
        return tag == .f32 or tag == .f64;
    }
};

pub const Samples = union(SampleTag) {
    u8: []u8,
    i16: []i16,
    i24: []i24,
    i32: []i32,
    f32: []f32,
    f64: []f64,

    /// Allocates `n` (uninitialized) samples of type `tag`.
    pub fn alloc(tag: SampleTag, gpa: std.mem.Allocator, n: usize) !Samples {
        return switch (tag) {
            inline else => |t| @unionInit(Samples, @tagName(t), try gpa.alloc(t.Type(), n)),
        };
    }

    /// Copies `data` into a new allocation.
    pub fn init(comptime tag: SampleTag, gpa: std.mem.Allocator, data: []const tag.Type()) !Samples {
        return @unionInit(Samples, @tagName(tag), try gpa.dupe(tag.Type(), data));
    }

    /// Reinterprets `bytes` (allocated with the alignment of `tag`'s type) as samples, taking ownership.
    pub fn fromBytes(tag: SampleTag, bytes: []u8) Samples {
        return switch (tag) {
            inline else => |t| @unionInit(Samples, @tagName(t), @alignCast(std.mem.bytesAsSlice(t.Type(), bytes))),
        };
    }

    pub fn asBytes(self: Samples) []u8 {
        return switch (self) {
            inline else => |s| std.mem.sliceAsBytes(s),
        };
    }

    /// Number of samples (frames * channels).
    pub fn len(self: Samples) usize {
        return switch (self) {
            inline else => |s| s.len,
        };
    }

    pub fn deinit(self: Samples, gpa: std.mem.Allocator) void {
        switch (self) {
            inline else => |s| gpa.free(s),
        }
    }

    pub fn dupe(self: Samples, gpa: std.mem.Allocator) !Samples {
        return switch (self) {
            inline else => |s, t| @unionInit(Samples, @tagName(t), try gpa.dupe(t.Type(), s)),
        };
    }

    /// Sample `i` as a float in nominal range [-1, 1].
    pub fn getF64(self: Samples, i: usize) f64 {
        return switch (self) {
            inline else => |s| toF64(s[i]),
        };
    }

    /// Returns a new buffer with every sample converted to `tag` (always allocates).
    pub fn convert(self: Samples, tag: SampleTag, gpa: std.mem.Allocator) !Samples {
        const out = try alloc(tag, gpa, self.len());
        switch (self) {
            inline else => |src| switch (out) {
                inline else => |dst| convertSlice(@TypeOf(dst[0]), dst, @TypeOf(src[0]), src),
            },
        }
        return out;
    }
};

/// Converts `src` into `dst` (same length). Vector code, bit-identical to `convertScalar`.
pub fn convertSlice(comptime D: type, dst: []D, comptime S: type, src: []const S) void {
    std.debug.assert(dst.len == src.len);
    if (D == S) return @memcpy(dst, src);
    const C = Compute(D, S);
    const L = lanes(C);
    var i: usize = 0;
    while (i + L <= src.len) : (i += L) storeV(D, L, dst[i..], convertV(D, S, L, loadV(S, L, src[i..])));
    convertScalar(D, dst[i..], S, src[i..]);
}

/// The reference (scalar) conversion: every vector kernel must match it exactly.
pub fn convertScalar(comptime D: type, dst: []D, comptime S: type, src: []const S) void {
    std.debug.assert(dst.len == src.len);
    if (D == S) return @memcpy(dst, src);
    if (comptime isInt(D) and isInt(S)) {
        // integer <-> integer: shift between full scales (exact when widening)
        for (dst, src) |*d, s| d.* = intToInt(D, S, s);
    } else {
        for (dst, src) |*d, s| d.* = fromF64(D, toF64(s));
    }
}

/// Lane type the vector kernel computes in. f32 is exact for every type up to 24 bits
/// (and only scales by powers of two), so it gives the same results as the f64 reference;
/// i32 and f64 need f64. Integer <-> integer stays in i32.
fn Compute(comptime D: type, comptime S: type) type {
    if (isInt(D) and isInt(S)) return i32;
    if (D == f64 or S == f64 or D == i32 or S == i32) return f64;
    return f32;
}

inline fn loadV(comptime T: type, comptime L: usize, src: []const T) @Vector(L, if (T == i24) i32 else T) {
    if (T == i24) return simd.loadI24(L, src);
    return src[0..L].*;
}

inline fn storeV(comptime T: type, comptime L: usize, dst: []T, v: @Vector(L, if (T == i24) i32 else T)) void {
    if (T == i24) return simd.storeI24(L, dst, v);
    dst[0..L].* = v;
}

/// Signed lanes of an integer sample vector (u8 is offset binary).
inline fn signedV(comptime S: type, comptime L: usize, v: anytype) @Vector(L, i32) {
    const w: @Vector(L, i32) = @intCast(v);
    return if (S == u8) w - @as(@Vector(L, i32), @splat(128)) else w;
}

/// i32 lanes known to fit `T` -> `T` lanes (i24 stays in i32 lanes).
/// Uses @truncate: Zig's LLVM backend at -O0 miscompiles i32 -> u8 vector @intCast (see the
/// "zig canary" test at the end of this file).
inline fn narrow(comptime T: type, comptime L: usize, v: @Vector(L, i32)) @Vector(L, if (T == i24) i32 else T) {
    if (T == i24 or T == i32) return v;
    if (T == u8) return @truncate(@as(@Vector(L, u32), @bitCast(v)));
    return @truncate(v);
}

inline fn convertV(comptime D: type, comptime S: type, comptime L: usize, v: anytype) @Vector(L, if (D == i24) i32 else D) {
    const C = Compute(D, S);
    if (C == i32) {
        const x = signedV(S, L, v);
        const sb = intBits(S);
        const db = intBits(D);
        const r = if (db >= sb) x << @splat(db - sb) else x >> @splat(sb - db);
        return narrow(D, L, if (D == u8) r + @as(@Vector(L, i32), @splat(128)) else r);
    }
    const VC = @Vector(L, C);
    // to the nominal [-1, 1] range
    const x: VC = if (comptime isInt(S)) blk: {
        const scale: C = 1.0 / @as(C, @floatFromInt(@as(i64, 1) << (intBits(S) - 1)));
        break :blk @as(VC, @floatFromInt(signedV(S, L, v))) * @as(VC, @splat(scale));
    } else @floatCast(v);
    if (comptime !isInt(D)) return @floatCast(x);
    // round, clamp, NaN -> 0
    const full: C = @floatFromInt(@as(i64, 1) << (intBits(D) - 1));
    const y = @min(@max(@round(x * @as(VC, @splat(full))), @as(VC, @splat(-full))), @as(VC, @splat(full - 1)));
    const z = @select(C, x == x, y, @as(VC, @splat(0)));
    const iv: @Vector(L, i32) = @intFromFloat(z);
    return narrow(D, L, if (D == u8) iv + @as(@Vector(L, i32), @splat(128)) else iv);
}

fn isInt(comptime T: type) bool {
    return @typeInfo(T) == .int;
}

/// Signed value of an integer sample (u8 is offset binary).
fn signed(comptime S: type, s: S) i32 {
    return if (S == u8) @as(i32, s) - 128 else s;
}

fn intBits(comptime T: type) comptime_int {
    return @typeInfo(T).int.bits;
}

fn intToInt(comptime D: type, comptime S: type, s: S) D {
    const v = signed(S, s);
    const sb = intBits(S);
    const db = intBits(D);
    const r: i32 = if (db >= sb) v << (db - sb) else v >> (sb - db);
    return if (D == u8) @intCast(r + 128) else @intCast(r);
}

pub fn toF64(s: anytype) f64 {
    const S = @TypeOf(s);
    if (S == f32 or S == f64) return s;
    const full: f64 = @floatFromInt(@as(i64, 1) << (intBits(S) - 1));
    return @as(f64, @floatFromInt(signed(S, s))) / full;
}

pub fn fromF64(comptime D: type, x: f64) D {
    if (D == f32 or D == f64) return @floatCast(x);
    const b = intBits(D);
    const full: f64 = @floatFromInt(@as(i64, 1) << (b - 1));
    const max: f64 = full - 1;
    if (std.math.isNan(x)) return if (D == u8) 128 else 0;
    const v = std.math.clamp(@round(x * full), -full, max);
    const iv: i64 = @intFromFloat(v);
    return if (D == u8) @intCast(iv + 128) else @intCast(iv);
}

test "Samples - conversions" {
    const gpa = std.testing.allocator;
    const s16 = try Samples.init(.i16, gpa, &.{ -32768, -16384, 0, 16384, 32767 });
    defer s16.deinit(gpa);

    const as_u8 = try s16.convert(.u8, gpa);
    defer as_u8.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0, 64, 128, 192, 255 }, as_u8.u8);

    const as_i24 = try s16.convert(.i24, gpa);
    defer as_i24.deinit(gpa);
    try std.testing.expectEqual(@as(i24, -8388608), as_i24.i24[0]);
    try std.testing.expectEqual(@as(i24, 32767 << 8), as_i24.i24[4]);

    const as_f32 = try s16.convert(.f32, gpa);
    defer as_f32.deinit(gpa);
    try std.testing.expectEqual(@as(f32, -1), as_f32.f32[0]);
    try std.testing.expectEqual(@as(f32, 0.5), as_f32.f32[3]);

    // float -> int round trips exactly, and clamps out-of-range values
    const back = try as_f32.convert(.i16, gpa);
    defer back.deinit(gpa);
    try std.testing.expectEqualSlices(i16, s16.i16, back.i16);
    var loud = [_]f32{ 2, -2, std.math.nan(f32) };
    var out: [3]i16 = undefined;
    convertSlice(i16, &out, f32, &loud);
    try std.testing.expectEqualSlices(i16, &.{ 32767, -32768, 0 }, &out);
}

test "Samples - vector conversions match the scalar reference" {
    const gpa = std.testing.allocator;
    const n = 4 * misc.N + 7; // full vectors plus a tail
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    // floats: in range, out of range, specials
    const f = try gpa.alloc(f64, n);
    defer gpa.free(f);
    const specials = [_]f64{ 0, -0.0, 1, -1, 0.5, -0.5, 1.0000001, -1.0000001, 1e30, -1e30, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64), 0.49999 / 32768.0, 0.5 / 32768.0, -0.5 / 32768.0 };
    for (f, 0..) |*x, i| x.* = if (i < specials.len) specials[i] else (r.float(f64) * 2.4 - 1.2);
    inline for (comptime std.enums.values(SampleTag)) |st| {
        const S = st.Type();
        const src = try gpa.alloc(S, n);
        defer gpa.free(src);
        if (comptime isInt(S)) {
            for (src, 0..) |*s, i| s.* = if (i < 2) (if (i == 0) std.math.minInt(S) else std.math.maxInt(S)) else r.int(S);
        } else for (src, f) |*s, x| {
            s.* = @floatCast(x);
        }
        inline for (comptime std.enums.values(SampleTag)) |dt| {
            const D = dt.Type();
            const a = try gpa.alloc(D, n);
            defer gpa.free(a);
            const b = try gpa.alloc(D, n);
            defer gpa.free(b);
            convertSlice(D, a, S, src);
            convertScalar(D, b, S, src);
            for (a, b, 0..) |x, y, i| {
                const same = if (comptime isInt(D)) x == y else (x == y or (std.math.isNan(x) and std.math.isNan(y)));
                if (!same) {
                    std.debug.print("{t} -> {t} at {}: vector {} scalar {}\n", .{ st, dt, i, x, y });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

// Compiler canary. Zig 0.18.0-dev.4 with the LLVM backend at -O0 (Debug; the x86_64 default)
// miscompiles `@intCast` from `@Vector(n, i32)` to a `@Vector(n, u8)` value: reading its lanes
// (or @reduce) gives 127 for every lane >= 128, as if narrowed with signed saturation; storing
// it to memory happens to give the right bytes, so whether a use breaks depends on how the
// result is consumed. (The self-hosted backend, -fno-llvm, and ReleaseFast are correct.)
// `narrow` avoids it with @truncate. This test
// reports SKIPPED while the bug is present, so every `zig build test` summary shows it; once a
// Zig version passes it in Debug too, `narrow` may go back to a plain @intCast.
test "zig canary: vector @intCast i32 -> u8" {
    var a: [8]i32 = .{ -128, 127, 0, 0, -1, 1, 1, 0 };
    _ = &a;
    const w: @Vector(8, i32) = a;
    const o: @Vector(8, u8) = @intCast(w + @as(@Vector(8, i32), @splat(128)));
    // storing `o` to memory gives the right bytes; reading lanes / reducing does not
    var got: [8]u8 = undefined;
    inline for (0..8) |k| got[k] = o[k];
    const want = [8]u8{ 0, 255, 128, 128, 127, 129, 129, 128 };
    if (!std.mem.eql(u8, &got, &want) or @reduce(.Max, o) != 255) {
        std.debug.print("\nzig canary: vector @intCast i32 -> u8 is still miscompiled here ({s}, {t}): got {any}; keep the @truncate workaround in Samples/samples.zig `narrow`\n", .{ @import("builtin").zig_version_string, @import("builtin").mode, got });
        return error.SkipZigTest;
    }
}
