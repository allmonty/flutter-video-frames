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

// Checks that need no video encoder.
// Error codes reported to Dart.
func code(_ body: () throws -> Any) -> String {
  do { _ = try body(); return "no error" } catch let e as VideoFramesError { return e.code } catch { return "\(error)" }
}
check(code { try FrameReader(path: "/nonexistent/video.mp4", maxDimension: nil) } == "fileNotFound", "missing file -> fileNotFound")
let notVideo = NSTemporaryDirectory() + "vf_not_a_video.mp4"
try "not a video".write(toFile: notVideo, atomically: true, encoding: .utf8)
check(code { try FrameReader(path: notVideo, maxDimension: nil) } == "unsupportedFormat", "non-video file -> unsupportedFormat")

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

// Everything below needs a working video encoder. GitHub's macOS runners are
// VMs without the Mac's media engine (encoding never starts there), so CI sets
// APPLE_CHECK_NO_ENCODER and runs only the checks above.
if ProcessInfo.processInfo.environment["APPLE_CHECK_NO_ENCODER"] != nil {
  print("ALL PASSED (checks that need no encoder; encoding skipped)")
  exit(0)
}

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

// HEVC: a round trip through the HEVC encoder (skipped on Macs without one, e.g. some CI VMs).
let hevcPath = NSTemporaryDirectory() + "vf_check_hevc.mp4"
do {
  let hevcWriter = try FrameWriter(path: hevcPath, width: w, height: h, frameRate: 30, bitRate: nil, audioSourcePath: nil, hevc: true)
  for i in 0..<10 { try hevcWriter.addFrame(rgba: frame(w, h, i), ptsUs: Int64(i) * 33333) }
  try hevcWriter.finish()
  let hevcFormat = AVURLAsset(url: URL(fileURLWithPath: hevcPath)).tracks(withMediaType: .video)[0].formatDescriptions[0] as! CMFormatDescription
  check(CMFormatDescriptionGetMediaSubType(hevcFormat) == kCMVideoCodecType_HEVC, "HEVC writer writes HEVC")
  let hevcReader = try FrameReader(path: hevcPath, maxDimension: nil)
  var hevcFrames = 0
  var hevcFirst: Data?
  while let f = try hevcReader.next() { hevcFirst = hevcFirst ?? f.rgba; hevcFrames += 1 }
  check(hevcFrames == 10, "HEVC decoded \(hevcFrames) frames")
  check(hevcFirst![o] > 170 && hevcFirst![o + 1] < 100, "HEVC top-left is red")
} catch let error as VideoFramesError where error.code == "codecUnsupported" {
  print("SKIP HEVC: \(error)")
}

// HDR (HLG / BT.2020, 10-bit HEVC) input: AVFoundation tone-maps it to SDR, and frameAt matches next().
let hlg = try FrameReader(path: "example/integration_test/assets/hlg.mp4", maxDimension: nil)
let hlgNext = try hlg.next()!.rgba
let hlgSeek = try hlg.frame(atUs: 0).rgba
let gray = ((270 * hlg.width + 480) * 4)
let (gr, gg, gb) = (Int(hlgNext[gray]), Int(hlgNext[gray + 1]), Int(hlgNext[gray + 2]))
check(abs(gr - gg) < 12 && abs(gg - gb) < 12 && gg > 60 && gg < 200, "HDR gray stays neutral and mid-range: \(gr) \(gg) \(gb)")
check(zip(hlgNext, hlgSeek).allSatisfy { abs(Int($0) - Int($1)) <= 12 }, "HDR frameAt matches next()")

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
var first: Data? = nil
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
try reader.seek(toUs: 500_000)
var seeked: [Int64] = []
while let f = try reader.next() { seeked.append(f.ptsUs) }
check(seeked.first.map { $0 >= 500_000 && $0 < 540_000 } == true, "seek: next frame at ~500ms: \(seeked.first ?? -1)")
check(seeked.count == 15 && zip(seeked, seeked.dropFirst()).allSatisfy { $0 < $1 }, "seek: then the rest in order (\(seeked.count))")
try reader.seek(toUs: 0)
check(try reader.next()?.ptsUs == 0, "seek back to the start")
try reader.seek(toUs: 5_000_000)
check(try reader.next() == nil, "seek past the end: no frame")
reader.close()

