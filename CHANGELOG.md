## Unreleased

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
