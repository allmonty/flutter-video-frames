# #7 HDR input and HEVC output

**Problem.** iPhone HDR (10-bit HLG/Dolby Vision) input decodes washed out or fails; output is always
H.264, large at 4K.

**HDR input → SDR.**
- Android: on API 33+, set `KEY_COLOR_TRANSFER_REQUEST = COLOR_TRANSFER_SDR_VIDEO` in the decoder config
  so it tone-maps. Below 33:
  `// shortcut: HDR input looks washed out below API 33; tone-map in the shader if users hit it.`
- iOS: add `AVVideoColorPropertiesKey` (709) to the `AVAssetReaderTrackOutput` settings so AVFoundation
  converts to SDR. If the track output rejects it, switch to `AVAssetReaderVideoCompositionOutput` with
  709 color properties. Verify on a real iPhone HDR clip.

**HEVC output.**
- Pigeon `enum VideoCodec { h264, hevc }`; `VideoWriter.create(..., VideoCodec codec = VideoCodec.h264)`.
- Android: `MIMETYPE_VIDEO_HEVC`; if `MediaCodecList(REGULAR_CODECS).findEncoderForFormat` is null, throw
  a clear "HEVC encoding not supported on this device".
- iOS: `AVVideoCodecType.hevc`; check `writer.canApply(outputSettings:forMediaType:)`, throw the same error
  (A9 devices lack an HEVC encoder).
- README/description: "H.264 or HEVC".

**Skipped.** 10-bit/HDR *output*, and a `VideoInfo.isHdr` flag.

**Tests.** `apple_check`: HEVC round trip on macOS. Integration test: HEVC round trip, skipped when the
device throws "not supported". HDR fixture needs a real device clip; manual check.
