/// Decode video frames to RGBA and encode RGBA frames to H.264 MP4 (with the
/// source's audio copied through), on Android and iOS.
///
/// Every call runs on a background queue on the platform side, and the API
/// also works from background isolates (initialize
/// `BackgroundIsolateBinaryMessenger` first).
library;

import 'dart:typed_data';

import 'src/messages.g.dart';

export 'src/messages.g.dart'
    show ScaleFilter, VideoFrameMessage, VideoInfoMessage, VideoReaderHostApi, VideoWriterHostApi;

/// Metadata of an opened video.
class VideoInfo {
  const VideoInfo({
    required this.width,
    required this.height,
    required this.duration,
    required this.frameRate,
    required this.rotationDegrees,
    required this.hasAudio,
    this.audioCompatible = false,
  });

  /// Size of the delivered frames (after rotation and any scaling).
  final int width;
  final int height;
  final Duration duration;
  final double frameRate;

  /// The file's rotation metadata; frames are already upright.
  final int rotationDegrees;
  final bool hasAudio;

  /// The audio can be copied into an MP4 unchanged. When [hasAudio] is true
  /// but this is false, [VideoWriter] drops the sound instead of failing.
  final bool audioCompatible;

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
  /// The platform decoding API; replace it with a fake in tests.
  static VideoReaderHostApi readerApi = VideoReaderHostApi();

  /// The platform encoding API (a separate queue from [readerApi], so
  /// decoding and encoding can overlap); replace it with a fake in tests.
  static VideoWriterHostApi writerApi = VideoWriterHostApi();
  static int _nextId = 1;

  static int _id() => _nextId++;
}

/// Reads frames from a video file. Always [close] it (e.g. in a `finally`):
/// it holds a hardware decoder until then.
class VideoReader {
  VideoReader._(this._id, this.info) {
    _finalizer.attach(this, _id, detach: this);
  }

  // A safety net for readers that are never closed; finalizers aren't
  // guaranteed to run, so it doesn't replace [close].
  static final _finalizer = Finalizer<int>((id) => VideoFrames.readerApi.closeReader(id).ignore());

  final int _id;
  final VideoInfo info;
  bool _closed = false;

  /// Open `path`. With `maxDimension`, frames are scaled down (keeping the
  /// aspect ratio) so neither edge exceeds it, using `filter`: the default
  /// [ScaleFilter.nearest] suits pixel art, [ScaleFilter.bilinear] small
  /// downscales and [ScaleFilter.area] large ones. Applies to [nextFrame]
  /// and [frameAt].
  static Future<VideoReader> open(
    String path, {
    int? maxDimension,
    ScaleFilter filter = ScaleFilter.nearest,
  }) async {
    final id = VideoFrames._id();
    final m = await VideoFrames.readerApi.openReader(id, path, maxDimension, filter);
    return VideoReader._(
      id,
      VideoInfo(
        width: m.width,
        height: m.height,
        duration: Duration(microseconds: m.durationUs),
        frameRate: m.frameRate,
        rotationDegrees: m.rotationDegrees,
        hasAudio: m.hasAudio,
        audioCompatible: m.audioCompatible,
      ),
    );
  }

  /// The next frame in presentation order, or null at the end.
  Future<VideoFrame?> nextFrame() async {
    _checkOpen();
    final m = await VideoFrames.readerApi.nextFrame(_id);
    return m == null ? null : _frame(m);
  }

  /// The frame closest to `time` (for scrubbing). Doesn't affect
  /// [nextFrame]'s position.
  Future<VideoFrame> frameAt(Duration time) async {
    _checkOpen();
    return _frame(await VideoFrames.readerApi.frameAt(_id, time.inMicroseconds));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _finalizer.detach(this);
    await VideoFrames.readerApi.closeReader(_id);
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

/// Encodes RGBA frames into an H.264 MP4. Always [finish] or [cancel] it: it
/// holds a hardware encoder until then.
class VideoWriter {
  VideoWriter._(
    this._id,
    this.width,
    this.height,
    this._requestedWidth,
    this._requestedHeight,
    this.includesAudio,
  ) {
    _finalizer.attach(this, _id, detach: this);
  }

  // A safety net for abandoned writers: the file is unfinished, so cancel
  // (delete) it. Finalizers aren't guaranteed to run.
  static final _finalizer = Finalizer<int>((id) => VideoFrames.writerApi.cancelWriter(id).ignore());

  final int _id;

  /// Encoded size: the requested size rounded down to even numbers (H.264
  /// needs even dimensions). Frames of the requested size are cropped.
  final int width;
  final int height;
  final int _requestedWidth;
  final int _requestedHeight;

  /// Whether the audio source's track is being copied. False when no audio
  /// source was given, it has no audio, or its format can't go into an MP4
  /// unchanged (the video is still written, silent).
  final bool includesAudio;
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
    final audio = await VideoFrames.writerApi.openWriter(
      id,
      path,
      w,
      h,
      frameRate,
      bitRate,
      audioSourcePath,
    );
    return VideoWriter._(id, w, h, width, height, audio);
  }

  /// Append a frame (RGBA, `width * height * 4` bytes, or the requested
  /// size before even-rounding) shown at `pts`.
  Future<void> addFrame(Uint8List rgba, Duration pts) {
    _checkOpen();
    return VideoFrames.writerApi.addFrame(_id, _fit(rgba), pts.inMicroseconds);
  }

  Future<void> finish() {
    _checkOpen();
    _done = true;
    _finalizer.detach(this);
    return VideoFrames.writerApi.finishWriter(_id);
  }

  /// Stop and delete the partial file.
  Future<void> cancel() async {
    if (_done) return;
    _done = true;
    _finalizer.detach(this);
    await VideoFrames.writerApi.cancelWriter(_id);
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
