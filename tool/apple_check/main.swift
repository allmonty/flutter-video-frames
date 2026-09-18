// Runs FrameReader/FrameWriter against real AVFoundation on macOS (the same
// framework the iOS plugin uses), without a device or simulator.
// Run: tool/apple_check.sh
import Foundation

func frame(_ w: Int, _ h: Int, _ i: Int) -> Data {
  var d = Data(count: w * h * 4)
  for y in 0..<h { for x in 0..<w {
    let q = (y < h / 2 ? 0 : 2) + (x < w / 2 ? 0 : 1)
    let o = (y * w + x) * 4
    d[o] = q == 0 ? 220 : UInt8((i * 8) % 256); d[o + 1] = q == 1 ? 220 : 40; d[o + 2] = q == 2 ? 220 : 40; d[o + 3] = 255
  } }
  return d
}

func check(_ ok: Bool, _ msg: String) { print((ok ? "PASS " : "FAIL ") + msg); if !ok { exit(1) } }

let path = NSTemporaryDirectory() + "vf_check.mp4"
let (w, h) = (320, 240)
let writer = try FrameWriter(path: path, width: w, height: h, frameRate: 30, bitRate: nil, audioSourcePath: nil)
for i in 0..<30 { try writer.addFrame(rgba: frame(w, h, i), ptsUs: Int64(i) * 33333) }
try writer.finish()
let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber).intValue
check(size > 1000, "wrote \(size) bytes")

let reader = try FrameReader(path: path, maxDimension: nil)
check(reader.width == w && reader.height == h, "size \(reader.width)x\(reader.height)")
check(!reader.hasAudio, "no audio")
check(reader.rotation == 0, "rotation 0")
var count = 0
var first: [UInt8]? = nil
var lastPts: Int64 = -1
while let f = try reader.next() { if first == nil { first = f.rgba }; check(f.ptsUs > lastPts, "pts increases \(f.ptsUs)"); lastPts = f.ptsUs; count += 1 }
check(count == 30, "decoded \(count) frames")
let o = ((h / 4) * w + w / 4) * 4
check(first![o] > 170 && first![o + 1] < 100, "top-left is red: \(first![o]),\(first![o+1]),\(first![o+2])")
let q = ((3 * h / 4) * w + w / 4) * 4
check(first![q + 2] > 170 && first![q] < 100, "bottom-left is blue: \(first![q]),\(first![q+1]),\(first![q+2])")
let mid = try reader.frame(atUs: 500_000)
check(abs(mid.ptsUs - 500_000) < 40_000, "frameAt ~500ms: \(mid.ptsUs)")
check(mid.rgba.count == w * h * 4, "frameAt size")
check(mid.rgba[o] > 170 && mid.rgba[o + 1] < 100, "frameAt top-left red (upright)")
reader.close()

let scaled = try FrameReader(path: path, maxDimension: 160)
check(scaled.width == 160 && scaled.height == 120, "scaled \(scaled.width)x\(scaled.height)")
let sf = try scaled.next()!
check(sf.rgba.count == 160 * 120 * 4, "scaled frame bytes")

// Rotation mapping on a synthetic BGRA buffer: 4x2, left half red, right blue.
var bgra = [UInt8](repeating: 0, count: 4 * 2 * 4)
for y in 0..<2 { for x in 0..<4 { let i = (y * 4 + x) * 4; if x < 2 { bgra[i + 2] = 255 } else { bgra[i] = 255 }; bgra[i + 3] = 255 } }
let rot = bgra.withUnsafeBufferPointer { PixelConversion.bgraToRgba($0.baseAddress!, srcWidth: 4, srcHeight: 2, bytesPerRow: 16, rotation: 90, dstWidth: 2, dstHeight: 4) }
check(rot[0] == 255 && rot[2] == 0, "rotate 90: top is red")
check(rot[(3 * 2) * 4 + 2] == 255, "rotate 90: bottom is blue")
check(PixelConversion.rotationDegrees(a: 0, b: 1) == 90 && PixelConversion.rotationDegrees(a: -1, b: 0) == 180 && PixelConversion.rotationDegrees(a: 0, b: -1) == 270, "rotation from transform")

let cancelPath = NSTemporaryDirectory() + "vf_cancel.mp4"
let cw = try FrameWriter(path: cancelPath, width: 64, height: 64, frameRate: 30, bitRate: nil, audioSourcePath: nil)
try cw.addFrame(rgba: frame(64, 64, 0), ptsUs: 0)
cw.cancel()
check(!FileManager.default.fileExists(atPath: cancelPath), "cancel deletes the file")
// Audio passthrough: needs an audio file; the script makes one with `say`.
if CommandLine.arguments.count > 1 {
  let audioPath = NSTemporaryDirectory() + "vf_audio.mp4"
  let aw = try FrameWriter(path: audioPath, width: 64, height: 64, frameRate: 10, bitRate: nil, audioSourcePath: CommandLine.arguments[1])
  for i in 0..<20 { try aw.addFrame(rgba: Data(repeating: UInt8(i * 10), count: 64 * 64 * 4), ptsUs: Int64(i) * 100_000) }
  try aw.finish()
  check(try FrameReader(path: audioPath, maxDimension: nil).hasAudio, "audio track copied")
}
print("ALL PASSED")
