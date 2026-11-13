//! Bit readers: `Bs` for headers / side info, `BitCache` for Huffman-coded main data.
const std = @import("std");

pub const Bs = struct {
    buf: []const u8,
    pos: i32 = 0,
    limit: i32,

    pub fn init(data: []const u8) Bs {
        return .{ .buf = data, .limit = @intCast(data.len * 8) };
    }

    pub fn getBits(bs: *Bs, n: u32) u32 {
        if (n == 0) return 0;
        const s: u32 = @intCast(bs.pos & 7);
        var shl: i32 = @intCast(n + s);
        var p: usize = @intCast(bs.pos >> 3);
        bs.pos += @intCast(n);
        if (bs.pos > bs.limit) return 0;
        var next: u32 = bs.buf[p] & (@as(u32, 255) >> @intCast(s));
        p += 1;
        var cache: u32 = 0;
        shl -= 8;
        while (shl > 0) : (shl -= 8) {
            cache |= next << @intCast(shl);
            next = bs.buf[p];
            p += 1;
        }
        return cache | (next >> @intCast(-shl));
    }
};

// ───────────────────────────── decoder state ─────────────────────────────

/// Bit cache over main data; bytes past the end read as zero.
pub const BitCache = struct {
    buf: []const u8,
    next: usize,
    cache: u32,
    sh: i32,

    pub fn byte(self: *const BitCache, i: usize) u32 {
        return if (i < self.buf.len) self.buf[i] else 0;
    }
    pub fn peek(self: *const BitCache, n: u32) u32 {
        return @truncate(@as(u64, self.cache) >> @intCast(32 - n));
    }
    pub fn flush(self: *BitCache, n: u32) void {
        self.cache = @truncate(@as(u64, self.cache) << @intCast(n));
        self.sh += @intCast(n);
    }
    pub fn check(self: *BitCache) void {
        while (self.sh >= 0) : (self.sh -= 8) {
            self.cache |= self.byte(self.next) << @intCast(self.sh);
            self.next += 1;
        }
    }
    pub fn bitPos(self: *const BitCache) i32 {
        return @as(i32, @intCast(self.next * 8)) - 24 + self.sh;
    }
    pub fn negative(self: *const BitCache) bool {
        return (self.cache >> 31) != 0;
    }
};
