// Round trip on a real device or emulator:
//   flutter test integration_test/plugin_integration_test.dart
import 'dart:io';

import 'package:flutter/services.dart';
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

/// Asserts the pixel at (x, y) is within `tolerance` of `rgb` per channel
/// (lossy codec).
void expectPixel(
  VideoFrame f,
  int x,
  int y,
  (int, int, int) rgb,
  String where, [
  int tolerance = 40,
]) {
  final o = (y * f.width + x) * 4;
  final (r, g, b) = rgb;
  final got = (f.rgba[o], f.rgba[o + 1], f.rgba[o + 2]);
  expect(
    (got.$1 - r).abs() <= tolerance &&
        (got.$2 - g).abs() <= tolerance &&
        (got.$3 - b).abs() <= tolerance,
    isTrue,
    reason: '$where: expected $rgb, got $got',
  );
}

/// The quadrant colors of the rotated fixture once upright (64x128).
void expectUprightQuadrants(VideoFrame f) {
  final (w, h) = (f.width, f.height);
  expectPixel(f, w ~/ 4, h ~/ 4, (40, 40, 220), 'top-left blue');
  expectPixel(f, w * 3 ~/ 4, h ~/ 4, (220, 40, 40), 'top-right red');
  expectPixel(f, w ~/ 4, h * 3 ~/ 4, (220, 220, 220), 'bottom-left white');
  expectPixel(f, w * 3 ~/ 4, h * 3 ~/ 4, (40, 220, 40), 'bottom-right green');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('applies rotation metadata, scaled or not', (tester) async {
    // 128x64, tagged 90°; see tool/make_fixtures.swift.
    final data = await rootBundle.load('integration_test/assets/rotated90.mp4');
    final path = '${Directory.systemTemp.path}/video_frames_rotated90.mp4';
    File(path).writeAsBytesSync(data.buffer.asUint8List());

    final reader = await VideoReader.open(path);
    expect(reader.info.rotationDegrees, 90);
    expect((reader.info.width, reader.info.height), (64, 128));
    expectUprightQuadrants((await reader.nextFrame())!);
    // Scrub forward, back and forward again on the same reader.
    for (final ms in [200, 33, 400, 100]) {
      final f = await reader.frameAt(Duration(milliseconds: ms));
      expect(f.pts.inMilliseconds, closeTo(ms, 34));
      expectUprightQuadrants(f);
    }
    await reader.close();

    final scaled = await VideoReader.open(path, maxDimension: 64);
    expect((scaled.info.width, scaled.info.height), (32, 64));
    expectUprightQuadrants((await scaled.nextFrame())!);
    await scaled.close();
  });

  testWidgets('HD colors match a BT.709 reference after a round trip', (tester) async {
    // The same four colors as colors709.mp4 (made by AVFoundation, tagged
    // BT.709). Comparing against how this device decodes that file isolates
    // our encoder: the Android emulator's GPU ignores color tags when decoding,
    // so absolute colors are off there, but a 601/709 mix-up in the encoder
    // still shows as a difference (green moves by 20+).
    const colors = [(40, 200, 60), (224, 172, 140), (200, 40, 40), (40, 60, 200)];
    const width = 1280, height = 720;
    final frame = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final (r, g, b) = colors[(y < height ~/ 2 ? 0 : 2) + (x < width ~/ 2 ? 0 : 1)];
        final o = (y * width + x) * 4;
        frame
          ..[o] = r
          ..[o + 1] = g
          ..[o + 2] = b
          ..[o + 3] = 255;
      }
    }
    final path = '${Directory.systemTemp.path}/video_frames_colors.mp4';
    final writer = await VideoWriter.create(path, width: width, height: height, frameRate: 30);
    for (var i = 0; i < 5; i++) {
      await writer.addFrame(frame, Duration(microseconds: i * 33333));
    }
    await writer.finish();

    final data = await rootBundle.load('integration_test/assets/colors709.mp4');
    final refPath = '${Directory.systemTemp.path}/video_frames_colors709.mp4';
    File(refPath).writeAsBytesSync(data.buffer.asUint8List());

    Future<VideoFrame> firstFrame(String p) async {
      final reader = await VideoReader.open(p);
      final f = (await reader.nextFrame())!;
      await reader.close();
      return f;
    }

    final ours = await firstFrame(path);
    final reference = await firstFrame(refPath);
    for (var q = 0; q < 4; q++) {
      final x = q.isEven ? width ~/ 4 : width * 3 ~/ 4;
      final y = q < 2 ? height ~/ 4 : height * 3 ~/ 4;
      final o = (y * width + x) * 4;
      final (r, g, b) = (reference.rgba[o], reference.rgba[o + 1], reference.rgba[o + 2]);
      expectPixel(ours, x, y, (r, g, b), 'color ${colors[q]} vs reference ($r, $g, $b)', 8);
    }
  });

  testWidgets('1080p speed (logged, not asserted)', (tester) async {
    const width = 1920, height = 1080, frames = 60;
    final path = '${Directory.systemTemp.path}/video_frames_1080p.mp4';
    final input = [for (var i = 0; i < 4; i++) syntheticFrame(width, height, i)];

    final encode = Stopwatch()..start();
    final writer = await VideoWriter.create(path, width: width, height: height, frameRate: 30);
    for (var i = 0; i < frames; i++) {
      await writer.addFrame(input[i % 4], Duration(microseconds: i * 33333));
    }
    await writer.finish();
    encode.stop();

    final decode = Stopwatch()..start();
    final reader = await VideoReader.open(path);
    var count = 0;
    while (await reader.nextFrame() != null) {
      count++;
    }
    decode.stop();
    await reader.close();
    expect(count, frames);
    // ignore: avoid_print
    print(
      '1080p: encode ${encode.elapsedMilliseconds ~/ frames} ms/frame, '
      'decode ${decode.elapsedMilliseconds ~/ frames} ms/frame',
    );
  });

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
