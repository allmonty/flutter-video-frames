# video_frames example

A small app that does what the plugin is for: apply a filter to every frame
of a video.

1. **Pick video** opens the system file picker (`file_picker`).
2. Choose **Grayscale** or **Invert**: the first frame is shown before and
   after.
3. **Export** reads every frame, filters its RGBA bytes, and writes a new MP4
   with the original sound, showing progress. Decoding the next frame
   overlaps encoding the current one.
4. The result plays in the app (`video_player`).

The core loop, from [`lib/main.dart`](lib/main.dart):

```dart
final reader = await VideoReader.open(input, maxDimension: 1280, filter: ScaleFilter.area);
final writer = await VideoWriter.create(
  output,
  width: reader.info.width,
  height: reader.info.height,
  frameRate: reader.info.frameRate,
  audioSourcePath: reader.info.audioCompatible ? input : null,
);
var next = reader.nextFrame();
for (var frame = await next; frame != null; frame = await next) {
  next = reader.nextFrame();
  await writer.addFrame(filter.apply(frame.rgba), frame.pts);
}
await writer.finish();
await reader.close();
```

The filters are plain functions over RGBA bytes in
[`lib/filters.dart`](lib/filters.dart).

Run it with `flutter run` on Android, iOS or macOS. `integration_test/`
holds the plugin's device tests: `flutter test integration_test -d <device>`.
