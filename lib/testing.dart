/// Test seam for `package:video_frames`: the platform host APIs and their
/// messages, so tests can replace [VideoFrames.readerApi] and
/// [VideoFrames.writerApi] with fakes.
///
/// These types are generated and may change in any release; apps shouldn't
/// use them outside tests.
library;

import 'video_frames.dart';

export 'src/messages.g.dart'
    show VideoFrameMessage, VideoInfoMessage, VideoReaderHostApi, VideoWriterHostApi;
