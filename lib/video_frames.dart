/// Decode video frames to RGBA and encode RGBA frames to H.264 or HEVC MP4 (with
/// audio copied from a file or encoded from PCM), and join clips, on Android, iOS and macOS.
///
/// Every call runs on a background queue on the platform side, and the API
/// also works from background isolates (initialize
/// `BackgroundIsolateBinaryMessenger` first).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;

import 'src/messages.g.dart';

export 'src/messages.g.dart' show ScaleFilter, VideoCodec;

/// Why a [VideoFramesException] happened.
enum VideoFramesErrorCode {
  /// The input path doesn't exist.
  fileNotFound,

  /// The file exists but isn't a video the platform can open (no video
  /// track, or a container it can't read).
  unsupportedFormat,

  /// No codec on this device can decode or encode it (e.g. HEVC on a device
  /// without an HEVC encoder, or a size the encoders refuse).
  codecUnsupported,

  /// The encoder stopped producing output (Android).
  encoderStalled,

  /// Decoding failed partway (including a decoder that stalled).
  readFailed,

  /// Encoding or writing the file failed.
  writeFailed,

  /// A failure the plugin didn't classify.
  unknown,
}

/// A failure from the platform side of a [VideoReader] or [VideoWriter].
class VideoFramesException implements Exception {
  /// A failure with its [code] and the platform's [message].
  const VideoFramesException(this.code, this.message);

  /// What kind of failure it was.
  final VideoFramesErrorCode code;

  /// The platform's description, for logs.
  final String message;

  @override
  String toString() => 'VideoFramesException(${code.name}): $message';
}

/// Run a host call, turning the platform's errors into [VideoFramesException].
Future<T> _guard<T>(Future<T> call) async {
  try {
    return await call;
  } on PlatformException catch (e) {
    final code = VideoFramesErrorCode.values.asNameMap()[e.code] ?? VideoFramesErrorCode.unknown;
    throw VideoFramesException(code, e.message ?? e.code);
  }
}

/// Metadata of an opened video.
class VideoInfo {
  /// Metadata as reported by [VideoReader.open].
  const VideoInfo({
    required this.width,
    required this.height,
    required this.duration,
    required this.frameRate,
    required this.rotationDegrees,
    required this.hasAudio,
    this.audioCompatible = false,
  });

  /// Width of the delivered frames (after rotation and any scaling).
  final int width;

  /// Height of the delivered frames (after rotation and any scaling).
  final int height;

  /// Length of the video track.
  final Duration duration;

  /// Nominal frames per second (30 when the file doesn't say).
  final double frameRate;

  /// The file's rotation metadata; frames are already upright.
  final int rotationDegrees;

  /// Whether the file has an audio track.
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
  /// A frame shown at `pts`.
  const VideoFrame({
    required this.pts,
    required this.width,
    required this.height,
    required this.rgba,
  });

  /// Presentation time: when the frame is shown.
  final Duration pts;

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Row-major RGBA pixels, `width * height * 4` bytes, opaque alpha.
  final Uint8List rgba;
}

/// Raw sound: 16-bit signed PCM samples, channels interleaved.
class PcmAudio {
  /// `samples` at `sampleRate` Hz, `channels` interleaved (1 mono, 2 stereo).
  PcmAudio(this.samples, {required this.sampleRate, required this.channels}) {
    if (sampleRate <= 0 || channels <= 0) {
      throw ArgumentError('sound needs a sample rate and channels, got $sampleRate Hz, $channels');
    }
  }

  /// The samples, `channels` per frame.
  final Int16List samples;

  /// Frames per second.
  final int sampleRate;

  /// Samples per frame.
  final int channels;

  /// How long it plays.
  Duration get duration => Duration(
    microseconds: samples.length ~/ channels * Duration.microsecondsPerSecond ~/ sampleRate,
  );

  PcmAudioMessage _message() => PcmAudioMessage(
    pcm: samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes),
    sampleRate: sampleRate,
    channels: channels,
  );
}

/// Entry point: holds the host API (swappable in tests).
abstract final class VideoFrames {
  /// The platform decoding API; replace it with a fake in tests (see
  /// `package:video_frames/testing.dart`).
  @visibleForTesting
  static VideoReaderHostApi readerApi = VideoReaderHostApi();

  /// The platform encoding API (a separate queue from [readerApi], so
  /// decoding and encoding can overlap); replace it with a fake in tests.
  @visibleForTesting
  static VideoWriterHostApi writerApi = VideoWriterHostApi();

  /// The platform's whole-file API (sound and joining, on its own queue); replace it with a fake in tests.
  @visibleForTesting
  static MediaHostApi mediaApi = MediaHostApi();
  static int _nextId = 1;

