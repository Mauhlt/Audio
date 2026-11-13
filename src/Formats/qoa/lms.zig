//! The QOA predictor (a 4-tap sign-sign LMS filter) and the quantization tables.
//! Integer math wraps like the reference C (32-bit `int`), so odd inputs encode the same.
const std = @import("std");
const LMS_LEN = 4; // header.LMS_LEN

pub const scalefactor_tab = [16]i32{ 1, 7, 21, 45, 84, 138, 211, 304, 421, 562, 731, 928, 1157, 1419, 1715, 2048 };

/// ceil(2^16 / scalefactor): lets the encoder divide with a multiply.
pub const reciprocal_tab: [16]i32 = blk: {
    var t: [16]i32 = undefined;
    for (&t, scalefactor_tab) |*r, sf| r.* = @divTrunc((1 << 16) + sf - 1, sf);
    break :blk t;
};

/// round(scalefactor * {0.75, -0.75, 2.5, -2.5, 4.5, -4.5, 7, -7}), rounding halves away from 0.
pub const dequant_tab: [16][8]i32 = blk: {
    const q = [8]f64{ 0.75, -0.75, 2.5, -2.5, 4.5, -4.5, 7, -7 };
    var t: [16][8]i32 = undefined;
    for (&t, scalefactor_tab) |*row, sf| {
        for (row, q) |*v, f| v.* = @intFromFloat(@round(@as(f64, @floatFromInt(sf)) * f));
    }
    break :blk t;
};

/// Residual clamped to -8..8 (index + 8) -> 3-bit quantized value.
pub const quant_tab = [17]u3{ 7, 7, 7, 5, 5, 3, 3, 1, 0, 0, 2, 2, 4, 4, 6, 6, 6 };

pub const Lms = struct {
    history: [LMS_LEN]i32 = @splat(0),
    weights: [LMS_LEN]i32 = @splat(0),

    /// What the encoder starts every channel with.
    pub const initial: Lms = .{ .weights = .{ 0, 0, -(1 << 13), 1 << 14 } };

    pub fn predict(self: *const Lms) i32 {
        var p: i32 = 0;
        for (self.weights, self.history) |w, h| p +%= w *% h;
        return p >> 13;
    }

    pub fn update(self: *Lms, sample: i32, residual: i32) void {
        const delta = residual >> 4;
        for (&self.weights, self.history) |*w, h| w.* +%= if (h < 0) -%delta else delta;
        self.history = .{ self.history[1], self.history[2], self.history[3], sample };
    }

    /// Big-endian 4 x i16 words, as stored in a frame header.
    pub fn packed16(values: [LMS_LEN]i32) u64 {
        var v: u64 = 0;
        for (values) |x| v = (v << 16) | @as(u16, @truncate(@as(u32, @bitCast(x))));
        return v;
    }

    pub fn unpack16(v_in: u64) [LMS_LEN]i32 {
        var v = v_in;
        var out: [LMS_LEN]i32 = undefined;
        for (&out) |*x| {
            x.* = @as(i16, @bitCast(@as(u16, @truncate(v >> 48))));
            v <<= 16;
        }
        return out;
    }
};

pub fn clampS16(v: i32) i32 {
    return std.math.clamp(v, -32768, 32767);
}

/// residual / scalefactor, rounded away from zero, using the reciprocal table.
pub fn div(v: i32, sf: usize) i32 {
    const n = (v *% reciprocal_tab[sf] +% (1 << 15)) >> 16;
    return n + (@as(i32, @intFromBool(v > 0)) - @intFromBool(v < 0)) - (@as(i32, @intFromBool(n > 0)) - @intFromBool(n < 0));
}

/// The reference encoder's penalty for large LMS weights, in its 32-bit `int` arithmetic:
/// ((sum of squared weights) >> 18) - 0x8ff, at least 0, then squared (wrapping).
pub fn weightsPenalty(weights: [LMS_LEN]i32) i32 {
    var sum: i32 = 0;
    for (weights) |w| sum +%= w *% w;
    const p = @max(0, (sum >> 18) - 0x8ff);
    return p *% p;
}

test "QOA - tables match the reference" {
    // rows of qoa_dequant_tab in qoa.h
    try std.testing.expectEqualSlices(i32, &.{ 1, -1, 3, -3, 5, -5, 7, -7 }, &dequant_tab[0]);
    try std.testing.expectEqualSlices(i32, &.{ 5, -5, 18, -18, 32, -32, 49, -49 }, &dequant_tab[1]);
    try std.testing.expectEqualSlices(i32, &.{ 1536, -1536, 5120, -5120, 9216, -9216, 14336, -14336 }, &dequant_tab[15]);
    for (scalefactor_tab, 1..) |sf, s| {
        try std.testing.expectEqual(@as(i32, @intFromFloat(@round(std.math.pow(f64, @floatFromInt(s), 2.75)))), sf);
    }
    try std.testing.expectEqualSlices(i32, &.{ 65536, 9363, 3121, 1457, 781, 475, 311, 216, 156, 117, 90, 71, 57, 47, 39, 32 }, &reciprocal_tab);
}
