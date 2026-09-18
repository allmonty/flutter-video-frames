import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_frames/video_frames.dart';

/// In-memory stand-in for the platform side.
class FakeHostApi extends VideoFramesHostApi {
  final calls = <String>[];
  final frames = <int, List<VideoFrameMessage>>{};
  final written = <int, List<(Uint8List, int)>>{};
  final writerSizes = <int, (int, int)>{};

  @override
  Future<VideoInfoMessage> openReader(int readerId, String path, int? maxDimension) async {
    calls.add('open $path $maxDimension');
    frames[readerId] = [
      for (var i = 0; i < 3; i++)
        VideoFrameMessage(ptsUs: i * 40000, width: 4, height: 2, rgba: Uint8List(32)..[0] = i),
    ];
    return VideoInfoMessage(
      width: 4,
      height: 2,
      durationUs: 120000,
      frameRate: 25,
      rotationDegrees: 90,
      hasAudio: true,
      audioCompatible: false,
    );
  }

  @override
  Future<VideoFrameMessage?> nextFrame(int readerId) async {
    final queue = frames[readerId]!;
    return queue.isEmpty ? null : queue.removeAt(0);
  }

  @override
  Future<VideoFrameMessage> frameAt(int readerId, int timeUs) async =>
      VideoFrameMessage(ptsUs: timeUs, width: 4, height: 2, rgba: Uint8List(32));

  @override
  Future<void> closeReader(int readerId) async => calls.add('close $readerId');

  @override
  Future<bool> openWriter(
    int writerId,
    String path,
    int width,
    int height,
    double frameRate,
    int? bitRate,
    String? audioSourcePath,
  ) async {
    calls.add('writer $path ${width}x$height $frameRate $bitRate $audioSourcePath');
    writerSizes[writerId] = (width, height);
    written[writerId] = [];
    // Pretend '.pcm' sources hold audio that can't go into an MP4.
    return audioSourcePath != null && !audioSourcePath.endsWith('.pcm');
  }

  @override
  Future<void> addFrame(int writerId, Uint8List rgba, int ptsUs) async {
    final (w, h) = writerSizes[writerId]!;
    if (rgba.length != w * h * 4) throw ArgumentError('bad frame');
    written[writerId]!.add((rgba, ptsUs));
  }

  @override
  Future<void> finishWriter(int writerId) async => calls.add('finish $writerId');

  @override
  Future<void> cancelWriter(int writerId) async => calls.add('cancel $writerId');
}

