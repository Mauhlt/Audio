//! ITU-T G.711 A-law and mu-law: 8-bit companded codes -> 16-bit PCM.
const std = @import("std");

pub const alaw_table: [256]i16 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]i16 = undefined;
    for (0..256) |i| {
        const a: u8 = @as(u8, @intCast(i)) ^ 0x55;
        const seg: u4 = @intCast((a & 0x70) >> 4);
        var v: i32 = (@as(i32, a & 0x0F) << 4) + 8;
        if (seg != 0) v = (v + 0x100) << (seg - 1);
        t[i] = @intCast(if (a & 0x80 != 0) v else -v);
    }
    break :blk t;
};

pub const mulaw_table: [256]i16 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]i16 = undefined;
    for (0..256) |i| {
        const u: u8 = ~@as(u8, @intCast(i));
        const exp: u3 = @intCast((u >> 4) & 0x07);
        const v: i32 = (((@as(i32, u & 0x0F) << 3) + 0x84) << exp) - 0x84;
        t[i] = @intCast(if (u & 0x80 != 0) -v else v);
    }
    break :blk t;
};

/// Expands every code in `src` through `table` into `dst`.
pub fn expand(table: *const [256]i16, src: []const u8, dst: []align(1) i16) void {
    for (dst, src) |*d, s| d.* = table[s];
}

test "G.711 tables" {
    // ITU-T G.711 reference points
    try std.testing.expectEqual(@as(i16, 0), mulaw_table[0xFF]);
    try std.testing.expectEqual(@as(i16, 0), mulaw_table[0x7F]);
    try std.testing.expectEqual(@as(i16, -32124), mulaw_table[0x00]);
    try std.testing.expectEqual(@as(i16, 32124), mulaw_table[0x80]);
    try std.testing.expectEqual(@as(i16, 8), alaw_table[0xD5]);
    try std.testing.expectEqual(@as(i16, -8), alaw_table[0x55]);
    try std.testing.expectEqual(@as(i16, 32256), alaw_table[0xAA]);
    try std.testing.expectEqual(@as(i16, -32256), alaw_table[0x2A]);
}
