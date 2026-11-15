//! What a decoder learns from a file's header, before touching sample data.
//! Every codec exposes `info(data) !Info`, so callers can size (or reuse)
//! the destination buffer before calling `decodeInto`.
const std = @import("std");
const SampleTag = @import("Samples/samples.zig").SampleTag;

sample_rate: u32,
channels: u16,
/// Samples per channel ("PCM frames").
frames: u64,
/// Layout `decodeInto` writes (interleaved, native endian).
tag: SampleTag,

/// frames * channels
pub fn nSamples(self: @This()) !usize {
    if (self.channels == 0 or self.sample_rate == 0) return error.InvalidDimensions;
    const n, const overflow = @mulWithOverflow(self.frames, @as(u64, self.channels));
    if (overflow != 0 or n > std.math.maxInt(usize)) return error.InvalidDimensions;
    return @intCast(n);
}

/// Bytes needed to hold the decoded samples.
pub fn byteLen(self: @This()) !usize {
    const n, const overflow = @mulWithOverflow(try self.nSamples(), self.tag.bytesPerSample());
    if (overflow != 0) return error.InvalidDimensions;
    return n;
}

/// Duration in seconds.
pub fn seconds(self: @This()) f64 {
    return @as(f64, @floatFromInt(self.frames)) / @as(f64, @floatFromInt(self.sample_rate));
}
