import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo

enum VideoFramesError: Error, CustomStringConvertible {
  case fileNotFound(String)
  case noVideoTrack(String)
  case codecUnsupported(String)
  case readFailed(String)
  case writeFailed(String)

  /// The Dart `VideoFramesErrorCode` name the plugin reports.
  var code: String {
    switch self {
    case .fileNotFound: return "fileNotFound"
    case .noVideoTrack: return "unsupportedFormat"
    case .codecUnsupported: return "codecUnsupported"
    case .readFailed: return "readFailed"
    case .writeFailed: return "writeFailed"
    }
  }

  var description: String {
    switch self {
    case .fileNotFound(let path): return "no file at \(path)"
    case .noVideoTrack(let path): return "no video track in \(path)"
    case .codecUnsupported(let message): return message
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
/// applied), optionally scaled down. Sequential frames come from one
/// `AVAssetReader`; random access (`frame(atUs:)`) starts a short-lived one at
/// the requested time, so both convert colors the same way (HDR included:
/// AVFoundation tone-maps it to SDR).
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
  private let track: AVAssetTrack
  private let reader: AVAssetReader
  private let output: AVAssetReaderTrackOutput
  private let srcWidth: Int
  private let srcHeight: Int
  private let filter: PixelConversion.Filter

  init(path: String, maxDimension: Int?, filter: PixelConversion.Filter = .nearest) throws {
    self.filter = filter
    guard FileManager.default.fileExists(atPath: path) else { throw VideoFramesError.fileNotFound(path) }
    asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first else {
      throw VideoFramesError.noVideoTrack(path)
    }
    self.track = track
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

    (reader, output) = try FrameReader.startReading(asset, track, from: nil)
  }

  /// A BGRA reader over `track`, from `start` to the end (or all of it).
  private static func startReading(_ asset: AVAsset, _ track: AVAssetTrack, from start: CMTime?) throws
    -> (AVAssetReader, AVAssetReaderTrackOutput)
  {
    let reader = try AVAssetReader(asset: asset)
    if let start = start { reader.timeRange = CMTimeRange(start: start, end: .positiveInfinity) }
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    if !reader.startReading() {
      throw VideoFramesError.readFailed(reader.error?.localizedDescription ?? "cannot start reading")
    }
    return (reader, output)
  }

  /// The next frame in presentation order, or nil at the end.
  func next() throws -> (ptsUs: Int64, rgba: Data)? {
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

  /// The first frame at or after `timeUs` (the last frame when `timeUs` is
  /// past the end), upright, scaled and color-converted like `next()`.
  func frame(atUs timeUs: Int64) throws -> (ptsUs: Int64, rgba: Data) {
    let target = CMTime(value: timeUs, timescale: 1_000_000)
    // Start a second before the end at the latest, so a time past the end
    // still finds the last frame.
    let latest = CMTimeSubtract(asset.duration, CMTime(value: 1, timescale: 1))
    let (seeker, frames) = try FrameReader.startReading(
      asset, track, from: CMTimeMaximum(.zero, CMTimeMinimum(target, latest)))
    defer { seeker.cancelReading() }
    var last: (CMTime, CVPixelBuffer)?
    while let sample = frames.copyNextSampleBuffer() {
      guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      last = (pts, pixels)
      if pts >= target { break }
    }
    if seeker.status == .failed {
      throw VideoFramesError.readFailed(seeker.error?.localizedDescription ?? "unknown error")
    }
    guard let (pts, pixels) = last else { throw VideoFramesError.readFailed("no frame at \(timeUs) us") }
    return (Int64(CMTimeGetSeconds(pts) * 1_000_000), try convert(pixels))
  }

  func close() {
    reader.cancelReading()
  }

  private func convert(_ pixels: CVPixelBuffer) throws -> Data {
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
