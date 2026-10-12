# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this is

`video_frames`: a Flutter plugin (Android + iOS) that decodes video to upright RGBA frames and encodes RGBA frames to H.264 MP4, using only platform codecs (no FFmpeg, no dependencies beyond Flutter). See README.md for the API and per-platform implementation table.

Flutter is pinned with asdf in `.tool-versions` (3.47.x).

## Commands

```sh
flutter test                                   # Dart API tests against a fake host
flutter test --plain-name "<test name>"        # single Dart test
flutter analyze
dart format .                                  # 100-column width, set in analysis_options.yaml

dart run pigeon --input pigeons/messages.dart  # regenerate channel code after editing pigeons/messages.dart

# Kotlin unit tests (needs JDK 17–21, e.g. Android Studio's bundled one)
cd example/android && ./gradlew :video_frames:testDebugUnitTest

# Swift reader/writer against real AVFoundation on macOS, no device needed
tool/apple_check.sh

# Device/emulator round trip
cd example && flutter test integration_test
```

## Architecture

- **Channel layer is Pigeon-generated.** `pigeons/messages.dart` is the source of truth; it generates `lib/src/messages.g.dart`, `android/.../Messages.g.kt` and `ios/.../Messages.g.swift`. Never hand-edit `*.g.*` files.
- **Readers/writers are addressed by ids chosen on the Dart side** (`VideoFrames._id()` in `lib/video_frames.dart`). Native plugins keep `id → FrameReader/FrameWriter` maps. Every host call runs on a serial background queue, and the API works from a background isolate.
- **Two host APIs, two queues.** `VideoReaderHostApi` and `VideoWriterHostApi` are separate Pigeon APIs so decoding and encoding run on separate serial background queues.
- **Testing seam:** `VideoFrames.readerApi` / `VideoFrames.writerApi` are static, `@visibleForTesting` and swappable; the host API and message types they need are exported only from `lib/testing.dart`, so Pigeon regenerations don't change the public API. `test/video_frames_test.dart` replaces them with `FakeReaderApi` / `FakeWriterApi`.
- **Every public member in `lib/` needs a `///` doc comment** (`public_member_api_docs` is on; pub.dev scores it).
- **Native code is split so the core is Flutter-free.** On iOS, `PixelConversion.swift`, `FrameReader.swift` and `FrameWriter.swift` must not import Flutter: `tool/apple_check.sh` compiles them directly with `swiftc` together with `tool/apple_check/main.swift`. `VideoFramesPlugin.swift` is the only Flutter-aware glue. Android mirrors this (`FrameSize.kt`, `Codecs.kt`, `GlRenderer.kt`, `FrameReader.kt`, `FrameWriter.kt`, `AudioSupport.kt` + `VideoFramesPlugin.kt`). Android pixel work runs on the GPU (`GlRenderer`), so it is only exercised by `example/integration_test` on a device/emulator, not by JVM unit tests.
- **iOS supports both SwiftPM (`ios/video_frames/Package.swift`) and CocoaPods (`ios/video_frames.podspec`)**; sources live in `ios/video_frames/Sources/video_frames/`. Android follows the Flutter 3.47 template (AGP 9, JVM target via `kotlin { compilerOptions }`).

## Behaviors to preserve

- Rotation metadata is applied to decoded frames; reported `width`/`height` are post-rotation and post-scaling.
- `VideoWriter` rounds size down to even numbers (H.264 requirement) and crops frames given at the requested size.
- Audio is passthrough only (never re-encoded). If the source audio can't fit an MP4, the writer drops it and writes silent video rather than failing. `VideoInfo.audioCompatible` / `VideoWriter.includesAudio` expose this. Compatibility check: Android does a trial `MediaMuxer.addTrack` on a throwaway file; iOS uses `AVAssetWriter.canAdd`.
- `writer.cancel()` deletes the partial output file.
