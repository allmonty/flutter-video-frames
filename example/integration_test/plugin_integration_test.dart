// Round trip on a real device or emulator:
//   flutter test integration_test/plugin_integration_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_frames/video_frames.dart';

/// A frame split into four flat quadrants whose colors shift with `i`.
Uint8List syntheticFrame(int width, int height, int i) {
  final out = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final q = (y < height ~/ 2 ? 0 : 2) + (x < width ~/ 2 ? 0 : 1);
      final o = (y * width + x) * 4;
      out[o] = q == 0 ? 220 : (i * 8) % 256;
      out[o + 1] = q == 1 ? 220 : 40;
      out[o + 2] = q == 2 ? 220 : 40;
      out[o + 3] = 255;
    }
  }
  return out;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('encode 30 frames, then decode them back', (tester) async {
    const width = 320, height = 240, frames = 30;
    final path = '${Directory.systemTemp.path}/video_frames_roundtrip.mp4';

    final writer = await VideoWriter.create(path, width: width, height: height, frameRate: 30);
    for (var i = 0; i < frames; i++) {
      await writer.addFrame(syntheticFrame(width, height, i), Duration(microseconds: i * 33333));
    }
    await writer.finish();
    expect(File(path).lengthSync(), greaterThan(1000));

    final reader = await VideoReader.open(path);
    expect(reader.info.width, width);
    expect(reader.info.height, height);
    expect(reader.info.hasAudio, isFalse);

    var count = 0;
    VideoFrame? first;
    while (true) {
      final frame = await reader.nextFrame();
      if (frame == null) break;
      first ??= frame;
      count++;
    }
    expect(count, frames);
    // Top-left quadrant is red-ish (lossy codec, so loose bounds).
    final px = first!.rgba;
    final o = ((height ~/ 4) * width + width ~/ 4) * 4;
    expect(px[o], greaterThan(170));
    expect(px[o + 1], lessThan(100));

    final middle = await reader.frameAt(const Duration(milliseconds: 500));
    expect(middle.width, width);
    expect(middle.pts.inMilliseconds, closeTo(500, 40));

    final scaled = await VideoReader.open(path, maxDimension: 160);
    expect((scaled.info.width, scaled.info.height), (160, 120));
    await scaled.close();
    await reader.close();
  });

  testWidgets('cancel deletes the partial file', (tester) async {
    final path = '${Directory.systemTemp.path}/video_frames_cancel.mp4';
    final writer = await VideoWriter.create(path, width: 64, height: 64, frameRate: 30);
    await writer.addFrame(syntheticFrame(64, 64, 0), Duration.zero);
    await writer.cancel();
    expect(File(path).existsSync(), isFalse);
  });
}
