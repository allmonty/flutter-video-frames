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
