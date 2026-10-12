## Unreleased

- The example app now picks a video, applies a filter to every frame,
  exports it with the original sound and plays it. CI runs on GitHub Actions.
  The README has install steps, a before/after image, a comparison with
  other options, and error-code and memory tables.
- macOS support (12+). iOS and macOS share one Swift implementation
  (`sharedDarwinSource`), which moved from `ios/` to `darwin/`.
- A writer whose `finish()` fails now frees the encoder and deletes the broken
  file (Android leaked the hardware encoder; both platforms left the file).
  An Android writer that fails while being created no longer leaks it either.
- Android: a stuck encoder now fails with "video encoder stalled" after 5
  seconds instead of hanging `addFrame` or `finish` forever.
- iOS: a frame whose pixel memory can't be read or allocated now returns an
  error to Dart instead of crashing the app.
- Readers and writers that are never closed are freed when garbage-collected
  (a forgotten writer is cancelled). iOS now frees everything when the
  Flutter engine shuts down, as Android already did.
- Faster frame conversion. Android now decodes and encodes through OpenGL ES
  (the GPU converts, rotates and scales), about 3x faster at 1080p on an
  emulator; iOS uses Accelerate (vImage) for full-size frames.
- Android: the first `frameAt` on a reader no longer sometimes fails with
  "video decoder stalled".
- Written videos are tagged BT.709 (both platforms). Players no longer guess
  the color space, which shifted greens and skin tones in HD output.
- `VideoReader.open(..., filter:)` chooses how `maxDimension` scales frames:
  `ScaleFilter.nearest` (default), `bilinear` or `area`. `frameAt` now scales
  exactly like `nextFrame` on iOS. Nearest sampling picks the pixel at each
  output pixel's center on both platforms (iOS used to pick its top-left).
- **Breaking:** the host API is split into `VideoReaderHostApi` and
  `VideoWriterHostApi`, each on its own native queue, so decoding can overlap
  encoding (see the pipelined loop in the README). The test seam
  `VideoFrames.api` is replaced by `VideoFrames.readerApi` and
  `VideoFrames.writerApi`.
- `VideoWriter.create(..., codec: VideoCodec.hevc)` writes HEVC; it fails
  with a clear error on devices without an HEVC encoder.
- HDR input: iOS `frameAt` now decodes with `AVAssetReader` like `nextFrame`,
  so HDR frames get the same tone mapping (the image generator path was
  darker and differently colored). Android 13+ asks decoders to tone-map
  HDR to SDR, plays Dolby Vision 8/9 (e.g. iPhone videos) through the HEVC/AVC
  base layer when there is no Dolby Vision decoder, and picks a decoder that
  supports the track's profile (e.g. 10-bit) instead of the default one.
- Less copying per frame: Android reads GPU pixels straight into one reused
  buffer per decoder instead of allocating a new array (plus a copy) per
  frame; iOS builds frames as `Data`, dropping a full-frame copy in the
  plugin. The README has a per-resolution memory table.
- Android: a decoder that fails mid-stream now reports which codec and video
  it was ("c2.x.hevc.decoder (video/hevc 640x360) can't decode this video")
  instead of only "Invalid to call at Released state".
- Android: the HDR-to-SDR tone-mapping request is only sent for HDR video.
  On SDR video it made Qualcomm decoders fail ("not a supported pixel
  format"), so videos the plugin itself wrote couldn't be read on those
  phones.
- Android: encoders and decoders are tried in the device's preference order
  until one starts, ending with Android's software codecs. Vendor codecs can
  claim a format and still fail to start (Qualcomm's H.264 encoder at 64x64
  and 256x64); those sizes now fall back instead of failing.
- **Breaking:** the generated host API and message types
  (`VideoReaderHostApi`, `VideoWriterHostApi`, `VideoFrameMessage`,
  `VideoInfoMessage`) moved from `package:video_frames/video_frames.dart` to
  `package:video_frames/testing.dart`, and `VideoFrames.readerApi` /
  `writerApi` are `@visibleForTesting`. Every public member is documented.
- **Breaking:** failures throw `VideoFramesException` with a
  `VideoFramesErrorCode` (`fileNotFound`, `unsupportedFormat`,
  `codecUnsupported`, `encoderStalled`, `readFailed`, `writeFailed`,
  `unknown`) instead of a raw `PlatformException`.

## 0.3.0

- Swift Package Manager support. The iOS sources moved to
  `ios/video_frames/Sources/video_frames/`, and CocoaPods still works.
- iOS 15 minimum, matching Flutter 3.47.
- Android build moves to AGP 9.1, Kotlin 2.4 and the
  `kotlin { compilerOptions }` DSL.

## 0.2.0

- `VideoInfo.audioCompatible` reports whether a video's audio can be copied
  into an MP4.
- `VideoWriter.includesAudio`: audio that can't be copied is now dropped,
  and the video is still written, instead of failing.

## 0.1.0

- `VideoReader`: sequential and random-access RGBA frames, with rotation
  applied and optional downscaling.
- `VideoWriter`: H.264 MP4 encoding from RGBA, with optional audio
  passthrough.
