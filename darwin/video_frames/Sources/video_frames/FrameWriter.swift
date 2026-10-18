import AVFoundation
import CoreMedia
import CoreVideo

/// Encodes RGBA frames to H.264 or HEVC in an MP4 with `AVAssetWriter`, with sound
/// either copied from another file's audio track (passthrough, no re-encoding) or
/// encoded to AAC from PCM.
final class FrameWriter {
  private let url: URL
  private let width: Int
  private let height: Int
  private let writer: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private var audioInput: AVAssetWriterInput?
  private var audioReader: AVAssetReader?
  private var audioOutput: AVAssetReaderTrackOutput?
  /// The PCM to encode, already cut into sample buffers; taken from the front.
  private var pcmSamples: [CMSampleBuffer] = []
  private var audioDone = false

  /// Whether the output gets sound: the audio source's track will be copied, or the PCM encoded.
  var audioIncluded: Bool { audioReader != nil || !pcmSamples.isEmpty }

  init(
    path: String, width: Int, height: Int, frameRate: Double, bitRate: Int?, audioSourcePath: String?,
    hevc: Bool = false, audio: Pcm? = nil
  ) throws {
    guard width % 2 == 0, height % 2 == 0 else {
      throw VideoFramesError.writeFailed("size must be even, got \(width)x\(height)")
    }
    url = URL(fileURLWithPath: path)
    self.width = width
    self.height = height
    try? FileManager.default.removeItem(at: url)
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

    let bits = bitRate ?? FrameWriter.defaultBitRate(width: width, height: height, frameRate: frameRate)
    let settings: [String: Any] = [
      AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      // Tag BT.709 so players don't guess (HD is 709; untagged often reads as 601).
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bits,
        AVVideoMaxKeyFrameIntervalKey: max(1, Int(frameRate.rounded())),
      ],
    ]
    // Devices without an HEVC encoder (e.g. A9 chips) can't apply these settings.
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
      throw VideoFramesError.codecUnsupported(
        "\(hevc ? "HEVC" : "H.264") encoding at \(width)x\(height) is not supported on this device")
    }
    videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    videoInput.expectsMediaDataInRealTime = false
    adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ])
    writer.add(videoInput)

    if let audioSourcePath = audioSourcePath {
      let asset = AVURLAsset(url: URL(fileURLWithPath: audioSourcePath))
      // Audio the MP4 can't hold unchanged is dropped; the video is still
      // written. The reader is created first so an input is only added to
      // the writer when its samples can actually be read.
      if let track = asset.tracks(withMediaType: .audio).first,
        let reader = try? AVAssetReader(asset: asset),
        let input = AudioSupport.passthroughInput(for: track, into: writer)
      {
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        audioInput = input
        audioReader = reader
        audioOutput = output
      }
    }

    if let audio, !audio.data.isEmpty {
      let settings: [String: Any] = [
        // No bit rate: the encoder's default suits each rate (a fixed one is refused at 24 kHz mono).
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audio.sampleRate, AVNumberOfChannelsKey: audio.channels,
      ]
      guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
        throw VideoFramesError.codecUnsupported(
          "AAC at \(audio.sampleRate) Hz with \(audio.channels) channels is not supported on this device")
      }
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
      input.expectsMediaDataInRealTime = false
      writer.add(input)
      audioInput = input
      pcmSamples = try AudioMedia.sampleBuffers(audio)
    }

    guard writer.startWriting() else {
      throw VideoFramesError.writeFailed(writer.error?.localizedDescription ?? "cannot start writing")
    }
    writer.startSession(atSourceTime: .zero)
    // Audio is copied as the frames come in, not all at the end: AVAssetWriter interleaves the tracks, so it stops
    // taking video once the video is about a second ahead of the audio.
    if let reader = audioReader, !reader.startReading() { endAudio() }
  }

  func addFrame(rgba: Data, ptsUs: Int64) throws {
    guard rgba.count == width * height * 4 else {
      throw VideoFramesError.writeFailed("expected \(width * height * 4) bytes, got \(rgba.count)")
    }
    // A blocked video input is waiting for audio (it interleaves in chunks of about a second): give the audio input
    // whatever it takes. Its own readiness keeps the audio from running far ahead.
    try waitUntilReady(videoInput) { feedAudio() }
    guard let pool = adaptor.pixelBufferPool else {
      throw VideoFramesError.writeFailed(writer.error?.localizedDescription ?? "no pixel buffer pool")
    }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pixels = buffer
    else { throw VideoFramesError.writeFailed("cannot allocate pixel buffer") }
    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    guard let dst = CVPixelBufferGetBaseAddress(pixels) else {
      throw VideoFramesError.writeFailed("pixel buffer has no memory")
    }
    rgba.withUnsafeBytes { src in
      // Non-empty: the size check above needs at least one pixel.
      PixelConversion.rgbaToBgra(
        src.bindMemory(to: UInt8.self).baseAddress!,
        width: width,
        height: height,
        into: dst.assumingMemoryBound(to: UInt8.self),
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixels))
    }
    if !adaptor.append(pixels, withPresentationTime: CMTime(value: ptsUs, timescale: 1_000_000)) {
      throw VideoFramesError.writeFailed(writer.error?.localizedDescription ?? "append failed")
    }
  }

  func finish() throws {
    do {
      videoInput.markAsFinished()
      if let input = audioInput {
        // The rest of the audio, however long (it may outlast the video).
        while !audioDone {
          try waitUntilReady(input)
          feedAudio()
        }
      }
      let done = DispatchSemaphore(value: 0)
      writer.finishWriting { done.signal() }
      if done.wait(timeout: .now() + FrameWriter.finishTimeout) == .timedOut {
        throw VideoFramesError.encoderStalled("finishing the file took over \(Int(FrameWriter.finishTimeout)) s")
      }
      if writer.status != .completed {
        throw VideoFramesError.writeFailed(writer.error?.localizedDescription ?? "finish failed")
      }
    } catch {
      // Don't leave a broken file behind.
      cancel()
      throw error
    }
  }

  func cancel() {
    audioReader?.cancelReading()
    if writer.status == .writing { writer.cancelWriting() }
    try? FileManager.default.removeItem(at: url)
  }

  /// Offline encoding: poll until the input accepts more data, failing
  /// instead of waiting forever if the encoder stops making progress.
  /// `whileWaiting` runs on each poll, e.g. to feed the other track the writer is waiting for.
  private func waitUntilReady(_ input: AVAssetWriterInput, whileWaiting: () -> Void = {}) throws {
    let deadline = Date().addingTimeInterval(FrameWriter.stallTimeout)
    while !input.isReadyForMoreMediaData {
      whileWaiting()
      if writer.status == .failed {
        throw VideoFramesError.writeFailed(writer.error?.localizedDescription ?? "writer failed")
      }
      if Date() > deadline {
        throw VideoFramesError.encoderStalled("not ready for \(Int(FrameWriter.stallTimeout)) s")
      }
      usleep(1_000)
    }
  }

  /// Append the next audio samples (copied or encoded), as many as the audio input takes now.
  private func feedAudio() {
    guard let input = audioInput, !audioDone else { return }
    while input.isReadyForMoreMediaData {
      guard let sample = audioOutput?.copyNextSampleBuffer() ?? (pcmSamples.isEmpty ? nil : pcmSamples.removeFirst())
      else {
        endAudio()
        return
      }
      if !input.append(sample) {
        audioDone = true  // the writer failed; the next wait reports its error
        return
      }
    }
  }

  /// Mark the audio track finished as soon as the source runs out: until then the writer can't tell it ended, and
  /// holds the last video frames back waiting for more audio.
  private func endAudio() {
    guard !audioDone else { return }
    audioDone = true
    audioInput?.markAsFinished()
  }

  /// Same limit as Android's encoder stall check.
  static let stallTimeout: TimeInterval = 5
  /// Writing the file's index at the end; generous, since it scales with length.
  static let finishTimeout: TimeInterval = 60

  /// ~0.2 bits per pixel per frame: good quality for flat pixel art.
  static func defaultBitRate(width: Int, height: Int, frameRate: Double) -> Int {
    max(1_000_000, Int(Double(width * height) * frameRate * 0.2))
  }
}
