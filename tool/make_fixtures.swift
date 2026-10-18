// Regenerate the test videos in example/integration_test/assets:
//   xcrun swift tool/make_fixtures.swift example/integration_test/assets
// - rotated90.mp4: 128x64 tagged with a 90° rotation; quadrants TL red, TR green, BL blue, BR white.
// - colors709.mp4: 1280x720 tagged BT.709; quadrants green, skin tone, red, blue.
// - hlg.mp4: 640x360 HEVC Main10, HLG / BT.2020 (HDR) made from SDR quadrants
//   green, skin tone, red, gray.
// - tone8.mp4: 64x64 gray with 8 s of mono 44.1 kHz AAC (a 440 Hz tone): an audio source longer than the
//   ~1 s AVAssetWriter interleaves by.
import AVFoundation
import VideoToolbox

func write(_ path: String, _ w: Int, _ h: Int, _ colors: [(UInt8, UInt8, UInt8)], rotated: Bool = false, hdr: Bool = false, toneSeconds: Int = 0) {
  let out = URL(fileURLWithPath: path)
  try? FileManager.default.removeItem(at: out)
  let writer = try! AVAssetWriter(outputURL: out, fileType: .mp4)
  let color: [String: Any] = hdr ? [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
  ] : [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
  ]
  // No B-frames: the Android emulator's decoder hands them out in decode order.
  var compression: [String: Any] = [AVVideoAllowFrameReorderingKey: false]
  if hdr { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: hdr ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
    AVVideoColorPropertiesKey: color, AVVideoCompressionPropertiesKey: compression])
  if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
  writer.add(input)
  let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
  if toneSeconds > 0 { writer.add(audio) }
  writer.startWriting(); writer.startSession(atSourceTime: .zero)
  for i in 0..<15 {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    // The source pixels are SDR BT.709; for HDR the encoder converts them to HLG.
    CVBufferSetAttachment(pb!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(pb!)
    for y in 0..<h { for x in 0..<w {
      let (r, g, b) = colors[(y < h / 2 ? 0 : 2) + (x < w / 2 ? 0 : 1)]
      let o = y * bpr + x * 4
      base[o] = b; base[o + 1] = g; base[o + 2] = r; base[o + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    adaptor.append(pb!, withPresentationTime: CMTime(value: Int64(i), timescale: 30))
  }
  input.markAsFinished()
  // The 0.5 s of video is under the interleave chunk, so the video never waits for this audio.
  if toneSeconds > 0 { appendTone(audio, seconds: toneSeconds); audio.markAsFinished() }
  let done = DispatchSemaphore(value: 0)
  writer.finishWriting { done.signal() }; done.wait()
  print(path, writer.status == .completed ? "ok" : "failed \(String(describing: writer.error))")
}

func appendTone(_ input: AVAssetWriterInput, seconds: Int) {
  let rate = 44100, chunk = 4410
  var pcmFormat = AudioStreamBasicDescription(
    mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 2,
    mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
  var format: CMAudioFormatDescription?
  CMAudioFormatDescriptionCreate(
    allocator: nil, asbd: &pcmFormat, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
    extensions: nil, formatDescriptionOut: &format)
  for start in stride(from: 0, to: seconds * rate, by: chunk) {
    var pcm = (0..<chunk).map { Int16(8000 * sin(2 * Double.pi * 440 * Double(start + $0) / Double(rate))) }
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
      allocator: nil, memoryBlock: nil, blockLength: chunk * 2, blockAllocator: nil, customBlockSource: nil,
      offsetToData: 0, dataLength: chunk * 2, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    CMBlockBufferReplaceDataBytes(with: &pcm, blockBuffer: block!, offsetIntoDestination: 0, dataLength: chunk * 2)
    var sample: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: chunk,
      presentationTimeStamp: CMTime(value: Int64(start), timescale: Int32(rate)), packetDescriptions: nil,
      sampleBufferOut: &sample)
    while !input.isReadyForMoreMediaData { usleep(1000) }
    input.append(sample!)
  }
}

let dir = CommandLine.arguments[1]
write("\(dir)/rotated90.mp4", 128, 64, [(220, 40, 40), (40, 220, 40), (40, 40, 220), (220, 220, 220)], rotated: true)
write("\(dir)/colors709.mp4", 1280, 720, [(40, 200, 60), (224, 172, 140), (200, 40, 40), (40, 60, 200)])
write("\(dir)/hlg.mp4", 640, 360, [(40, 200, 60), (224, 172, 140), (200, 40, 40), (128, 128, 128)], hdr: true)
write("\(dir)/tone8.mp4", 64, 64, [(128, 128, 128), (128, 128, 128), (128, 128, 128), (128, 128, 128)], toneSeconds: 8)
