//! QOA file and frame headers. All integers are big endian.
//!
//! File   = header (8 bytes) + frames
//! header = "qoaf" ++ u32 samples per channel (0 = streaming / unknown)
//! frame  = u8 channels, u24 sample rate, u16 samples per channel, u16 frame bytes,
//!          per channel: LMS state (4 x i16 history, 4 x i16 weights),
//!          then up to 256 slices per channel (interleaved by channel):
//!          u64 = 4-bit scale factor index + 20 x 3-bit quantized residuals.
const std = @import("std");
const Error = @import("../error.zig").Error;

pub const MAGIC = "qoaf";
pub const SIZE = 8;
pub const SLICE_LEN = 20;
pub const SLICES_PER_FRAME = 256;
pub const FRAME_LEN = SLICES_PER_FRAME * SLICE_LEN;
pub const LMS_LEN = 4;
/// The spec allows up to 255 channels; the reference encoder caps it at 8.
pub const MAX_CHANNELS = 255;

/// Bytes of one frame with `samples` samples per channel.
pub fn frameSize(channels: usize, samples: usize) usize {
    const slices = (samples + SLICE_LEN - 1) / SLICE_LEN;
    return 8 + LMS_LEN * 4 * channels + 8 * slices * channels;
}

pub const Frame = struct {
    channels: u8,
    sample_rate: u24,
    samples: u16,
    size: u16,

    pub fn parse(bytes: []const u8) !Frame {
        if (bytes.len < 8) return Error.UnexpectedEndOfData;
        const h: Frame = .{
            .channels = bytes[0],
            .sample_rate = std.mem.readInt(u24, bytes[1..4], .big),
            .samples = std.mem.readInt(u16, bytes[4..6], .big),
            .size = std.mem.readInt(u16, bytes[6..8], .big),
        };
        if (h.channels == 0) return Error.InvalidChannels;
        if (h.sample_rate == 0) return Error.InvalidSampleRate;
        if (h.samples == 0 or h.samples > FRAME_LEN) return Error.InvalidFrame;
        if (h.size != frameSize(h.channels, h.samples)) return Error.InvalidFrame;
        if (h.size > bytes.len) return Error.UnexpectedEndOfData;
        return h;
    }

    pub fn write(h: Frame, w: *std.Io.Writer) !void {
        try w.writeInt(u8, h.channels, .big);
        try w.writeInt(u24, h.sample_rate, .big);
        try w.writeInt(u16, h.samples, .big);
        try w.writeInt(u16, h.size, .big);
    }
};