  /// The first audio track of the file at `path`, decoded to 16-bit PCM at its own rate and channels, or null when
  /// it has no sound. Works for videos and for audio files (m4a, mp3, wav…).
  static Future<PcmAudio?> decodeAudio(String path) async {
    final m = await _guard(mediaApi.decodeAudio(path));
    if (m == null) return null;
    final bytes = m.pcm;
    final samples = bytes.offsetInBytes.isEven
        ? bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 2)
        : Int16List.sublistView(Uint8List.fromList(bytes));
    return PcmAudio(samples, sampleRate: m.sampleRate, channels: m.channels);
  }

  /// Join MP4s of the same format (size, codec, sound) one after another into `output`, without re-encoding:
  /// e.g. clips made by [VideoWriter] with the same settings. `output` (overwritten) can't be one of the inputs.
  static Future<void> concat(List<String> inputs, String output) {
    if (inputs.isEmpty) throw ArgumentError('nothing to join');
    // The output is opened first, so joining into one of the inputs would wipe it before it's read.
    if (File(output).existsSync() &&
        inputs.any((i) => File(i).existsSync() && FileSystemEntity.identicalSync(i, output))) {
      throw ArgumentError('output is one of the inputs: $output');
    }
    return _guard(mediaApi.concat(inputs, output));
  }

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

  /// The video's size, length, frame rate, rotation and audio.
  final VideoInfo info;
  bool _closed = false;

  /// Open the video file at `path`: a file path, not a `content://` or
  /// `file://` URI (pickers such as `file_picker` return copied file paths).
  /// With `maxDimension`, frames are scaled down (keeping the
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
    final m = await _guard(VideoFrames.readerApi.openReader(id, path, maxDimension, filter));
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
    final m = await _guard(VideoFrames.readerApi.nextFrame(_id));
    return m == null ? null : _frame(m);
  }

  /// The frame closest to `time` (for scrubbing). Doesn't affect
  /// [nextFrame]'s position.
  Future<VideoFrame> frameAt(Duration time) async {
    _checkOpen();
    return _frame(await _guard(VideoFrames.readerApi.frameAt(_id, time.inMicroseconds)));
  }

  /// Move [nextFrame]'s position: the next call returns the first frame at
  /// or after `time` (null when `time` is past the end), and the frames
  /// after it in order. Decoding restarts at the previous sync frame and the
  /// frames before `time` are skipped without being converted, so playing
  /// from a point doesn't pay for the whole video before it. Doesn't affect
  /// [frameAt].
  Future<void> seek(Duration time) async {
    _checkOpen();
    await _guard(VideoFrames.readerApi.seek(_id, time.inMicroseconds));
  }

  /// Release the decoders. Calling it again does nothing; reading after it
  /// throws a [StateError].
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _finalizer.detach(this);
    await _guard(VideoFrames.readerApi.closeReader(_id));
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

/// Encodes RGBA frames into an H.264 or HEVC MP4. Always [finish] or [cancel] it: it
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

  /// Encoded width: the requested width rounded down to an even number
  /// (H.264 and HEVC need even dimensions). Frames of the requested size are
  /// cropped.
  final int width;

  /// Encoded height, rounded down to an even number like [width].
  final int height;
  final int _requestedWidth;
  final int _requestedHeight;

  /// Whether the video gets sound: the audio source's track is being
  /// copied, or `audio` encoded. False when neither was given, the source
  /// has no audio, or its format can't go into an MP4 unchanged (the video
  /// is still written, silent).
  final bool includesAudio;
  bool _done = false;

  /// Create `path` (overwritten if it exists). With `audioSourcePath` (a
  /// file path, like [VideoReader.open]'s), that file's audio track is
  /// copied into the output unchanged; with `audio` instead, that sound is
  /// encoded to AAC (e.g. a mix made from [VideoFrames.decodeAudio]'s PCM).
  /// [VideoCodec.hevc] makes smaller files but fails on devices without an
  /// HEVC encoder; fall back to [VideoCodec.h264] when it throws.
  static Future<VideoWriter> create(
    String path, {
    required int width,
    required int height,
    required double frameRate,
    int? bitRate,
    String? audioSourcePath,
    VideoCodec codec = VideoCodec.h264,
    PcmAudio? audio,
  }) async {
    final w = width & ~1, h = height & ~1;
    if (w < 2 || h < 2) throw ArgumentError('video must be at least 2x2, got ${width}x$height');
    if (audio != null && audioSourcePath != null) {
      throw ArgumentError('give audio or audioSourcePath, not both');
    }
    final id = VideoFrames._id();
    final included = await _guard(
      VideoFrames.writerApi.openWriter(
        id,
        path,
        w,
        h,
        frameRate,
        bitRate,
        audioSourcePath,
        codec,
        audio?._message(),
      ),
    );
    return VideoWriter._(id, w, h, width, height, included);
  }

  /// Append a frame (RGBA, `width * height * 4` bytes, or the requested
  /// size before even-rounding) shown at `pts`.
  Future<void> addFrame(Uint8List rgba, Duration pts) {
    _checkOpen();
    return _guard(VideoFrames.writerApi.addFrame(_id, _fit(rgba), pts.inMicroseconds));
  }

  /// Flush the encoder, copy the audio track (if any) and close the file.
  /// If it fails, the encoder is freed and the partial file deleted.
  Future<void> finish() {
    _checkOpen();
    _done = true;
    _finalizer.detach(this);
    return _guard(VideoFrames.writerApi.finishWriter(_id));
  }

  /// Stop and delete the partial file.
  Future<void> cancel() async {
    if (_done) return;
    _done = true;
    _finalizer.detach(this);
    await _guard(VideoFrames.writerApi.cancelWriter(_id));
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