void main() {
  late FakeHostApi api;
  setUp(() => VideoFrames.api = api = FakeHostApi());

  group('VideoReader', () {
    test('open reports info', () async {
      final reader = await VideoReader.open('/v.mp4', maxDimension: 640);
      expect(api.calls.single, 'open /v.mp4 640');
      final info = reader.info;
      expect((info.width, info.height), (4, 2));
      expect(info.duration, const Duration(milliseconds: 120));
      expect(info.frameRate, 25);
      expect(info.rotationDegrees, 90);
      expect(info.hasAudio, isTrue);
      expect(info.audioCompatible, isFalse);
      expect(info.estimatedFrameCount, 3);
    });

    test('nextFrame walks frames in order, then returns null', () async {
      final reader = await VideoReader.open('/v.mp4');
      final pts = <Duration>[];
      VideoFrame? f;
      while ((f = await reader.nextFrame()) != null) {
        pts.add(f!.pts);
      }
      expect(pts, [
        Duration.zero,
        const Duration(milliseconds: 40),
        const Duration(milliseconds: 80),
      ]);
    });

    test('frameAt passes microseconds', () async {
      final reader = await VideoReader.open('/v.mp4');
      final f = await reader.frameAt(const Duration(milliseconds: 1500));
      expect(f.pts, const Duration(milliseconds: 1500));
      expect(f.rgba, hasLength(32));
    });

    test('close is idempotent and blocks further reads', () async {
      final reader = await VideoReader.open('/v.mp4');
      await reader.close();
      await reader.close();
      expect(api.calls.where((c) => c.startsWith('close')), hasLength(1));
      expect(reader.nextFrame, throwsStateError);
      expect(() => reader.frameAt(Duration.zero), throwsStateError);
    });

    test('readers get distinct ids', () async {
      final a = await VideoReader.open('/a.mp4');
      final b = await VideoReader.open('/b.mp4');
      await a.close();
      await b.close();
      final closes = api.calls.where((c) => c.startsWith('close')).toList();
      expect(closes.toSet(), hasLength(2));
    });
  });

  group('VideoWriter', () {
    test('rounds odd sizes down to even and crops frames to fit', () async {
      final writer = await VideoWriter.create('/o.mp4', width: 5, height: 3, frameRate: 30);
      expect((writer.width, writer.height), (4, 2));
      expect(api.calls.single, 'writer /o.mp4 4x2 30.0 null null');

      // A 5x3 frame whose pixel (x, y) has red = 10*y + x.
      final full = Uint8List(5 * 3 * 4);
      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 5; x++) {
          full[(y * 5 + x) * 4] = 10 * y + x;
        }
      }
      await writer.addFrame(full, const Duration(milliseconds: 33));
      final (bytes, pts) = api.written.values.single.single;
      expect(pts, 33000);
      expect(bytes, hasLength(4 * 2 * 4));
      expect([for (var i = 0; i < 8; i++) bytes[i * 4]], [0, 1, 2, 3, 10, 11, 12, 13]);
    });

    test('accepts frames already at the even size', () async {
      final writer = await VideoWriter.create('/o.mp4', width: 4, height: 2, frameRate: 30);
      await writer.addFrame(Uint8List(32), Duration.zero);
      expect(api.written.values.single, hasLength(1));
    });

    test('rejects frames of the wrong size', () async {
      final writer = await VideoWriter.create('/o.mp4', width: 4, height: 2, frameRate: 30);
      expect(() => writer.addFrame(Uint8List(10), Duration.zero), throwsArgumentError);
    });

    test('passes bit rate and audio source, and reports whether audio is kept', () async {
      final kept = await VideoWriter.create(
        '/o.mp4',
        width: 8,
        height: 8,
        frameRate: 24,
        bitRate: 500000,
        audioSourcePath: '/in.mov',
      );
      expect(api.calls.single, 'writer /o.mp4 8x8 24.0 500000 /in.mov');
      expect(kept.includesAudio, isTrue);
      final dropped = await VideoWriter.create(
        '/o.mp4',
        width: 8,
        height: 8,
        frameRate: 24,
        audioSourcePath: '/in.pcm',
      );
      expect(dropped.includesAudio, isFalse);
      final none = await VideoWriter.create('/o.mp4', width: 8, height: 8, frameRate: 24);
      expect(none.includesAudio, isFalse);
    });

    test('rejects videos smaller than 2x2', () {
      expect(
        () => VideoWriter.create('/o.mp4', width: 1, height: 9, frameRate: 30),
        throwsArgumentError,
      );
    });

    test('finish and cancel end the writer', () async {
      final a = await VideoWriter.create('/a.mp4', width: 4, height: 2, frameRate: 30);
      await a.finish();
      expect(() => a.addFrame(Uint8List(32), Duration.zero), throwsStateError);
      await a.cancel(); // no-op after finish
      final b = await VideoWriter.create('/b.mp4', width: 4, height: 2, frameRate: 30);
      await b.cancel();
      await b.cancel();
      expect(api.calls.where((c) => c.startsWith('cancel')), hasLength(1));
      expect(api.calls.where((c) => c.startsWith('finish')), hasLength(1));
    });
  });

  test('cropRgba keeps the top-left corner', () {
    final src = Uint8List.fromList(List.generate(3 * 2 * 4, (i) => i));
    expect(cropRgba(src, 3, 2, 1), [0, 1, 2, 3, 4, 5, 6, 7]);
  });
}
