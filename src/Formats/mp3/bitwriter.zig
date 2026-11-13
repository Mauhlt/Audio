//! MSB-first bit writer into a fixed buffer (one MP3 frame).
const std = @import("std");

const BitWriter = @This();

buf: []u8,
/// bits written
pos: usize = 0,

pub fn init(buf: []u8) BitWriter {
    @memset(buf, 0);
    return .{ .buf = buf };
}

/// Writes the low `n` bits of `v` (n <= 32), most significant first.
pub fn write(self: *BitWriter, v: u32, n: u6) void {
    var left: u6 = n;
    while (left > 0) {
        const byte = self.pos >> 3;
        const free: u6 = @intCast(8 - (self.pos & 7));
        const take = @min(free, left);
        const shift: u5 = @intCast(left - take);
        const chunk: u8 = @truncate((v >> shift) & ((@as(u32, 1) << @intCast(take)) - 1));
        self.buf[byte] |= chunk << @intCast(free - take);
        self.pos += take;
        left -= take;
    }
}

test "BitWriter" {
    var buf: [4]u8 = undefined;
    var w: BitWriter = .init(&buf);
    w.write(0b101, 3);
    w.write(0x1F, 5);
    w.write(0xABC, 12);
    try std.testing.expectEqual(@as(usize, 20), w.pos);
    try std.testing.expectEqualSlices(u8, &.{ 0b1011_1111, 0xAB, 0xC0, 0 }, &buf);
}
