// Renders doc/before_after.png for the README: a drawn scene encoded to MP4
// with the plugin's FrameWriter, decoded with FrameReader, then shown as is,
// in grayscale and inverted (the example app's filters).
// Run: tool/make_readme_image.sh
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let (w, h) = (480, 270)

/// The scene as RGBA: sky gradient, sun, two hill ranges.
func scene() -> Data {
  var data = Data(count: w * h * 4)
  data.withUnsafeMutableBytes { buffer in
    let ctx = CGContext(
      data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let sky = CGGradient(
      colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      colors: [CGColor(red: 0.98, green: 0.62, blue: 0.30, alpha: 1), CGColor(red: 0.36, green: 0.22, blue: 0.62, alpha: 1)] as CFArray,
      locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
    ctx.setFillColor(CGColor(red: 1, green: 0.88, blue: 0.45, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 300, y: 150, width: 80, height: 80))
    for (color, base, peaks) in [
      (CGColor(red: 0.20, green: 0.42, blue: 0.40, alpha: 1), 95.0, [(0.0, 60.0), (120.0, 135.0), (260.0, 70.0), (380.0, 120.0), (480.0, 65.0)]),
      (CGColor(red: 0.10, green: 0.24, blue: 0.22, alpha: 1), 40.0, [(0.0, 30.0), (90.0, 75.0), (210.0, 35.0), (340.0, 90.0), (480.0, 40.0)]),
    ] {
      ctx.setFillColor(color)
      ctx.move(to: CGPoint(x: 0, y: 0))
      for (x, y) in peaks { ctx.addLine(to: CGPoint(x: x, y: y + base - 40)) }
      ctx.addLine(to: CGPoint(x: Double(w), y: 0))
      ctx.fillPath()
    }
  }
  // A bitmap context's memory is top row first, like frames.
  return data
}

// Through the plugin: encode a short clip, decode its first frame.
let path = NSTemporaryDirectory() + "readme_scene.mp4"
let writer = try FrameWriter(path: path, width: w, height: h, frameRate: 30, bitRate: 4_000_000, audioSourcePath: nil)
let frame = scene()
for i in 0..<5 { try writer.addFrame(rgba: frame, ptsUs: Int64(i) * 33333) }
try writer.finish()
let decoded = try FrameReader(path: path, maxDimension: nil).next()!.rgba

// The example app's filters (example/lib/filters.dart).
func grayscale(_ d: Data) -> Data {
  var out = d
  for i in stride(from: 0, to: out.count, by: 4) {
    let r = 54 * Int(out[i]), g = 183 * Int(out[i + 1]), b = 19 * Int(out[i + 2])
    let y = UInt8((r + g + b) >> 8)
    out[i] = y; out[i + 1] = y; out[i + 2] = y
  }
  return out
}
func invert(_ d: Data) -> Data {
  var out = d
  for i in stride(from: 0, to: out.count, by: 4) { out[i] = 255 - out[i]; out[i + 1] = 255 - out[i + 1]; out[i + 2] = 255 - out[i + 2] }
  return out
}

// Three panels side by side with a gap.
let gap = 8
let panels = [decoded, grayscale(decoded), invert(decoded)]
let outW = w * 3 + gap * 2
var sheet = Data(repeating: 255, count: outW * h * 4)
for (p, panel) in panels.enumerated() {
  for y in 0..<h {
    let dst = (y * outW + p * (w + gap)) * 4
    sheet.replaceSubrange(dst..<(dst + w * 4), with: panel[(y * w * 4)..<((y + 1) * w * 4)])
  }
}
let provider = CGDataProvider(data: sheet as CFData)!
let image = CGImage(
  width: outW, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outW * 4,
  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
print(CGImageDestinationFinalize(dest) ? "wrote \(out.path)" : "failed")
