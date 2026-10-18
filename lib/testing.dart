/// Test seam for `package:video_frames`: the platform host APIs and their
/// messages, so tests can replace [VideoFrames.readerApi],
/// [VideoFrames.writerApi] and [VideoFrames.mediaApi] with fakes.
///
/// These types are generated and may change in any release; apps shouldn't
/// use them outside tests.
library;

import 'video_frames.dart';

export 'src/messages.g.dart'
    show
        MediaHostApi,
        PcmAudioMessage,
        VideoFrameMessage,
        VideoInfoMessage,
        VideoReaderHostApi,
        VideoWriterHostApi;
