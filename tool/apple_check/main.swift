// Runs FrameReader/FrameWriter against real AVFoundation on macOS (the same
// framework the iOS plugin uses), without a device or simulator.
// Run: tool/apple_check.sh
import AVFoundation
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
let format = AVURLAsset(url: URL(fileURLWithPath: path)).tracks(withMediaType: .video)[0].formatDescriptions[0] as! CMFormatDescription
let matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
check(matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String), "output tagged BT.709 (\(matrix ?? "untagged"))")

// HD colors that shift by 20+ under a 601/709 mix-up survive a round trip.
let hdColors: [(UInt8, UInt8, UInt8)] = [(40, 200, 60), (224, 172, 140), (200, 40, 40), (40, 60, 200)]
let (hw, hh) = (1280, 720)
var hd = Data(count: hw * hh * 4)
for y in 0..<hh { for x in 0..<hw {
  let (r, g, b) = hdColors[(y < hh / 2 ? 0 : 2) + (x < hw / 2 ? 0 : 1)]
  let o = (y * hw + x) * 4
  hd[o] = r; hd[o + 1] = g; hd[o + 2] = b; hd[o + 3] = 255
} }
let hdPath = NSTemporaryDirectory() + "vf_check_hd.mp4"
let hdWriter = try FrameWriter(path: hdPath, width: hw, height: hh, frameRate: 30, bitRate: nil, audioSourcePath: nil)
for i in 0..<5 { try hdWriter.addFrame(rgba: hd, ptsUs: Int64(i) * 33333) }
try hdWriter.finish()
let hdFrame = try FrameReader(path: hdPath, maxDimension: nil).next()!.rgba
for (q, (r, g, b)) in hdColors.enumerated() {
  let o = ((q < 2 ? hh / 4 : hh * 3 / 4) * hw + (q % 2 == 0 ? hw / 4 : hw * 3 / 4)) * 4
  let got = (Int(hdFrame[o]), Int(hdFrame[o + 1]), Int(hdFrame[o + 2]))
  check(abs(got.0 - Int(r)) <= 12 && abs(got.1 - Int(g)) <= 12 && abs(got.2 - Int(b)) <= 12, "HD color \((r, g, b)) -> \(got)")
}
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

// Scale filters on 8x2 stripes (columns 0,255,0,0,0,255,0,0) down to 2x1: each filter gives a different value.
let stripes = (0..<2).flatMap { _ in [0, 255, 0, 0, 0, 255, 0, 0].flatMap { v in [UInt8](repeating: UInt8(v), count: 4) } }
func scaled(_ filter: PixelConversion.Filter) -> UInt8 {
  var out = [UInt8](repeating: 0, count: 2 * 4)
  stripes.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { dst in
    PixelConversion.scale(src.baseAddress!, srcWidth: 8, srcHeight: 2, bytesPerRow: 32, filter: filter, into: dst.baseAddress!, width: 2, height: 1)
  } }
  return out[0]
}
check(scaled(.nearest) == 0, "nearest samples the center pixel: \(scaled(.nearest))")
check(scaled(.bilinear) == 128, "bilinear blends the two center pixels: \(scaled(.bilinear))")
check(scaled(.area) == 64, "area averages the whole block: \(scaled(.area))")

// frameAt (image generator) and next() (asset reader) filter the same way.
let areaReader = try FrameReader(path: path, maxDimension: 160, filter: .area)
let viaNext = try areaReader.next()!.rgba
let viaSeek = try areaReader.frame(atUs: 0).rgba
check(viaSeek.count == viaNext.count, "frameAt size matches next() with a filter")
check(zip(viaNext, viaSeek).allSatisfy { abs(Int($0) - Int($1)) <= 10 }, "frameAt pixels match next() with area filtering")

// Rotation mapping on a synthetic BGRA buffer: 4x2, left half red, right blue.
var bgra = [UInt8](repeating: 0, count: 4 * 2 * 4)
for y in 0..<2 { for x in 0..<4 { let i = (y * 4 + x) * 4; if x < 2 { bgra[i + 2] = 255 } else { bgra[i] = 255 }; bgra[i + 3] = 255 } }
let rot = bgra.withUnsafeBufferPointer { PixelConversion.bgraToRgba($0.baseAddress!, srcWidth: 4, srcHeight: 2, bytesPerRow: 16, rotation: 90, dstWidth: 2, dstHeight: 4) }
check(rot[0] == 255 && rot[2] == 0, "rotate 90: top is red")
check(rot[(3 * 2) * 4 + 2] == 255, "rotate 90: bottom is blue")
let rot180 = bgra.withUnsafeBufferPointer { PixelConversion.bgraToRgba($0.baseAddress!, srcWidth: 4, srcHeight: 2, bytesPerRow: 16, rotation: 180, dstWidth: 4, dstHeight: 2) }
check(rot180[2] == 255 && rot180[3 * 4] == 255, "rotate 180: left is blue, right is red")
let rot270 = bgra.withUnsafeBufferPointer { PixelConversion.bgraToRgba($0.baseAddress!, srcWidth: 4, srcHeight: 2, bytesPerRow: 16, rotation: 270, dstWidth: 2, dstHeight: 4) }
check(rot270[2] == 255 && rot270[(3 * 2) * 4] == 255, "rotate 270: top is blue, bottom is red")
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
  check(aw.audioIncluded, "writer reports AAC audio included")
  let withAudio = try FrameReader(path: audioPath, maxDimension: nil)
  check(withAudio.hasAudio, "audio track copied")
  check(withAudio.audioCompatible, "copied AAC audio reported compatible")

  // Compatibility of the source formats themselves.
  let aac = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1])).tracks(withMediaType: .audio).first!
  check(AudioSupport.canCopyIntoMp4(aac), "AAC can be copied into an MP4")
  if CommandLine.arguments.count > 2 {
    let pcmPath = CommandLine.arguments[2]
    let pcm = AVURLAsset(url: URL(fileURLWithPath: pcmPath)).tracks(withMediaType: .audio).first!
    // AVFoundation accepts PCM passthrough into an MP4 (Apple players handle
    // it), so on iOS it counts as compatible and is written.
    check(AudioSupport.canCopyIntoMp4(pcm), "AVFoundation accepts PCM (AIFF) passthrough")
    let pcmOut = NSTemporaryDirectory() + "vf_pcm.mp4"
    let pw = try FrameWriter(path: pcmOut, width: 64, height: 64, frameRate: 10, bitRate: nil, audioSourcePath: pcmPath)
    check(pw.audioIncluded, "writer includes the PCM audio")
    for i in 0..<5 { try pw.addFrame(rgba: Data(repeating: 128, count: 64 * 64 * 4), ptsUs: Int64(i) * 100_000) }
    try pw.finish()
    check(try FrameReader(path: pcmOut, maxDimension: nil).hasAudio, "PCM audio written")

    // A source without audio: nothing to copy, and the export still works.
    let silentPath = NSTemporaryDirectory() + "vf_silent.mp4"
    let sw = try FrameWriter(path: silentPath, width: 64, height: 64, frameRate: 10, bitRate: nil, audioSourcePath: path)
    check(!sw.audioIncluded, "a source without audio adds no track")
    for i in 0..<5 { try sw.addFrame(rgba: Data(repeating: 128, count: 64 * 64 * 4), ptsUs: Int64(i) * 100_000) }
    try sw.finish()
    let silent = try FrameReader(path: silentPath, maxDimension: nil)
    check(!silent.hasAudio && !silent.audioCompatible, "video saved without sound")
  }
}
print("ALL PASSED")
