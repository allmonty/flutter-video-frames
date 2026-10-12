# #5 HD color correctness

**Problem.** Android decoding uses BT.601 math on HD video (usually BT.709); neither platform tags the
encoded output's color space, so players guess.

**Change.**
- Android read: solved by #1 — the external-texture sampler converts with the stream's own color aspects.
- Android write: in `FrameWriter` set `KEY_COLOR_STANDARD = COLOR_STANDARD_BT709`,
  `KEY_COLOR_RANGE = COLOR_RANGE_LIMITED`, `KEY_COLOR_TRANSFER = COLOR_TRANSFER_SDR_VIDEO` (API 24+).
- iOS write: add `AVVideoColorPropertiesKey` (primaries, transfer, matrix = `ITU_R_709_2`) to the video
  input's output settings.
- iOS read: no change (already correct).

**Test.** Integration test: encode flat red/green/blue/skin-tone patches, decode, assert each channel is
within ±12 of the input — a 601/709 mismatch shifts green by ~20+. `apple_check`: read back the written
track's format description and assert the 709 matrix extension.

**Risk.** Some Android encoders ignore the requested standard; the round-trip test is what catches it.
