import AVFoundation
import CoreMedia

/// Raw sound: 16-bit signed little-endian PCM, channels interleaved.
struct Pcm {
  var data: Data
  var sampleRate: Int
  var channels: Int
}

/// Whole-file work on sound and joining, with no Flutter dependency (tool/apple_check.sh compiles it directly).
enum AudioMedia {
  /// The first audio track of `path`, decoded to 16-bit PCM at its own rate and channels; nil when it has none.
  static func decode(path: String) throws -> Pcm? {
    guard FileManager.default.fileExists(atPath: path) else { throw VideoFramesError.fileNotFound(path) }
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
    // A CF cast can't fail: formatDescriptions only holds CMFormatDescriptions.
    guard let format = track.formatDescriptions.first.map({ $0 as! CMAudioFormatDescription }),
      let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
    else { throw VideoFramesError.readFailed("no audio format in \(path)") }
    let rate = Int(stream.mSampleRate)
    let channels = Int(stream.mChannelsPerFrame)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
      ])
    reader.add(output)
    guard reader.startReading() else {
      throw VideoFramesError.readFailed(reader.error?.localizedDescription ?? "cannot read the audio of \(path)")
    }
    var data = Data()
    while let sample = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      let length = CMBlockBufferGetDataLength(block)
      var bytes = Data(count: length)
      bytes.withUnsafeMutableBytes { buffer in
        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
      }
      data.append(bytes)
    }
    if reader.status == .failed {
      throw VideoFramesError.readFailed(reader.error?.localizedDescription ?? "decoding the audio failed")
    }
    return Pcm(data: data, sampleRate: rate, channels: channels)
  }

  /// `pcm` cut into sample buffers of up to `frames` frames each, timed from zero, for an AAC writer input.
  static func sampleBuffers(_ pcm: Pcm, frames: Int = 4096) throws -> [CMSampleBuffer] {
    let bytesPerFrame = pcm.channels * 2
    var stream = AudioStreamBasicDescription(
      mSampleRate: Float64(pcm.sampleRate), mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
      mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytesPerFrame),
      mChannelsPerFrame: UInt32(pcm.channels), mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &stream, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &format) == noErr, let format
    else { throw VideoFramesError.writeFailed("cannot describe the audio") }
    let total = pcm.data.count / bytesPerFrame
    var buffers: [CMSampleBuffer] = []
    for start in stride(from: 0, to: total, by: frames) {
      let count = min(frames, total - start)
      let bytes = pcm.data.subdata(in: start * bytesPerFrame..<(start + count) * bytesPerFrame)
      var block: CMBlockBuffer?
      guard
        CMBlockBufferCreateWithMemoryBlock(
          allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil,
          offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
          blockBufferOut: &block) == noErr, let block
      else { throw VideoFramesError.writeFailed("cannot hold the audio") }
      _ = bytes.withUnsafeBytes { raw in
        CMBlockBufferReplaceDataBytes(
          with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
      }
      var sample: CMSampleBuffer?
      guard
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
          allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
          presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(pcm.sampleRate)),
          packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample
      else { throw VideoFramesError.writeFailed("cannot time the audio") }
      buffers.append(sample)
    }
    return buffers
  }

  /// Join MP4s of the same format one after another into `output`, without re-encoding.
  static func concat(inputs: [String], output: String) throws {
    guard !inputs.isEmpty else { throw VideoFramesError.writeFailed("nothing to join") }
    let composition = AVMutableComposition()
    var cursor = CMTime.zero
    for path in inputs {
      guard FileManager.default.fileExists(atPath: path) else { throw VideoFramesError.fileNotFound(path) }
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      try composition.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: asset, at: cursor)
      cursor = CMTimeAdd(cursor, asset.duration)
    }
    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
      throw VideoFramesError.writeFailed("these videos can't be joined without re-encoding")
    }
    let url = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: url)
    export.outputURL = url
    export.outputFileType = .mp4
    let done = DispatchSemaphore(value: 0)
    export.exportAsynchronously { done.signal() }
    if done.wait(timeout: .now() + AudioMedia.concatTimeout) == .timedOut {
      export.cancelExport()
      throw VideoFramesError.writeFailed("joining took over \(Int(AudioMedia.concatTimeout)) s")
    }
    guard export.status == .completed else {
      try? FileManager.default.removeItem(at: url)
      throw VideoFramesError.writeFailed(export.error?.localizedDescription ?? "joining failed")
    }
  }

  /// Copying without re-encoding is fast, but scales with length (an episode can be long).
  static let concatTimeout: TimeInterval = 600
}
