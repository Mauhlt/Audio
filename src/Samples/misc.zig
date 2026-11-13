const std = @import("std");

/// SIMD tuning width in bytes (u8 lanes): the target's suggested vector length, or the
/// `-Dvector-bytes` build option. Kernels whose width is only a performance choice
/// derive it from this; widths the algorithm dictates stay literal.
pub const N: usize = switch (@import("build_options").vector_bytes) {
    0 => std.simd.suggestVectorLength(u8) orelse 64,
    else => |n| n,
};
comptime {
    if (N < 16 or !std.math.isPowerOfTwo(N)) @compileError("vector width must be a power of two >= 16 bytes");
}

/// Lanes of `T` in one tuning-width vector (at least 4).
pub fn lanes(comptime T: type) comptime_int {
    return @max(4, N / @sizeOf(T));
}
