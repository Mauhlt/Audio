# Audio Loader

## Purpose
Audio library created in zig to read/write different audio file types.
This library will read/write sample data but not play it for you.
NEED TO SUPPLY YOUR OWN AUDIO OUTPUT FOR NOW.

## Formats
| Format | Read | Write | Notes |
|--------|------|-------|-------|
| WAV (`.wav`, `.wave`, `.rf64`) | yes | yes | PCM 8/16/24/32-bit, float 32/64, A-law/mu-law (read), WAVE_FORMAT_EXTENSIBLE, RF64 for > 4 GiB |
| QOA (`.qoa`) | yes | yes | "Quite OK Audio", the audio sibling of QOI. Lossy, 3.2 bits/sample, 16-bit. Output matches the reference encoder byte for byte |
| MP3 (`.mp3`, `.mp2`, `.mp1`) | yes | yes | Decode: MPEG-1/2/2.5 Layer III (and Layer I/II) to f32, skips ID3v2/ID3v1/APE tags, trims LAME gapless delay/padding. Encode: CBR Layer III at every MPEG sample rate, mono / joint stereo, gapless Info frame (see below) |

## Usage
`build.zig.zon` (a URL package pinned to a commit; `zig fetch --save=Audio
git+https://github.com/Mauhlt/Audio#<commit>` writes this entry and its hash):
```zig
.dependencies = .{
    .Audio = .{
        .url = "git+https://github.com/Mauhlt/Audio#<commit>",
        .hash = "<hash printed by zig fetch>",
    },
},
```
To build against a local checkout instead, without editing the manifest:
`zig build --fork=../Audio`.
`build.zig`:
```zig
exe.root_module.addImport("Audio", b.dependency("Audio", .{}).module("Audio"));
```
Code:
```zig
const Audio = @import("Audio");

const song = try Audio.read(.{ .io = io, .gpa = gpa, .filepath = "song.mp3" });
defer song.deinit(gpa);
// song.sample_rate, song.channels, song.samples (interleaved: frame i, channel c at i * channels + c)

const pcm16 = try song.convert(.i16, gpa); // u8, i16, i24, i32, f32, f64
defer pcm16.deinit(gpa);
try pcm16.write(io, gpa, "song.wav"); // format chosen from the extension
try pcm16.write(io, gpa, "song.qoa");
```
Lower level, the same three functions every codec exposes (like the Image library):
```zig
const inf = try Audio.info(.wav, bytes);            // headers only: rate, channels, frames, sample type
try Audio.decodeInto(.wav, arena, bytes, inf, out); // decode into your own buffer (inf.byteLen() bytes)
try audio.encode(.qoa, &writer, gpa);               // any std.Io.Writer
const any = try Audio.decodeAny(gpa, bytes);        // format sniffed from the first bytes
try Audio.MP3.encodeWith(&audio, &writer, gpa, .{ .bitrate_kbps = 192, .stereo = .auto });
```

### MP3 encoder
Constant bit rate (default 192 kbps stereo / 96 mono at 32-48 kHz), mid/side stereo chosen per
frame, a bit-rate dependent low-pass, and:
- **psychoacoustic model** (`psy.zig`): allowed noise per scale factor band from Bark-scale
  spreading, tonality, the threshold in quiet and pre-echo control; the quantizer's outer loop
  shapes the noise under it with scale factors, and saves bits once everything is masked
- **short blocks**: start / short / stop windows around attacks (one granule of look-ahead),
  measured to cut pre-echo by 12-19 dB 15-20 ms before a click
- **bit reservoir**: granules that need fewer bits leave them (up to 511 bytes) to later ones;
  perceptual entropy decides who gets more
Each can be switched off in `MP3.EncodeOptions` (`psy`, `short_blocks`, `reservoir`). The
filterbank is the exact transpose of the decoder's (derived from its synthesis window), and the
Huffman encode tables are derived from the decoder's tables at compile time. The first frame
is a LAME-style "Info" frame with the encoder delay and padding, so gapless decoders (this one,
dr_mp3/miniaudio) return exactly the input's length. Not done: VBR, intensity stereo, mixed
blocks, and LAME's finer-tuned psychoacoustics (it should still sound better on hard material).

## Layout
```
src/root.zig             Audio type (the data) + read/write/decode/encode
src/info.zig             Info (what a header tells you)
src/misc.zig             AudioTag, extension / magic detection, file reading
src/bench.zig            zig build bench
src/Samples/             core sample data: Samples + conversions, simd.zig kernels, misc.zig (vector width N)
src/Formats/error.zig    shared error set
src/Formats/wav/         wav.zig, header.zig (RIFF/RF64 chunks), g711.zig (A-law / mu-law)
src/Formats/qoa/         qoa.zig, header.zig, lms.zig, search.zig (vector encoder), scalar.zig (oracle)
src/Formats/mp3/         mp3.zig (tags, gapless, API)
                         decode: decoder.zig, header.zig, bits.zig, layer3.zig, layer12.zig, synth.zig
                         encode: encoder.zig, analysis.zig, psy.zig, quantize.zig, huffman.zig, bitwriter.zig
                         tables.zig (from minimp3), scalar.zig (oracle)
src/testdata.zig         test data generated at test time: tones / sweeps / seeded noise,
                         hand-packed WAV files, hand-built MP3 frames and tags
```

## Tests
```
zig build test           # Debug (bounds checked; includes a corrupt-file fuzz test)
zig build test-release   # ReleaseFast
zig build bench          # ReleaseFast timings; -Dvector-bytes=16/32/64 to try other widths
```
SIMD follows the Image library's structure; results are in `docs/simd-speedups.md`.
The library is pure Zig, and so is its test data: the repository ships no audio files. The
tests synthesise signals from a seeded PRNG, pack WAV files field by field (independently of
the WAV encoder), compare the QOA encoder with a whole-file oracle built on the scalar port of
the reference search, and build MP3 frames and tags by hand from the standard (they decode to
silence). Other MP3 decode tests run on streams from this library's own encoder. One test,
"MP3 - decode matches reference decoder", reports SKIPPED: it needs MP3s from an independent
encoder with an independent decoder's output, which the repository no longer carries (see
`THIRD_PARTY.md`).

One test is a compiler canary: "zig canary: vector @intCast i32 -> u8" reports SKIPPED while
Zig 0.18.0-dev.4's LLVM backend at -O0 miscompiles that cast (see `narrow` in
`Samples/samples.zig`, which works around it). After a Zig upgrade, check whether it passes.

## Licence
MIT (`LICENSE`). The MP3 decoder is a port of minimp3 (CC0) and the QOA code follows the
reference `qoa.h` (MIT): see `THIRD_PARTY.md`.

## Goals
1. Read Formats:
    - wav, qoa, mp3 - done
    - flac
    - aiff / aifc
    - ogg vorbis
    - opus
    - aac / m4a
2. Write Formats:
    - wav, qoa, mp3 - done
    - flac
    - mp3 encoder: VBR, intensity stereo, mixed blocks, finer psychoacoustics, speed (60x realtime)
3. Convert between formats/sample types - done for the formats above
4. Streaming decode (frame at a time) for long files
5. Resampling / channel remixing
6. Benchmark formats
    - file size
    - decode time
    - quality vs. the original
