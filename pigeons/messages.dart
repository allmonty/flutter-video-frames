// Pigeon definition of the host API. Regenerate after editing:
//   dart run pigeon --input pigeons/messages.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    kotlinOut: 'android/src/main/kotlin/com/allmonty/video_frames/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.allmonty.video_frames'),
    swiftOut: 'ios/video_frames/Sources/video_frames/Messages.g.swift',
    dartPackageName: 'video_frames',
  ),
)
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

/// Every call runs on a serial background queue on the platform side, so
/// decoding and encoding never block the platform's main thread. Readers and
/// writers are addressed by ids chosen on the Dart side.
@HostApi()
abstract class VideoFramesHostApi {
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  VideoInfoMessage openReader(int readerId, String path, int? maxDimension);

  /// The next frame in presentation order, or null at the end.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  VideoFrameMessage? nextFrame(int readerId);

  /// The frame closest to `timeUs`, for scrubbing. Doesn't move the
  /// sequential position used by [nextFrame].
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  VideoFrameMessage frameAt(int readerId, int timeUs);

  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  void closeReader(int readerId);

  /// Returns whether the audio of `audioSourcePath` will be copied; audio
  /// that can't go into an MP4 unchanged is dropped instead of failing.
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  bool openWriter(
    int writerId,
    String path,
    int width,
    int height,
    double frameRate,
    int? bitRate,
    String? audioSourcePath,
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
