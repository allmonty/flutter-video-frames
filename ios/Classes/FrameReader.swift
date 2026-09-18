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

  private let asset: AVURLAsset
  private let reader: AVAssetReader
  private let output: AVAssetReaderTrackOutput
  private let srcWidth: Int
  private let srcHeight: Int
  private lazy var generator: AVAssetImageGenerator = {
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = CGSize(width: width, height: height)
    return generator
  }()

  init(path: String, maxDimension: Int?) throws {
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
    hasAudio = !asset.tracks(withMediaType: .audio).isEmpty

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
      return (Int64(CMTimeGetSeconds(pts) * 1_000_000), convert(pixels))
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
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    if !drawn { throw VideoFramesError.readFailed("cannot draw frame") }
    for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 255 }
    return (Int64(CMTimeGetSeconds(actual) * 1_000_000), rgba)
  }

  func close() {
    reader.cancelReading()
  }

  private func convert(_ pixels: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    return PixelConversion.bgraToRgba(
      base,
      srcWidth: CVPixelBufferGetWidth(pixels),
      srcHeight: CVPixelBufferGetHeight(pixels),
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
      rotation: rotation,
      dstWidth: width,
      dstHeight: height)
  }
}
