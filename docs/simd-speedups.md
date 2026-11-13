# SIMD speedups

`zig build bench`, ReleaseFast, median of 9 runs, i5-14400F (AVX2, so `N` = 32 bytes).
Signal: 10 s of stereo 44.1 kHz (encode/decode rows), or the LAME-encoded test files (MP3 rows).
Every vector path is bit-identical to the scalar code it replaced; the scalar code is kept as
the test oracle (`Formats/qoa/scalar.zig`, `Formats/mp3/scalar.zig`, `convertScalar` in
`Samples/samples.zig`), and "... matches the scalar oracle" tests compare them.

Layout follows the Image library: `Samples/misc.zig` holds the tuning width `N`
(`-Dvector-bytes`, default = the target's suggested vector length), `Samples/simd.zig` the
shared load/store and byte-layout kernels; widths that are only a performance choice are
derived from `N`, widths the algorithm dictates (QOA's 8 candidates per pass, MP3's 4-lane
synthesis window, 8 alias butterflies, 32 subbands) stay literal.

## Sample conversions (`Samples/`)

| Case | Before (ms) | After (ms) | Speedup |
|---|---:|---:|---:|
| convert f32 -> i16 | 1.29 | 0.39 | 3.3x |
| convert f32 -> i24 | 1.48 | 0.65 | 2.3x |
| convert i16 -> f32 | 0.90 | 0.66 | 1.4x |
| convert u8 -> f32 | 0.89 | 0.65 | 1.4x |
| convert f64 -> f32 | 0.94 | 0.70 | 1.3x |
| convert i32 -> i16 | 0.42 | 0.35 | 1.2x |
| convert i24 -> f32, i16 -> i24 | 0.80, 0.73 | 0.76, 0.73 | 1x (memory bound) |

Float -> int computes in f32 where that is exact (every type up to 24 bits), f64 otherwise.

## WAV

| Case | Before (ms) | After (ms) | Speedup |
|---|---:|---:|---:|
| encode 24-bit | 1.74 | 0.16 | 11x |
| decode 24-bit | 0.22 | 0.13 | 1.7x |
| 16-bit / float | already a copy | | 1x |

24-bit samples are packed / unpacked with one byte shuffle per vector (`simd.packI24Little`,
`simd.unpackI24Little`).

## QOA

| Case | Before (ms) | After (ms) | Speedup |
|---|---:|---:|---:|
| encode | 46.8 | 16.5 | 2.8x |
| decode | 3.93 | 3.89 | 1x |

The encoder's scale factor search runs candidates as vector lanes (`search.zig`): the 8 nearest
the previous scale factor to the end, the other 8 with an exact early exit, and stereo pairs of
channels side by side for instruction-level parallelism. The output is still byte-identical to
the reference encoder (qoa.h). Decoding is one serial dependency chain per channel; 4-lane
vectors were measured slower than scalar there, so it stays scalar.

## MP3 decode

| File | Before (ms) | After (ms) | Speedup |
|---|---:|---:|---:|
| Music128.mp3 | 1.50 | 1.25 | 1.2x |
| Music48k320.mp3 | 0.97 | 0.85 | 1.1x |
| MusicMono64.mp3 | 1.08 | 0.91 | 1.2x |

Vectorized: DCT-II (`N / 4` time slots per vector), the synthesis window (4 lanes, minimp3's SSE
order), IMDCT-36 (`N / 4` subbands per vector), alias reduction and mid/side. Per-stage time for
Music128: synthesis 0.43 -> 0.42 ms, IMDCT 0.17 -> 0.10 ms, alias reduction 0.019 -> 0.008 ms;
the rest (~0.55 ms) is Huffman / scale factor parsing, which is bit-serial.

## MP3 encode (new)

| Case | Time (ms) | Realtime |
|---|---:|---:|
| 10 s stereo, 128 kbps, all features (psychoacoustic model, short blocks, reservoir) | 166 | 60x |
| same, before the psychoacoustic model / short blocks / reservoir existed | 39.6 | 253x |

Written vector-first: polyphase analysis is a 64-wide window fold plus a 64 x 32 matrix applied as
32-lane vectors (one lane per subband), the long and short MDCTs work on slot-major 32-lane
vectors, and quantization (`|x|^(3/4)`, the per-band quantize) is `N / 4` wide. Most of the time
now goes to the noise-shaping outer loop (each iteration re-runs the global gain search with
scalar Huffman table selection and bit counting).

## Notes

- Zig 0.18.0-dev.4's LLVM backend at -O0 (Debug, the x86_64 default) miscompiles `@intCast` from
  `@Vector(n, i32)` to `@Vector(n, u8)`: lane reads and `@reduce` see 127 for lanes >= 128.
  The conversions narrow with `@truncate` on values already known to fit (`narrow` in
  `Samples/samples.zig`), and the "zig canary" test there reports SKIPPED while the bug exists:
  check it after upgrading Zig.
