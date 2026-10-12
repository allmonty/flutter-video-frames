# video_frames

[![CI](https://github.com/allmonty/flutter-video-frames/actions/workflows/ci.yml/badge.svg)](https://github.com/allmonty/flutter-video-frames/actions/workflows/ci.yml)
[![pub package](https://img.shields.io/pub/v/video_frames.svg)](https://pub.dev/packages/video_frames)

A small Flutter plugin that takes a video apart into still pictures, and puts
pictures back together into a video.

**In plain terms:** a video is a fast series of photos. This package lets an
app open a video, get each photo (frame) out of it, change those photos
however it likes (filters, effects, drawing on them), and save the result as
a new video, keeping the original sound. It can also jump to a single moment,
for example to show a preview while the user drags a slider.

**Why it exists:** to apply filters to videos. It was built so an app could
run its own image filters on every frame of a video and export the filtered
result, without bundling a heavy video library like FFmpeg.

**Technically:** it decodes video files to RGBA frames and encodes RGBA frames
to H.264 or HEVC in an MP4, using the phone's own hardware/system codecs (no FFmpeg).

![A frame decoded by video_frames, then filtered to grayscale and inverted](https://raw.githubusercontent.com/allmonty/flutter-video-frames/main/doc/before_after.png)

*A frame read back from a video the plugin wrote, as is, in grayscale and
inverted: the two filters in the [example app](example/lib/main.dart).*

```sh
flutter pub add video_frames
```

## Platforms

| Platform | Supported | Minimum version |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) |
| iOS | ✅ | iOS 15 |
| macOS | ✅ | macOS 12 |
| Web, Windows, Linux | ❌ | — |

## Features

- **Read:** decode a video to upright RGBA frames, with rotation metadata
  applied and optional downscaling. Frames come one by one, or at a given
  time for scrubbing.
- **Write:** encode RGBA frames to H.264 or HEVC in an MP4, optionally copying
  another file's audio track through unchanged.

Every call runs on a background queue on the platform side. The API also
works from a background isolate, after calling
`BackgroundIsolateBinaryMessenger.ensureInitialized`, so a whole
decode → process → encode loop can run off the UI thread.

It has no dependencies beyond Flutter.

## Compared to other options

- **No FFmpeg.** It uses the codecs already on the device (MediaCodec,
  AVFoundation), so it adds almost nothing to the app's size and brings no
  GPL/LGPL licensing questions.
- **Read and write in one package,** at the level of individual RGBA frames,
  so any filter or effect written in Dart (or on the GPU, then read back)
  can be applied to every frame.
- **Audio is copied, not re-encoded,** so the sound keeps its quality and
  costs no processing time.
- **Not a player or an editor:** there's no timeline, trimming or
  transitions. For playback use `video_player`; for general transcoding,
  FFmpeg-based packages cover far more formats.

## Usage

```dart
final reader = await VideoReader.open(inputPath, maxDimension: 1280);
final writer = await VideoWriter.create(
  outputPath,
  width: reader.info.width,
  height: reader.info.height,
  frameRate: reader.info.frameRate,
  audioSourcePath: reader.info.hasAudio ? inputPath : null,
);
try {
  VideoFrame? frame;
  while ((frame = await reader.nextFrame()) != null) {
    await writer.addFrame(process(frame!.rgba), frame.pts);
  }
  await writer.finish();
} catch (_) {
  await writer.cancel();   // deletes the partial file
  rethrow;
} finally {
  await reader.close();
}

// Decoding and encoding run on separate native queues. To overlap them,
// request the next frame before awaiting the current one's encode:
//   var next = reader.nextFrame();
//   for (var f = await next; f != null; f = await next) {
//     next = reader.nextFrame();               // decode n+1 ...
//     await writer.addFrame(process(f.rgba), f.pts); // ... while encoding n
//   }

// Readers and writers hold hardware codecs, so always close them as above.
// A forgotten one is freed when it's garbage-collected, but that may be late.

// Scrubbing:
final still = await reader.frameAt(const Duration(seconds: 3));
```

Paths are file paths, not `content://` URIs. File pickers such as
`file_picker` and `image_picker` already return copied file paths.

`maxDimension` scales frames down; pick how with `filter`:
`ScaleFilter.nearest` (default, sharp, for pixel art), `ScaleFilter.bilinear`
(smooth for small downscales) or `ScaleFilter.area` (averages every covered
pixel, best for large downscales like 4K to 720p):

```dart
final reader = await VideoReader.open(path, maxDimension: 720, filter: ScaleFilter.area);
```

## Errors

Failures throw a `VideoFramesException` whose `code` says what happened:

| `VideoFramesErrorCode` | When |
|---|---|
| `fileNotFound` | The input path doesn't exist. |
| `unsupportedFormat` | The file isn't a video the platform can open. |
| `codecUnsupported` | No codec on the device can handle it, e.g. HEVC without an HEVC encoder. Fall back to H.264. |
| `encoderStalled` | The encoder stopped producing output or accepting frames. |
| `readFailed` | Decoding failed partway. |
| `writeFailed` | Encoding or writing the file failed. |
| `unknown` | Anything else. |

```dart
try {
  writer = await VideoWriter.create(path, width: w, height: h, frameRate: 30, codec: VideoCodec.hevc);
} on VideoFramesException catch (e) {
  if (e.code != VideoFramesErrorCode.codecUnsupported) rethrow;
  writer = await VideoWriter.create(path, width: w, height: h, frameRate: 30);
}
```

## Memory

Every frame is uncompressed RGBA, and it is copied a few times on its way
between the platform and Dart:

| Frame size | One frame |
|---|---|
| 720p | 3.7 MB |
| 1080p | 8.3 MB |
| 4K | 33 MB |

For editing, open readers with `maxDimension: 1920` (or smaller) unless you
target high-end devices; 4K frames can run mid-range Android phones out of
memory.

## Audio

`audioSourcePath` copies the source's audio track into the MP4 unchanged;
nothing is re-encoded. Not every audio format fits an MP4:

- `VideoInfo.audioCompatible` says whether a video's audio can be copied.
  Check it after opening, so you can tell the user before exporting.
- `VideoWriter.includesAudio` says whether the writer is actually copying
  the audio.
- When the audio doesn't fit, the writer drops it and still writes the
  video, silent, instead of failing.

What counts as compatible depends on the platform:

- **Android:** `MediaMuxer` is asked directly, with a trial `addTrack` on a
  throwaway file. AAC always works; the accepted codecs vary by Android
  version.
- **iOS:** `AVAssetWriter.canAdd` is asked. AVFoundation is permissive and
  accepts AAC and even PCM. PCM-in-MP4 plays on Apple devices but may not
  play everywhere else.

H.264 and HEVC need even dimensions. `VideoWriter` rounds the size down to even
numbers (`writer.width` and `writer.height`) and crops frames given at the
requested size.

## Colors

Written videos are tagged as BT.709 SDR, the standard for HD, so players
don't have to guess. When reading, iOS converts with the video's own color
tags. On Android the GPU driver is expected to apply them; the Android
emulator's doesn't, so colors read there can be slightly off.

HDR input (HLG or PQ, like iPhone videos) is converted to SDR when read: iOS
uses AVFoundation's tone mapping; Android 13+ asks the decoder to tone-map
(below Android 13 HDR frames look washed out). Android plays iPhones' Dolby
Vision videos through their HEVC base layer when the device has no Dolby
Vision decoder.

`codec: VideoCodec.hevc` writes HEVC instead of H.264: about half the file
size at the same quality, but writer creation fails on devices without an
HEVC encoder (`VideoFramesErrorCode.codecUnsupported`), so fall back to
H.264 then.

## How it works

| | Android (minSdk 24) | iOS 15+ and macOS 12+ (shared code) |
|---|---|---|
| Decode | `MediaExtractor` + `MediaCodec` into a `SurfaceTexture`; OpenGL ES converts, rotates and scales, then reads back RGBA | `AVAssetReader` (BGRA); rotated and converted with Accelerate (vImage) |
| Seek (`frameAt`) | A second decoder: seek to the previous sync frame, then decode forward | A short-lived `AVAssetReader` from the requested time, so frames convert exactly like sequential ones |
| Encode | RGBA drawn with OpenGL ES into a `MediaCodec` H.264/HEVC encoder's input surface (the first encoder that starts, hardware first), explicit timestamps, `MediaMuxer` | `AVAssetWriter` + pixel-buffer adaptor, converted with vImage |
| Audio | Samples copied through `MediaExtractor` → `MediaMuxer` | Passthrough `AVAssetReaderTrackOutput` → `AVAssetWriterInput` |

On iOS and macOS the plugin shares one Swift implementation, with both Swift Package Manager (`darwin/video_frames/Package.swift`) and CocoaPods (`darwin/video_frames.podspec`). The sources are in `darwin/video_frames/Sources/video_frames/`. On Android it follows Flutter 3.47's plugin template: AGP 9, with the JVM target set through `kotlin { compilerOptions }`.

The channel API is generated by Pigeon. To regenerate it:

```sh
dart run pigeon --input pigeons/messages.dart
```

## Tests

- `flutter test`: tests the Dart API against a fake host.
- Kotlin unit tests (frame size, rotation mapping), from `example/android`:
  `./gradlew :video_frames:testDebugUnitTest`. This needs a JDK 17–21,
  such as Android Studio's bundled one.
- `tool/apple_check.sh`: runs the Swift reader and writer against real
  AVFoundation on macOS. It checks encoding, decoding, seeking, scaling,
  rotation, cancelling and audio passthrough, with no device needed.
- `example/integration_test`: the device tests, on an Android device or
  emulator, an iOS device or simulator, or this Mac:
  `cd example && flutter test integration_test -d <device>` (`-d macos`
  runs them natively on macOS).
