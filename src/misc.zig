const std = @import("std");

pub const AudioTag = enum {
    aac,
    aiff,
    flac,
    mp3,
    ogg,
    opus,
    qoa,
    wav,
};

/// Extra spellings that map onto an `AudioTag` (looked up without the leading '.').
pub const mapAudioTagFromExt: std.StaticStringMap(AudioTag) = .initComptime(.{
    .{ "wave", .wav },
    .{ "rf64", .wav },
    .{ "bwf", .wav },
    // the MP3 decoder also handles MPEG-1/2 Layer I and II
    .{ "mp1", .mp3 },
    .{ "mp2", .mp3 },
    .{ "mpa", .mp3 },
    .{ "aif", .aiff },
    .{ "aifc", .aiff },
    .{ "m4a", .aac },
    .{ "oga", .ogg },
});

/// "foo/bar.WAV" -> .wav
pub fn tagFromExt(path: []const u8) !AudioTag {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return error.InvalidFileExtension;
    var buf: [8]u8 = undefined;
    if (ext.len - 1 > buf.len) return error.InvalidFileExtension;
    const lower = std.ascii.lowerString(&buf, ext[1..]);
    return std.meta.stringToEnum(AudioTag, lower) orelse
        mapAudioTagFromExt.get(lower) orelse
        error.InvalidFileExtension;
}

/// Guesses the format from the first bytes of a file (null if unknown).
pub fn tagFromMagic(data: []const u8) ?AudioTag {
    if (data.len < 4) return null;
    if (data.len >= 12 and (std.mem.eql(u8, data[0..4], "RIFF") or std.mem.eql(u8, data[0..4], "RF64")) and
        std.mem.eql(u8, data[8..12], "WAVE")) return .wav;
    if (std.mem.eql(u8, data[0..4], "qoaf")) return .qoa;
    if (std.mem.eql(u8, data[0..4], "fLaC")) return .flac;
    if (std.mem.eql(u8, data[0..4], "OggS")) return .ogg;
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "FORM") and
        (std.mem.eql(u8, data[8..12], "AIFF") or std.mem.eql(u8, data[8..12], "AIFC"))) return .aiff;
    if (std.mem.eql(u8, data[0..3], "ID3")) return .mp3;
    if (data[0] == 0xFF and (data[1] & 0xE0) == 0xE0) {
        // MPEG audio frame sync (layer bits != 0) vs. ADTS AAC (layer bits == 0)
        return if ((data[1] & 0x06) != 0) .mp3 else .aac;
    }
    return null;
}

/// Reads the whole file into `buf`, growing it only when needed.
/// Reusing `buf` across many files avoids one allocation per file.
pub fn readFileInto(
    io: std.Io,
    gpa: std.mem.Allocator,
    file: std.Io.File,
    buf: *std.ArrayList(u8),
) ![]const u8 {
    const len: usize = @intCast(try file.length(io));
    buf.clearRetainingCapacity();
    try buf.ensureTotalCapacity(gpa, len);
    buf.items.len = len;
    const n_bytes = try file.readPositionalAll(io, buf.items, 0);
    if (n_bytes != len) return error.FailedToReadFile;
    return buf.items;
}

test "tagFromExt" {
    try std.testing.expectEqual(AudioTag.wav, try tagFromExt("a/b.WAV"));
    try std.testing.expectEqual(AudioTag.wav, try tagFromExt("b.wave"));
    try std.testing.expectEqual(AudioTag.mp3, try tagFromExt("x.mp3"));
    try std.testing.expectEqual(AudioTag.mp3, try tagFromExt("x.MP2"));
    try std.testing.expectEqual(AudioTag.qoa, try tagFromExt("x.qoa"));
    try std.testing.expectEqual(AudioTag.aiff, try tagFromExt("x.aif"));
    try std.testing.expectError(error.InvalidFileExtension, tagFromExt("noext"));
    try std.testing.expectError(error.InvalidFileExtension, tagFromExt("x.verylongext"));
}

test "tagFromMagic" {
    try std.testing.expectEqual(AudioTag.wav, tagFromMagic("RIFF\x00\x00\x00\x00WAVEfmt ").?);
    try std.testing.expectEqual(AudioTag.qoa, tagFromMagic("qoaf\x00\x00\x00\x01").?);
    try std.testing.expectEqual(AudioTag.mp3, tagFromMagic("ID3\x04\x00").?);
    try std.testing.expectEqual(AudioTag.mp3, tagFromMagic("\xFF\xFB\x90\x00").?);
    try std.testing.expectEqual(AudioTag.aac, tagFromMagic("\xFF\xF1\x50\x80").?);
    try std.testing.expectEqual(@as(?AudioTag, null), tagFromMagic("abcd"));
}
