# #6 Choosable scaling filter

**Problem.** Downscaling is nearest-neighbour only: right for pixel art, jagged for photos.

**API.**
- `pigeons/messages.dart`: `enum ScaleFilter { nearest, bilinear, area }`; add `ScaleFilter filter` to
  `openReader`. Regenerate; export `ScaleFilter` from `lib/video_frames.dart`.
- `VideoReader.open(path, {int? maxDimension, ScaleFilter filter = ScaleFilter.nearest})` — default keeps
  today's output. Doc: `bilinear` for small downscales, `area` for large ones (e.g. 4K→720p).
  Applies to both `nextFrame` and `frameAt`. No effect without `maxDimension`.

**Android (in #1's shader).** `nearest` → `GL_NEAREST`; `bilinear` → `GL_LINEAR`;
`area` → fragment shader averaging an N×N grid of `GL_LINEAR` taps over the output pixel's source
footprint, `N = min(8, ceil(ratio / 2))`.
`// shortcut: area is exact up to 16× downscale, beyond that it under-samples; add a pre-pass if needed.`

**iOS.** `PixelConversion.scale(src, filter, …)`, pure Swift on 32-bit pixels: precomputed index tables
(nearest), fixed-point 8-bit weights (bilinear), exact integer box average (area). Pipeline: scale at
pre-rotation size, then vImage rotate + permute (#1). `frameAt`: drop `generator.maximumSize`, draw the
full-size upright `CGImage` into a BGRA buffer, then run the same scale (rotation 0 — the generator
already applied it), so both paths filter identically.

**Tests.**
- `apple_check`: 4×4 checkerboard → 2×2: nearest picks pixels, area gives the exact average (127/128),
  bilinear lies between.
- Integration test: same checkerboard via a real video for each filter on Android/iOS (loose bounds,
  the codec is lossy).
- `test/video_frames_test.dart`: fake API receives the chosen filter.
