//! One shared, de-duplicated error set for every format.
//! Encode vs. decode is already clear from the function that returned the error,
//! so there is no need for separate sets.
//! Usage: `const Error = @import("../error.zig").Error;` then `return Error.InvalidHeader;`
pub const Error = error{
    // ── signature / structure ──
    UnexpectedSignature,
    InvalidHeader,
    InvalidChunkLen,
    MissingFormatChunk,
    MissingDataChunk,
    MissingFrame,

    // ── data / sizes ──
    UnexpectedEndOfData,
    InvalidDataLen,
    InvalidFrame,
    InvalidChannels,
    InvalidSampleRate,
    InvalidBitsPerSample,
    InvalidBlockAlign,
    InvalidBufferLen,
    InconsistentFrames,
    TooLarge,

    // ── unsupported features ──
    UnsupportedFormat,
    UnsupportedBitsPerSample,
    UnsupportedChannels,
    UnsupportedSampleRate,
    UnsupportedFeature,
};
