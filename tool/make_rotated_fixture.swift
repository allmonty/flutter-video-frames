// Regenerate example/integration_test/assets/rotated90.mp4:
//   xcrun swift tool/make_rotated_fixture.swift example/integration_test/assets/rotated90.mp4
// Writes a 128x64 H.264 MP4 tagged with a 90° rotation: quadrants TL red, TR green, BL blue, BR white.
import AVFoundation
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: out)
let (w, h) = (128, 64)
let writer = try! AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
  // No B-frames: the Android emulator's decoder hands them out in decode order.
  AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]])
input.transform = CGAffineTransform(rotationAngle: .pi / 2)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
  kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
writer.add(input)
writer.startWriting(); writer.startSession(atSourceTime: .zero)
for i in 0..<15 {
  while !input.isReadyForMoreMediaData { usleep(1000) }
  var pb: CVPixelBuffer?
  CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
  CVPixelBufferLockBaseAddress(pb!, [])
  let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
  let bpr = CVPixelBufferGetBytesPerRow(pb!)
  for y in 0..<h { for x in 0..<w {
    let q = (y < h / 2 ? 0 : 2) + (x < w / 2 ? 0 : 1)
    let (r, g, b): (UInt8, UInt8, UInt8) = [(220, 40, 40), (40, 220, 40), (40, 40, 220), (220, 220, 220)][q]
    let o = y * bpr + x * 4
    base[o] = b; base[o + 1] = g; base[o + 2] = r; base[o + 3] = 255
  } }
  CVPixelBufferUnlockBaseAddress(pb!, [])
  adaptor.append(pb!, withPresentationTime: CMTime(value: Int64(i), timescale: 30))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }; done.wait()
print(writer.status == .completed ? "ok" : "failed \(String(describing: writer.error))")
