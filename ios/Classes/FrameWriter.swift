import AVFoundation
import CoreMedia
import CoreVideo

/// Encodes RGBA frames to H.264 in an MP4 with `AVAssetWriter`, optionally
/// copying another file's audio track (passthrough, no re-encoding).
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

  /// Whether the audio source's track will be copied.
  var audioIncluded: Bool { audioReader != nil }

  init(path: String, width: Int, height: Int, frameRate: Double, bitRate: Int?, audioSourcePath: String?) throws {
    guard width % 2 == 0, height % 2 == 0 else {
      throw VideoFramesError.writeFailed("size must be even, got \(width)x\(height)")
    }
    url = URL(fileURLWithPath: path)
    self.width = width
    self.height = height
    try? FileManager.default.removeItem(at: url)
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

    let bits = bitRate ?? FrameWriter.defaultBitRate(width: width, height: height, frameRate: frameRate)
    videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: bits,
          AVVideoMaxKeyFrameIntervalKey: max(1, Int(frameRate.rounded())),
        ],
      ])
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

    guard writer.startWriting() else {
      throw VideoFramesError.writeFailed(writer.error?.localizedDescription ?? "cannot start writing")
    }
    writer.startSession(atSourceTime: .zero)
  }

  func addFrame(rgba: Data, ptsUs: Int64) throws {
    guard rgba.count == width * height * 4 else {
      throw VideoFramesError.writeFailed("expected \(width * height * 4) bytes, got \(rgba.count)")
    }
    try waitUntilReady(videoInput)
    guard let pool = adaptor.pixelBufferPool else {
      throw VideoFramesError.writeFailed(writer.error?.localizedDescription ?? "no pixel buffer pool")
    }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let pixels = buffer else { throw VideoFramesError.writeFailed("cannot allocate pixel buffer") }
    CVPixelBufferLockBaseAddress(pixels, [])
    rgba.withUnsafeBytes { src in
      PixelConversion.rgbaToBgra(
        src.bindMemory(to: UInt8.self).baseAddress!,
        width: width,
        height: height,
        into: CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self),
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixels))
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    if !adaptor.append(pixels, withPresentationTime: CMTime(value: ptsUs, timescale: 1_000_000)) {
      throw VideoFramesError.writeFailed(writer.error?.localizedDescription ?? "append failed")
    }
  }

  func finish() throws {
    videoInput.markAsFinished()
    if let input = audioInput, let reader = audioReader, let output = audioOutput {
      if reader.startReading() {
        while let sample = output.copyNextSampleBuffer() {
          try waitUntilReady(input)
          if !input.append(sample) { break }
        }
      }
      input.markAsFinished()
    }
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed {
      throw VideoFramesError.writeFailed(writer.error?.localizedDescription ?? "finish failed")
    }
  }

  func cancel() {
    audioReader?.cancelReading()
    writer.cancelWriting()
    try? FileManager.default.removeItem(at: url)
  }

  /// Offline encoding: poll until the input accepts more data.
  private func waitUntilReady(_ input: AVAssetWriterInput) throws {
    while !input.isReadyForMoreMediaData {
      if writer.status == .failed {
        throw VideoFramesError.writeFailed(writer.error?.localizedDescription ?? "writer failed")
      }
      usleep(1_000)
    }
  }

  /// ~0.2 bits per pixel per frame: good quality for flat pixel art.
  static func defaultBitRate(width: Int, height: Int, frameRate: Double) -> Int {
    max(1_000_000, Int(Double(width * height) * frameRate * 0.2))
  }
}
