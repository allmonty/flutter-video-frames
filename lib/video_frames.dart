/// Decode video frames to RGBA and encode RGBA frames to H.264 MP4 (with the
/// source's audio copied through), on Android and iOS.
///
/// Every call runs on a background queue on the platform side, and the API
/// also works from background isolates (initialize
/// `BackgroundIsolateBinaryMessenger` first).
library;

import 'dart:typed_data';

import 'src/messages.g.dart';

export 'src/messages.g.dart' show VideoFrameMessage, VideoFramesHostApi, VideoInfoMessage;

/// Metadata of an opened video.
class VideoInfo {
  const VideoInfo({
    required this.width,
    required this.height,
    required this.duration,
    required this.frameRate,
    required this.rotationDegrees,
    required this.hasAudio,
  });

  /// Size of the delivered frames (after rotation and any scaling).
  final int width;
  final int height;
  final Duration duration;
  final double frameRate;

  /// The file's rotation metadata; frames are already upright.
  final int rotationDegrees;
  final bool hasAudio;

  /// Approximate number of frames.
  int get estimatedFrameCount =>
      (duration.inMicroseconds * frameRate / Duration.microsecondsPerSecond).round();
}

/// One decoded frame: row-major RGBA, `width * height * 4` bytes.
class VideoFrame {
  const VideoFrame({
    required this.pts,
    required this.width,
    required this.height,
    required this.rgba,
  });

  final Duration pts;
  final int width;
  final int height;
  final Uint8List rgba;
}

/// Entry point: holds the host API (swappable in tests).
abstract final class VideoFrames {
  /// The platform API; replace it with a fake in tests.
  static VideoFramesHostApi api = VideoFramesHostApi();
  static int _nextId = 1;

  static int _id() => _nextId++;
}

/// Reads frames from a video file.
class VideoReader {
  VideoReader._(this._id, this.info);

  final int _id;
  final VideoInfo info;
  bool _closed = false;

  /// Open `path`. With `maxDimension`, frames are scaled down (keeping the
  /// aspect ratio) so neither edge exceeds it.
  static Future<VideoReader> open(String path, {int? maxDimension}) async {
    final id = VideoFrames._id();
    final m = await VideoFrames.api.openReader(id, path, maxDimension);
    return VideoReader._(
      id,
      VideoInfo(
        width: m.width,
        height: m.height,
        duration: Duration(microseconds: m.durationUs),
        frameRate: m.frameRate,
        rotationDegrees: m.rotationDegrees,
        hasAudio: m.hasAudio,
      ),
    );
  }

  /// The next frame in presentation order, or null at the end.
  Future<VideoFrame?> nextFrame() async {
    _checkOpen();
    final m = await VideoFrames.api.nextFrame(_id);
    return m == null ? null : _frame(m);
  }

  /// The frame closest to `time` (for scrubbing). Doesn't affect
  /// [nextFrame]'s position.
  Future<VideoFrame> frameAt(Duration time) async {
    _checkOpen();
    return _frame(await VideoFrames.api.frameAt(_id, time.inMicroseconds));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await VideoFrames.api.closeReader(_id);
  }

  void _checkOpen() {
    if (_closed) throw StateError('VideoReader is closed');
  }

  static VideoFrame _frame(VideoFrameMessage m) => VideoFrame(
    pts: Duration(microseconds: m.ptsUs),
    width: m.width,
    height: m.height,
    rgba: m.rgba,
  );
}

/// Encodes RGBA frames into an H.264 MP4.
class VideoWriter {
  VideoWriter._(this._id, this.width, this.height, this._requestedWidth, this._requestedHeight);

  final int _id;

  /// Encoded size: the requested size rounded down to even numbers (H.264
  /// needs even dimensions). Frames of the requested size are cropped.
  final int width;
  final int height;
  final int _requestedWidth;
  final int _requestedHeight;
  bool _done = false;

  /// Create `path` (overwritten if it exists). With `audioSourcePath`, that
  /// file's audio track is copied into the output when [finish] is called.
  static Future<VideoWriter> create(
    String path, {
    required int width,
    required int height,
    required double frameRate,
    int? bitRate,
    String? audioSourcePath,
  }) async {
    final w = width & ~1, h = height & ~1;
    if (w < 2 || h < 2) throw ArgumentError('video must be at least 2x2, got ${width}x$height');
    final id = VideoFrames._id();
    await VideoFrames.api.openWriter(id, path, w, h, frameRate, bitRate, audioSourcePath);
    return VideoWriter._(id, w, h, width, height);
  }

  /// Append a frame (RGBA, `width * height * 4` bytes, or the requested
  /// size before even-rounding) shown at `pts`.
  Future<void> addFrame(Uint8List rgba, Duration pts) {
    _checkOpen();
    return VideoFrames.api.addFrame(_id, _fit(rgba), pts.inMicroseconds);
  }

  Future<void> finish() {
    _checkOpen();
    _done = true;
    return VideoFrames.api.finishWriter(_id);
  }

  /// Stop and delete the partial file.
  Future<void> cancel() async {
    if (_done) return;
    _done = true;
    await VideoFrames.api.cancelWriter(_id);
  }

  Uint8List _fit(Uint8List rgba) {
    if (rgba.length == width * height * 4) return rgba;
    if (rgba.length != _requestedWidth * _requestedHeight * 4) {
      throw ArgumentError(
        'frame must be ${width}x$height or ${_requestedWidth}x$_requestedHeight RGBA, '
        'got ${rgba.length} bytes',
      );
    }
    return cropRgba(rgba, _requestedWidth, width, height);
  }

  void _checkOpen() {
    if (_done) throw StateError('VideoWriter is finished or cancelled');
  }
}

/// The top-left `width x height` of an RGBA image `srcWidth` pixels wide.
Uint8List cropRgba(Uint8List rgba, int srcWidth, int width, int height) {
  final out = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    out.setRange(y * width * 4, (y + 1) * width * 4, rgba, y * srcWidth * 4);
  }
  return out;
}
