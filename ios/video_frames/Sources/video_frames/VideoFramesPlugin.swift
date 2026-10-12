import Flutter
import UIKit

/// Routes the Pigeon host APIs to `FrameReader`s and `FrameWriter`s by id.
/// Pigeon runs reader calls and writer calls on two separate serial
/// background queues.
public class VideoFramesPlugin: NSObject, FlutterPlugin, VideoReaderHostApi, VideoWriterHostApi {
  private var readers: [Int64: FrameReader] = [:]
  private var writers: [Int64: FrameWriter] = [:]
  private let lock = NSLock()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = VideoFramesPlugin()
    VideoReaderHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    VideoWriterHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    // Published so the engine calls detachFromEngine(for:) on shutdown.
    registrar.publish(instance)
  }

  /// Free every decoder and encoder still open when the engine goes away.
  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    VideoReaderHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
    VideoWriterHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
    lock.lock()
    let openReaders = readers.values
    let openWriters = writers.values
    readers.removeAll()
    writers.removeAll()
    lock.unlock()
    openReaders.forEach { $0.close() }
    openWriters.forEach { $0.cancel() }
  }

  private func reader(_ id: Int64) throws -> FrameReader {
    lock.lock()
    defer { lock.unlock() }
    guard let reader = readers[id] else {
      throw PigeonError(code: "readFailed", message: "unknown reader \(id)", details: nil)
    }
    return reader
  }

  private func writer(_ id: Int64) throws -> FrameWriter {
    lock.lock()
    defer { lock.unlock() }
    guard let writer = writers[id] else {
      throw PigeonError(code: "writeFailed", message: "unknown writer \(id)", details: nil)
    }
    return writer
  }

  /// Rethrow native errors with a Dart `VideoFramesErrorCode` name as the
  /// code; `fallback` is the code for errors that aren't `VideoFramesError`s.
  private func bridged<T>(_ fallback: String, _ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as PigeonError {
      throw error
    } catch let error as VideoFramesError {
      throw PigeonError(code: error.code, message: error.description, details: nil)
    } catch {
      throw PigeonError(code: fallback, message: "\(error)", details: nil)
    }
  }

  func openReader(readerId: Int64, path: String, maxDimension: Int64?, filter: ScaleFilter) throws
    -> VideoInfoMessage
  {
    try bridged("unsupportedFormat") {
      let reader = try FrameReader(
        path: path, maxDimension: maxDimension.map { Int($0) },
        filter: PixelConversion.Filter(rawValue: filter.rawValue) ?? .nearest)
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
    try bridged("readFailed") {
      let reader = try self.reader(readerId)
      guard let frame = try reader.next() else { return nil }
      return VideoFrameMessage(
        ptsUs: frame.ptsUs, width: Int64(reader.width), height: Int64(reader.height),
        rgba: FlutterStandardTypedData(bytes: frame.rgba))
    }
  }

  func frameAt(readerId: Int64, timeUs: Int64) throws -> VideoFrameMessage {
    try bridged("readFailed") {
      let reader = try self.reader(readerId)
      let frame = try reader.frame(atUs: timeUs)
      return VideoFrameMessage(
        ptsUs: frame.ptsUs, width: Int64(reader.width), height: Int64(reader.height),
        rgba: FlutterStandardTypedData(bytes: frame.rgba))
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
    audioSourcePath: String?, codec: VideoCodec
  ) throws -> Bool {
    try bridged("writeFailed") {
      let writer = try FrameWriter(
        path: path, width: Int(width), height: Int(height), frameRate: frameRate,
        bitRate: bitRate.map { Int($0) }, audioSourcePath: audioSourcePath, hevc: codec == .hevc)
      lock.lock()
      writers[writerId] = writer
      lock.unlock()
      return writer.audioIncluded
    }
  }

  func addFrame(writerId: Int64, rgba: FlutterStandardTypedData, ptsUs: Int64) throws {
    try bridged("writeFailed") { try writer(writerId).addFrame(rgba: rgba.data, ptsUs: ptsUs) }
  }

  func finishWriter(writerId: Int64) throws {
    try bridged("writeFailed") {
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
