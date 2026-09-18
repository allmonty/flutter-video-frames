import Flutter
import UIKit

/// Routes the Pigeon host API to `FrameReader`s and `FrameWriter`s by id.
/// Pigeon runs every call on a serial background queue.
public class VideoFramesPlugin: NSObject, FlutterPlugin, VideoFramesHostApi {
  private var readers: [Int64: FrameReader] = [:]
  private var writers: [Int64: FrameWriter] = [:]
  private let lock = NSLock()

  public static func register(with registrar: FlutterPluginRegistrar) {
    VideoFramesHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: VideoFramesPlugin())
  }

  private func reader(_ id: Int64) throws -> FrameReader {
    lock.lock()
    defer { lock.unlock() }
    guard let reader = readers[id] else {
      throw PigeonError(code: "not-found", message: "unknown reader \(id)", details: nil)
    }
    return reader
  }

  private func writer(_ id: Int64) throws -> FrameWriter {
    lock.lock()
    defer { lock.unlock() }
    guard let writer = writers[id] else {
      throw PigeonError(code: "not-found", message: "unknown writer \(id)", details: nil)
    }
    return writer
  }

  /// Rethrow native errors with a readable message on the Dart side.
  private func bridged<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as PigeonError {
      throw error
    } catch {
      throw PigeonError(code: "video-frames", message: "\(error)", details: nil)
    }
  }

  func openReader(readerId: Int64, path: String, maxDimension: Int64?) throws -> VideoInfoMessage {
    try bridged {
      let reader = try FrameReader(path: path, maxDimension: maxDimension.map { Int($0) })
      lock.lock()
      readers[readerId] = reader
      lock.unlock()
      return VideoInfoMessage(
        width: Int64(reader.width), height: Int64(reader.height), durationUs: reader.durationUs,
        frameRate: reader.frameRate, rotationDegrees: Int64(reader.rotation), hasAudio: reader.hasAudio,
        audioCompatible: reader.audioCompatible)
    }
  }

  func nextFrame(readerId: Int64) throws -> VideoFrameMessage? {
    try bridged {
      let reader = try self.reader(readerId)
      guard let frame = try reader.next() else { return nil }
      return VideoFrameMessage(
        ptsUs: frame.ptsUs, width: Int64(reader.width), height: Int64(reader.height),
        rgba: FlutterStandardTypedData(bytes: Data(frame.rgba)))
    }
  }

  func frameAt(readerId: Int64, timeUs: Int64) throws -> VideoFrameMessage {
    try bridged {
      let reader = try self.reader(readerId)
      let frame = try reader.frame(atUs: timeUs)
      return VideoFrameMessage(
        ptsUs: frame.ptsUs, width: Int64(reader.width), height: Int64(reader.height),
        rgba: FlutterStandardTypedData(bytes: Data(frame.rgba)))
    }
  }

  func closeReader(readerId: Int64) throws {
    lock.lock()
    let reader = readers.removeValue(forKey: readerId)
    lock.unlock()
    reader?.close()
  }

  func openWriter(
    writerId: Int64, path: String, width: Int64, height: Int64, frameRate: Double, bitRate: Int64?,
    audioSourcePath: String?
  ) throws -> Bool {
    try bridged {
      let writer = try FrameWriter(
        path: path, width: Int(width), height: Int(height), frameRate: frameRate,
        bitRate: bitRate.map { Int($0) }, audioSourcePath: audioSourcePath)
      lock.lock()
      writers[writerId] = writer
      lock.unlock()
      return writer.audioIncluded
    }
  }

  func addFrame(writerId: Int64, rgba: FlutterStandardTypedData, ptsUs: Int64) throws {
    try bridged { try writer(writerId).addFrame(rgba: rgba.data, ptsUs: ptsUs) }
  }

  func finishWriter(writerId: Int64) throws {
    try bridged {
      let writer = try self.writer(writerId)
      lock.lock()
      writers.removeValue(forKey: writerId)
      lock.unlock()
      try writer.finish()
    }
  }

  func cancelWriter(writerId: Int64) throws {
    lock.lock()
    let writer = writers.removeValue(forKey: writerId)
    lock.unlock()
    writer?.cancel()
  }
}
