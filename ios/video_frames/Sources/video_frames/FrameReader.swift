import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo

enum VideoFramesError: Error, CustomStringConvertible {
  case noVideoTrack(String)
  case readFailed(String)
  case writeFailed(String)

  var description: String {
    switch self {
    case .noVideoTrack(let path): return "no video track in \(path)"
    case .readFailed(let message): return "read failed: \(message)"
    case .writeFailed(let message): return "write failed: \(message)"
    }
  }
}

/// Whether an audio track can be copied into an MP4 unchanged: a
/// passthrough writer input for it must be accepted by an MP4 writer (AAC
/// is; e.g. the PCM audio of many .mov files isn't).
enum AudioSupport {
  static func canCopyIntoMp4(_ track: AVAssetTrack) -> Bool {
    passthroughInput(for: track, into: nil) != nil
  }

  /// A passthrough input for `track`, added to `writer` when given; nil if an
  /// MP4 writer won't accept it.
  static func passthroughInput(for track: AVAssetTrack, into writer: AVAssetWriter?) -> AVAssetWriterInput? {
    // A CF cast can't fail: formatDescriptions only holds CMFormatDescriptions.
    let hint = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
    input.expectsMediaDataInRealTime = false
    let target: AVAssetWriter
    if let writer = writer {
      target = writer
    } else {
      let probe = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("video_frames_probe_\(UUID().uuidString).mp4")
      guard let probeWriter = try? AVAssetWriter(outputURL: probe, fileType: .mp4) else { return nil }
      target = probeWriter
    }
    guard target.canAdd(input) else { return nil }
    if writer != nil { target.add(input) }
    return input
  }
}

/// Decodes a file's video track to upright RGBA frames (rotation metadata
/// applied), optionally scaled down. Sequential frames come from an
/// `AVAssetReader`; random access (`frame(at:)`) uses `AVAssetImageGenerator`.
final class FrameReader {
  let width: Int
  let height: Int
  let rotation: Int
  let durationUs: Int64
  let frameRate: Double
  let hasAudio: Bool

  /// The audio track can be copied into an MP4 unchanged.
  let audioCompatible: Bool

  private let asset: AVURLAsset
  private let reader: AVAssetReader
  private let output: AVAssetReaderTrackOutput
  private let srcWidth: Int
  private let srcHeight: Int
  private let filter: PixelConversion.Filter
  /// Full size, so frames are scaled with `filter` exactly like `next()`.
  private lazy var generator: AVAssetImageGenerator = {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return generator
  }()

  init(path: String, maxDimension: Int?, filter: PixelConversion.Filter = .nearest) throws {
    self.filter = filter
    asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first else {
      throw VideoFramesError.noVideoTrack(path)
    }
    srcWidth = Int(track.naturalSize.width)
    srcHeight = Int(track.naturalSize.height)
    let t = track.preferredTransform
    rotation = PixelConversion.rotationDegrees(a: Double(t.a), b: Double(t.b))
    (width, height) = PixelConversion.outputSize(
      srcWidth: srcWidth, srcHeight: srcHeight, rotation: rotation, maxDimension: maxDimension)
    durationUs = Int64(CMTimeGetSeconds(asset.duration) * 1_000_000)
    frameRate = track.nominalFrameRate > 0 ? Double(track.nominalFrameRate) : 30
    let audioTrack = asset.tracks(withMediaType: .audio).first
    hasAudio = audioTrack != nil
    audioCompatible = audioTrack.map(AudioSupport.canCopyIntoMp4) ?? false

    reader = try AVAssetReader(asset: asset)
    output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    if !reader.startReading() {
      throw VideoFramesError.readFailed(reader.error?.localizedDescription ?? "cannot start reading")
    }
  }

  /// The next frame in presentation order, or nil at the end.
  func next() throws -> (ptsUs: Int64, rgba: [UInt8])? {
    while let sample = output.copyNextSampleBuffer() {
      guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      return (Int64(CMTimeGetSeconds(pts) * 1_000_000), try convert(pixels))
    }
    if reader.status == .failed {
      throw VideoFramesError.readFailed(reader.error?.localizedDescription ?? "unknown error")
    }
    return nil
  }

  /// The frame at (or nearest to) `timeUs`, upright and scaled like `next()`.
  func frame(atUs timeUs: Int64) throws -> (ptsUs: Int64, rgba: [UInt8]) {
    var actual = CMTime.zero
    let image = try generator.copyCGImage(
      at: CMTime(value: timeUs, timescale: 1_000_000), actualTime: &actual)
    // Draw the upright full-size frame as BGRA, then convert like next() (no rotation left).
    let (w, h) = (image.width, image.height)
    var bgra = [UInt8](repeating: 0, count: w * h * 4)
    let rgba = try bgra.withUnsafeMutableBytes { buffer -> [UInt8] in
      guard
        let base = buffer.baseAddress,
        let context = CGContext(
          data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
      else { throw VideoFramesError.readFailed("cannot draw frame") }
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return PixelConversion.bgraToRgba(
        base.assumingMemoryBound(to: UInt8.self), srcWidth: w, srcHeight: h, bytesPerRow: w * 4,
        rotation: 0, dstWidth: width, dstHeight: height, filter: filter)
    }
    return (Int64(CMTimeGetSeconds(actual) * 1_000_000), rgba)
  }

  func close() {
    reader.cancelReading()
  }

  private func convert(_ pixels: CVPixelBuffer) throws -> [UInt8] {
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixels) else {
      throw VideoFramesError.readFailed("frame has no pixel data")
    }
    return PixelConversion.bgraToRgba(
      base.assumingMemoryBound(to: UInt8.self),
      srcWidth: CVPixelBufferGetWidth(pixels),
      srcHeight: CVPixelBufferGetHeight(pixels),
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
      rotation: rotation,
      dstWidth: width,
      dstHeight: height,
      filter: filter)
  }
}