let scaled = try FrameReader(path: path, maxDimension: 160)
check(scaled.width == 160 && scaled.height == 120, "scaled \(scaled.width)x\(scaled.height)")
let sf = try scaled.next()!
check(sf.rgba.count == 160 * 120 * 4, "scaled frame bytes")

// frameAt and next() filter the same way.
let areaReader = try FrameReader(path: path, maxDimension: 160, filter: .area)
let viaNext = try areaReader.next()!.rgba
let viaSeek = try areaReader.frame(atUs: 0).rgba
check(viaSeek.count == viaNext.count, "frameAt size matches next() with a filter")
check(zip(viaNext, viaSeek).allSatisfy { abs(Int($0) - Int($1)) <= 10 }, "frameAt pixels match next() with area filtering")

let cancelPath = NSTemporaryDirectory() + "vf_cancel.mp4"
let cw = try FrameWriter(path: cancelPath, width: 64, height: 64, frameRate: 30, bitRate: nil, audioSourcePath: nil)
try cw.addFrame(rgba: frame(64, 64, 0), ptsUs: 0)
cw.cancel()
check(!FileManager.default.fileExists(atPath: cancelPath), "cancel deletes the file")
// Audio passthrough, from a generated one-second tone as AAC (.m4a) and PCM (.aiff).
func writeTone(_ path: String, _ settings: [String: Any]) throws {
  try? FileManager.default.removeItem(atPath: path)
  let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
  buffer.frameLength = 44_100
  for i in 0..<44_100 { buffer.floatChannelData![0][i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / 44_100) }
  let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings)
  try file.write(from: buffer)
}
let aacPath = NSTemporaryDirectory() + "vf_tone.m4a"
let aiffPath = NSTemporaryDirectory() + "vf_tone.aiff"
try writeTone(aacPath, [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
try writeTone(aiffPath, [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
  AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsFloatKey: false])
do {
  let audioPath = NSTemporaryDirectory() + "vf_audio.mp4"
  let aw = try FrameWriter(path: audioPath, width: 64, height: 64, frameRate: 10, bitRate: nil, audioSourcePath: aacPath)
  for i in 0..<20 { try aw.addFrame(rgba: Data(repeating: UInt8(i * 10), count: 64 * 64 * 4), ptsUs: Int64(i) * 100_000) }
  try aw.finish()
  check(aw.audioIncluded, "writer reports AAC audio included")
  let withAudio = try FrameReader(path: audioPath, maxDimension: nil)
  check(withAudio.hasAudio, "audio track copied")
  check(withAudio.audioCompatible, "copied AAC audio reported compatible")

  // Compatibility of the source formats themselves.
  let aac = AVURLAsset(url: URL(fileURLWithPath: aacPath)).tracks(withMediaType: .audio).first!
  check(AudioSupport.canCopyIntoMp4(aac), "AAC can be copied into an MP4")
  do {
    let pcmPath = aiffPath
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

  // A real-length clip: AVAssetWriter interleaves audio with video, so it stops taking frames once the video is about
  // a second ahead of the audio, and holds the last ones until the audio track is marked finished. Audio copied only
  // at finish() stalled here.
  let longPath = NSTemporaryDirectory() + "vf_long_audio.mp4"
  let lw = try FrameWriter(
    path: longPath, width: 720, height: 1280, frameRate: 24, bitRate: nil,
    audioSourcePath: "example/integration_test/assets/tone8.mp4")
  let gray = Data(repeating: 128, count: 720 * 1280 * 4)
  let written = code {
    for i in 0..<192 { try lw.addFrame(rgba: gray, ptsUs: Int64(i) * 1_000_000 / 24) }
    return try lw.finish()
  }
  check(written == "no error", "8 s of 720x1280 frames with 8 s of audio: \(written)")
  let long = AVURLAsset(url: URL(fileURLWithPath: longPath))
  let audioSeconds = long.tracks(withMediaType: .audio).first.map { CMTimeGetSeconds($0.timeRange.duration) } ?? 0
  check(abs(audioSeconds - 8) < 0.1, "the whole audio track copied: \(audioSeconds) s")

  // Sound as PCM: decoded from a file, encoded to AAC by the writer, and clips joined without re-encoding.
  let decoded = try AudioMedia.decode(path: "example/integration_test/assets/tone8.mp4")!
  let decodedSeconds = Double(decoded.data.count / 2 / decoded.channels) / Double(decoded.sampleRate)
  check(decoded.sampleRate == 44_100 && decoded.channels == 1, "tone decoded at \(decoded.sampleRate) Hz, \(decoded.channels) ch")
  check(abs(decodedSeconds - 8) < 0.1, "the whole tone decoded: \(decodedSeconds) s")
  let peak = stride(from: 0, to: decoded.data.count - 1, by: 2).reduce(0) { m, i in
    max(m, abs(Int(Int16(bitPattern: UInt16(decoded.data[i]) | UInt16(decoded.data[i + 1]) << 8))))
  }
  check(peak > 3000, "the tone is heard, not silence (peak \(peak))")
  check(try AudioMedia.decode(path: path) == nil, "a video without sound decodes to nothing")
  check(code { try AudioMedia.decode(path: "/nonexistent.mp4") as Any } == "fileNotFound", "decoding a missing file -> fileNotFound")

  func pcmClip(_ name: String, seconds: Int, rate: Int, channels: Int) throws -> String {
    var pcm = Data(count: seconds * rate * channels * 2)
    pcm.withUnsafeMutableBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      for i in 0..<samples.count { samples[i] = Int16(8000 * sin(Double(i / channels) * 2 * .pi * 440 / Double(rate))) }
    }
    let out = NSTemporaryDirectory() + name
    let pw = try FrameWriter(
      path: out, width: 64, height: 64, frameRate: 24, bitRate: nil, audioSourcePath: nil,
      audio: Pcm(data: pcm, sampleRate: rate, channels: channels))
    check(pw.audioIncluded, "\(name): the writer encodes the PCM")
    for i in 0..<(seconds * 24) { try pw.addFrame(rgba: Data(repeating: UInt8(i % 256), count: 64 * 64 * 4), ptsUs: Int64(i) * 1_000_000 / 24) }
    try pw.finish()
    return out
  }
  let stereo = try pcmClip("vf_pcm_stereo.mp4", seconds: 3, rate: 48_000, channels: 2)
  let mono = try pcmClip("vf_pcm_mono.mp4", seconds: 1, rate: 24_000, channels: 1)
  for (clip, seconds) in [(stereo, 3.0), (mono, 1.0)] {
    let a = AVURLAsset(url: URL(fileURLWithPath: clip)).tracks(withMediaType: .audio).first
    let d = a.map { CMTimeGetSeconds($0.timeRange.duration) } ?? 0
    check(abs(d - seconds) < 0.1, "PCM written as \(seconds) s of AAC: \(d) s")
  }
  let back = try AudioMedia.decode(path: stereo)!
  check(back.sampleRate == 48_000 && back.channels == 2, "the AAC decodes back at 48 kHz stereo")

  let joined = NSTemporaryDirectory() + "vf_joined.mp4"
  try AudioMedia.concat(inputs: [stereo, stereo], output: joined)
  let j = AVURLAsset(url: URL(fileURLWithPath: joined))
  check(abs(CMTimeGetSeconds(j.duration) - 6) < 0.15, "two 3 s clips joined: \(CMTimeGetSeconds(j.duration)) s")
  check(!j.tracks(withMediaType: .audio).isEmpty && !j.tracks(withMediaType: .video).isEmpty, "the join keeps picture and sound")
  var joinedFrames = 0
  let jr = try FrameReader(path: joined, maxDimension: nil)
  while try jr.next() != nil { joinedFrames += 1 }
  check(joinedFrames == 144, "every frame of both clips is there: \(joinedFrames)")
  check(code { try AudioMedia.concat(inputs: [], output: joined) } == "writeFailed", "joining nothing -> writeFailed")
  check(code { try AudioMedia.concat(inputs: ["/nonexistent.mp4"], output: joined) } == "fileNotFound", "joining a missing file -> fileNotFound")
}
print("ALL PASSED")
