// Regenerate the test videos in example/integration_test/assets:
//   xcrun swift tool/make_fixtures.swift example/integration_test/assets
// - rotated90.mp4: 128x64 tagged with a 90° rotation; quadrants TL red, TR green, BL blue, BR white.
// - colors709.mp4: 1280x720 tagged BT.709; quadrants green, skin tone, red, blue.
import AVFoundation

func write(_ path: String, _ w: Int, _ h: Int, _ colors: [(UInt8, UInt8, UInt8)], rotated: Bool) {
  let out = URL(fileURLWithPath: path)
  try? FileManager.default.removeItem(at: out)
  let writer = try! AVAssetWriter(outputURL: out, fileType: .mp4)
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
    AVVideoColorPropertiesKey: [
      AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
      AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
      AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
    // No B-frames: the Android emulator's decoder hands them out in decode order.
    AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]])
  if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
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
      let (r, g, b) = colors[(y < h / 2 ? 0 : 2) + (x < w / 2 ? 0 : 1)]
      let o = y * bpr + x * 4
      base[o] = b; base[o + 1] = g; base[o + 2] = r; base[o + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    adaptor.append(pb!, withPresentationTime: CMTime(value: Int64(i), timescale: 30))
  }
  input.markAsFinished()
  let done = DispatchSemaphore(value: 0)
  writer.finishWriting { done.signal() }; done.wait()
  print(path, writer.status == .completed ? "ok" : "failed \(String(describing: writer.error))")
}

let dir = CommandLine.arguments[1]
write("\(dir)/rotated90.mp4", 128, 64, [(220, 40, 40), (40, 220, 40), (40, 40, 220), (220, 220, 220)], rotated: true)
write("\(dir)/colors709.mp4", 1280, 720, [(40, 200, 60), (224, 172, 140), (200, 40, 40), (40, 60, 200)], rotated: false)
