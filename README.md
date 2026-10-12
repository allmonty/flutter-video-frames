# video_frames

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

## Platforms

| Platform | Supported | Minimum version |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) |
| iOS | ✅ | iOS 15 |
| Web, macOS, Windows, Linux | ❌ | — |

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

It has no dependencies beyond Flutter and was written to be reusable outside
Bitmapper.

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

`maxDimension` scales frames down; pick how with `filter`:
`ScaleFilter.nearest` (default, sharp, for pixel art), `ScaleFilter.bilinear`
(smooth for small downscales) or `ScaleFilter.area` (averages every covered
pixel, best for large downscales like 4K to 720p):

```dart
final reader = await VideoReader.open(path, maxDimension: 720, filter: ScaleFilter.area);
```

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
HEVC encoder, so fall back to H.264 when it throws.

## How it works

| | Android (minSdk 24) | iOS (15+) |
|---|---|---|
| Decode | `MediaExtractor` + `MediaCodec` into a `SurfaceTexture`; OpenGL ES converts, rotates and scales, then reads back RGBA | `AVAssetReader` (BGRA); rotated and converted with Accelerate (vImage) |
| Seek (`frameAt`) | A second decoder: seek to the previous sync frame, then decode forward | `AVAssetImageGenerator` with zero tolerance |
| Encode | RGBA drawn with OpenGL ES into the `MediaCodec` AVC input surface, explicit timestamps, `MediaMuxer` | `AVAssetWriter` + pixel-buffer adaptor, converted with vImage |
| Audio | Samples copied through `MediaExtractor` → `MediaMuxer` | Passthrough `AVAssetReaderTrackOutput` → `AVAssetWriterInput` |

On iOS the plugin supports both Swift Package Manager (`ios/video_frames/Package.swift`) and CocoaPods (`ios/video_frames.podspec`). The sources are in `ios/video_frames/Sources/video_frames/`. On Android it follows Flutter 3.47's plugin template: AGP 9, with the JVM target set through `kotlin { compilerOptions }`.

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
- `example/integration_test`: a round trip on a device or emulator:
  `cd example && flutter test integration_test`.
