//! MPEG audio frame header fields, and splitting a stream into frames (sync).
const std = @import("std");
const T = @import("tables.zig");

pub const HDR_SIZE = 4;
pub const MAX_FREE_FORMAT_FRAME_SIZE = 2304;
pub const MAX_BITRESERVOIR_BYTES = 511;
pub const MAX_FRAME_SYNC_MATCHES = 10;
/// Most samples per channel one frame can produce.
pub const MAX_FRAME_SAMPLES = 1152;
pub const MODE_MONO = 3;
pub const MODE_JOINT_STEREO = 1;

pub const Header = struct {
    pub fn isMono(h: []const u8) bool {
        return (h[3] & 0xC0) == 0xC0;
    }
    pub fn isMsStereo(h: []const u8) bool {
        return (h[3] & 0xE0) == 0x60;
    }
    pub fn isIStereo(h: []const u8) bool {
        return stereoMode(h) == MODE_JOINT_STEREO and (h[3] & 0x10) != 0;
    }
    pub fn isFreeFormat(h: []const u8) bool {
        return (h[2] & 0xF0) == 0;
    }
    pub fn isCrc(h: []const u8) bool {
        return (h[1] & 1) == 0;
    }
    pub fn testPadding(h: []const u8) bool {
        return (h[2] & 0x2) != 0;
    }
    pub fn isMpeg1(h: []const u8) bool {
        return (h[1] & 0x8) != 0;
    }
    pub fn isNotMpeg25(h: []const u8) bool {
        return (h[1] & 0x10) != 0;
    }
    pub fn stereoMode(h: []const u8) u8 {
        return (h[3] >> 6) & 3;
    }
    pub fn stereoModeExt(h: []const u8) u8 {
        return (h[3] >> 4) & 3;
    }
    /// 3 = Layer I, 2 = Layer II, 1 = Layer III
    pub fn layerBits(h: []const u8) u8 {
        return (h[1] >> 1) & 3;
    }
    /// 1, 2 or 3
    pub fn layer(h: []const u8) u8 {
        return 4 - layerBits(h);
    }
    pub fn bitrateIdx(h: []const u8) u8 {
        return h[2] >> 4;
    }
    pub fn sampleRateIdx(h: []const u8) u8 {
        return (h[2] >> 2) & 3;
    }
    /// 0..8: 44.1/48/32 kHz for MPEG-1, then MPEG-2, then MPEG-2.5
    pub fn mySampleRate(h: []const u8) u8 {
        return sampleRateIdx(h) + (((h[1] >> 3) & 1) + ((h[1] >> 4) & 1)) * 3;
    }
    pub fn isFrame576(h: []const u8) bool {
        return (h[1] & 14) == 2;
    }
    pub fn isLayer1(h: []const u8) bool {
        return (h[1] & 6) == 6;
    }

    pub fn valid(h: []const u8) bool {
        return h[0] == 0xff and
            ((h[1] & 0xF0) == 0xf0 or (h[1] & 0xFE) == 0xe2) and
            layerBits(h) != 0 and bitrateIdx(h) != 15 and sampleRateIdx(h) != 3;
    }

    /// Same stream: version, layer, sample rate and free-format-ness match.
    pub fn compare(h1: []const u8, h2: []const u8) bool {
        return valid(h2) and
            ((h1[1] ^ h2[1]) & 0xFE) == 0 and
            ((h1[2] ^ h2[2]) & 0x0C) == 0 and
            isFreeFormat(h1) == isFreeFormat(h2);
    }

    pub fn bitrateKbps(h: []const u8) u32 {
        return 2 * @as(u32, T.halfrate[@intFromBool(isMpeg1(h))][layerBits(h) - 1][bitrateIdx(h)]);
    }

    pub fn sampleRateHz(h: []const u8) u32 {
        const hz = [3]u32{ 44100, 48000, 32000 };
        return (hz[sampleRateIdx(h)] >> @intFromBool(!isMpeg1(h))) >> @intFromBool(!isNotMpeg25(h));
    }

    pub fn frameSamples(h: []const u8) u32 {
        return if (isLayer1(h)) 384 else @as(u32, 1152) >> @intFromBool(isFrame576(h));
    }

    pub fn frameBytes(h: []const u8, free_format_size: u32) u32 {
        var n = frameSamples(h) * bitrateKbps(h) * 125 / sampleRateHz(h);
        if (isLayer1(h)) n &= ~@as(u32, 3);
        return if (n != 0) n else free_format_size;
    }

    pub fn padding(h: []const u8) u32 {
        return if (testPadding(h)) (if (isLayer1(h)) 4 else 1) else 0;
    }
};

// ───────────────────────────── frame sync ─────────────────────────────

