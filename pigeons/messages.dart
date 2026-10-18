// Pigeon definition of the host API. Regenerate after editing:
//   dart run pigeon --input pigeons/messages.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    kotlinOut: 'android/src/main/kotlin/com/allmonty/video_frames/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.allmonty.video_frames'),
    swiftOut: 'darwin/video_frames/Sources/video_frames/Messages.g.swift',
    dartPackageName: 'video_frames',
  ),
)
/// How frames are filtered when `maxDimension` scales them down.
enum ScaleFilter {
  /// Pick the source pixel at each output pixel's center: sharp, keeps hard
  /// edges (pixel art), but aliases on photos.
  nearest,

  /// Blend the 2x2 source pixels around each output pixel's center: smooth
  /// for downscales up to about 2x; larger ones alias again.
  bilinear,

  /// Average every source pixel an output pixel covers: smooth at any
  /// downscale (e.g. 4K to 720p).
  area,
}

/// The video codec a writer encodes with.
enum VideoCodec {
  /// Plays everywhere.
  h264,

  /// About half the size of H.264 at the same quality; needs a device with
  /// an HEVC encoder (writer creation fails otherwise) and a player that
  /// supports it.
  hevc,
}

class VideoInfoMessage {
  VideoInfoMessage({
    required this.width,
    required this.height,
    required this.durationUs,
    required this.frameRate,
    required this.rotationDegrees,
    required this.hasAudio,
    required this.audioCompatible,
  });

  /// Frame size as delivered (after rotation and scaling).
  int width;
  int height;
  int durationUs;
  double frameRate;

  /// Rotation from the file's metadata, already applied to the frames.
  int rotationDegrees;
  bool hasAudio;

  /// The audio track can be copied into an MP4 unchanged (false when there
  /// is no audio, or its format doesn't fit the MP4 container).
  bool audioCompatible;
}

class VideoFrameMessage {
  VideoFrameMessage({
    required this.ptsUs,
    required this.width,
    required this.height,
    required this.rgba,
  });

  int ptsUs;
  int width;
  int height;

  /// Row-major RGBA, `width * height * 4` bytes.
  Uint8List rgba;
}

/// Raw sound: 16-bit signed little-endian PCM, channels interleaved.
class PcmAudioMessage {
  PcmAudioMessage({required this.pcm, required this.sampleRate, required this.channels});

  Uint8List pcm;
  int sampleRate;
  int channels;
}

// Readers and writers are separate APIs so each gets its own serial
// background queue: decoding one frame can run while another is encoded.
// Neither blocks the platform's main thread. Readers and writers are
// addressed by ids chosen on the Dart side.

/// Decoding, on its own serial background queue.
@HostApi()
abstract class VideoReaderHostApi {
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  VideoInfoMessage openReader(int readerId, String path, int? maxDimension, ScaleFilter filter);

  /// The next frame in presentation order, or null at the end.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  VideoFrameMessage? nextFrame(int readerId);

  /// The frame closest to `timeUs`, for scrubbing. Doesn't move the
  /// sequential position used by [nextFrame].
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  VideoFrameMessage frameAt(int readerId, int timeUs);

  /// Moves the sequential position: the next [nextFrame] returns the first
  /// frame at or after `timeUs`. Doesn't affect [frameAt].
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void seek(int readerId, int timeUs);

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void closeReader(int readerId);
}

/// Encoding, on its own serial background queue.
@HostApi()
abstract class VideoWriterHostApi {
  /// Returns whether the audio of `audioSourcePath` will be copied; audio
  /// that can't go into an MP4 unchanged is dropped instead of failing.
  /// `audio` (instead of `audioSourcePath`) is encoded to AAC.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  bool openWriter(
    int writerId,
    String path,
    int width,
    int height,
    double frameRate,
    int? bitRate,
    String? audioSourcePath,
    VideoCodec codec,
    PcmAudioMessage? audio,
  );

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void addFrame(int writerId, Uint8List rgba, int ptsUs);

  /// Flush, copy the audio track (if any) and close the file.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void finishWriter(int writerId);

  /// Stop and delete the partial file.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void cancelWriter(int writerId);
}

/// Whole-file work (sound and joining), on its own serial background queue.
@HostApi()
abstract class MediaHostApi {
  /// The first audio track of a file as PCM at its own rate and channels, or
  /// null when it has none.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  PcmAudioMessage? decodeAudio(String path);

  /// Join MP4s of the same format one after another, without re-encoding.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void concat(List<String> inputs, String output);
}
