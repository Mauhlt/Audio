# Third-party material

The library is MIT licensed (see `LICENSE`). The parts below come from, or are ported from,
other projects and keep their own terms; they are not relicensed.

## minimp3 (MP3 decoder)

- Source: minimp3 by lieff, https://github.com/lieff/minimp3 (as bundled in dr_mp3)
- Licence: CC0 1.0 Universal (public domain dedication)
- Used in: `src/Formats/mp3/decoder.zig`, `layer3.zig`, `layer12.zig`, `synth.zig`, `bits.zig`
  and `scalar.zig` are a Zig port of its decoder; `tables.zig` holds its lookup tables,
  extracted verbatim. The encoder's Huffman tables are derived from those decode tables at
  compile time.

## dr_mp3 (miniaudio)

- Source: dr_mp3 by David Reid, https://github.com/mackron/dr_libs (also part of miniaudio)
- Licence: public domain (Unlicense) or MIT No Attribution, at the user's choice
- Used in: `tables.zig` was extracted from the copy of minimp3 that dr_mp3 bundles. dr_mp3 also
  decoded the reference files `src/Data/Read/*.mp3.wav` (output data, no code).

## QOA reference (qoa.h)

- Source: qoa.h by Dominic Szablewski, https://github.com/phoboslab/qoa (https://qoaformat.org)
- Licence: MIT
- Used in: `src/Formats/qoa/lms.zig` (the LMS predictor; `dequant_tab` holds the rows of
  `qoa_dequant_tab`), `src/Formats/qoa/scalar.zig` (a line-by-line port of the reference
  `qoa_encode_frame` search, the test oracle) and `search.zig` (picks exactly the slices the
  reference picks), so the encoder's output is byte-identical to the reference.
  `src/Data/Read/Tone.qoa` was written by the reference encoder and `Tone.qoa.wav` is its decode.

```
Copyright (c) 2023, Dominic Szablewski - https://phoboslab.org

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Test data

- `src/Data/Read/Music*.mp3` were encoded with LAME; LAME itself contributes no code here.
- The WAV reference files were written with Python's `wave` module or packed by hand.
- Standards followed (no code taken): ISO/IEC 11172-3 and 13818-3 (MPEG audio), ITU-T G.711
  (A-law / mu-law), Microsoft RIFF WAVE and EBU RF64.