/// Enough state to split a stream into frames the way the decoder does.
pub const Sync = struct {
    header: [4]u8 = @splat(0),
    free_format_bytes: u32 = 0,

    pub const Found = struct {
        /// garbage bytes before the frame
        skip: usize,
        /// frame length incl. padding (0 = no frame found; `skip` bytes may be discarded)
        len: usize,
        /// the decoder state must be reset (sync was lost)
        resync: bool,
    };

    pub fn next(self: *Sync, mp3: []const u8) Found {
        if (mp3.len > 4 and self.header[0] == 0xff and Header.compare(&self.header, mp3)) {
            const size = Header.frameBytes(mp3, self.free_format_bytes) + Header.padding(mp3);
            if (size == mp3.len or (size + HDR_SIZE <= mp3.len and Header.compare(mp3, mp3[size..]))) {
                @memcpy(&self.header, mp3[0..4]);
                return .{ .skip = 0, .len = size, .resync = false };
            }
        }
        self.* = .{};
        var size: u32 = 0;
        const i = findFrame(mp3, &self.free_format_bytes, &size);
        if (size == 0 or i + size > mp3.len) return .{ .skip = i, .len = 0, .resync = true };
        @memcpy(&self.header, mp3[i..][0..4]);
        return .{ .skip = i, .len = size, .resync = true };
    }
};

pub fn matchFrame(hdr: []const u8, frame_bytes: u32) bool {
    var i: usize = 0;
    var nmatch: usize = 0;
    while (nmatch < MAX_FRAME_SYNC_MATCHES) : (nmatch += 1) {
        i += Header.frameBytes(hdr[i..], frame_bytes) + Header.padding(hdr[i..]);
        if (i + HDR_SIZE > hdr.len) return nmatch > 0;
        if (!Header.compare(hdr, hdr[i..])) return false;
    }
    return true;
}

pub fn findFrame(mp3: []const u8, free_format_bytes: *u32, ptr_frame_bytes: *u32) usize {
    if (mp3.len <= HDR_SIZE) {
        ptr_frame_bytes.* = 0;
        return mp3.len;
    }
    for (0..mp3.len - HDR_SIZE) |i| {
        const h = mp3[i..];
        if (!Header.valid(h)) continue;
        var frame_bytes = Header.frameBytes(h, free_format_bytes.*);
        var frame_and_padding = frame_bytes + Header.padding(h);
        var k: usize = HDR_SIZE;
        while (frame_bytes == 0 and k < MAX_FREE_FORMAT_FRAME_SIZE and i + 2 * k < mp3.len - HDR_SIZE) : (k += 1) {
            if (Header.compare(h, h[k..])) {
                const fb = k - Header.padding(h);
                const nextfb = fb + Header.padding(h[k..]);
                if (i + k + nextfb + HDR_SIZE > mp3.len or !Header.compare(h, h[k + nextfb ..])) continue;
                frame_and_padding = @intCast(k);
                frame_bytes = @intCast(fb);
                free_format_bytes.* = @intCast(fb);
            }
        }
        if ((frame_bytes != 0 and i + frame_and_padding <= mp3.len and matchFrame(h, frame_bytes)) or
            (i == 0 and frame_and_padding == mp3.len))
        {
            ptr_frame_bytes.* = frame_and_padding;
            return i;
        }
        free_format_bytes.* = 0;
    }
    ptr_frame_bytes.* = 0;
    return mp3.len;
}

test "Header helpers" {
    // MPEG-1 Layer III, 128 kbps, 44.1 kHz, padding, joint stereo
    const h = [4]u8{ 0xFF, 0xFB, 0x92, 0x64 };
    try std.testing.expect(Header.valid(&h));
    try std.testing.expectEqual(@as(u8, 3), Header.layer(&h));
    try std.testing.expectEqual(@as(u32, 128), Header.bitrateKbps(&h));
    try std.testing.expectEqual(@as(u32, 44100), Header.sampleRateHz(&h));
    try std.testing.expectEqual(@as(u32, 1152), Header.frameSamples(&h));
    try std.testing.expectEqual(@as(u32, 417), Header.frameBytes(&h, 0));
    try std.testing.expectEqual(@as(u32, 1), Header.padding(&h));
    try std.testing.expect(Header.isMsStereo(&h));
    // MPEG-2.5, 8 kHz, 8 kbps, mono
    const h25 = [4]u8{ 0xFF, 0xE3, 0x18, 0xC0 };
    try std.testing.expect(Header.valid(&h25));
    try std.testing.expectEqual(@as(u32, 8000), Header.sampleRateHz(&h25));
    try std.testing.expectEqual(@as(u32, 576), Header.frameSamples(&h25));
    try std.testing.expect(Header.isMono(&h25));
}
