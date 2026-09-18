import Foundation

/// Pure pixel conversions between the BGRA buffers AVFoundation uses and the
/// RGBA frames of the Dart API. No Flutter or UIKit, so it is unit-testable
/// anywhere Swift runs.
enum PixelConversion {
  /// Size of a `srcWidth x srcHeight` frame after rotating by `rotation`
  /// degrees (0/90/180/270) and scaling down so neither edge exceeds
  /// `maxDimension` (when given).
  static func outputSize(srcWidth: Int, srcHeight: Int, rotation: Int, maxDimension: Int?) -> (Int, Int) {
    var w = rotation % 180 == 0 ? srcWidth : srcHeight
    var h = rotation % 180 == 0 ? srcHeight : srcWidth
    if let maxDimension = maxDimension, maxDimension > 0 {
      let longest = max(w, h)
      if longest > maxDimension {
        let scale = Double(maxDimension) / Double(longest)
        w = max(1, Int((Double(w) * scale).rounded()))
        h = max(1, Int((Double(h) * scale).rounded()))
      }
    }
    return (w, h)
  }

  /// Rotation in degrees (0/90/180/270, clockwise) encoded by a track's
  /// `preferredTransform` matrix components.
  static func rotationDegrees(a: Double, b: Double) -> Int {
    let degrees = Int((atan2(b, a) * 180 / Double.pi).rounded())
    return ((degrees % 360) + 360) % 360
  }

  /// BGRA (`bytesPerRow` may include padding) to a tightly packed RGBA frame
  /// of `dstWidth x dstHeight`, rotated clockwise by `rotation` degrees,
  /// with nearest-neighbour scaling.
  static func bgraToRgba(
    _ src: UnsafePointer<UInt8>,
    srcWidth: Int,
    srcHeight: Int,
    bytesPerRow: Int,
    rotation: Int,
    dstWidth: Int,
    dstHeight: Int
  ) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: dstWidth * dstHeight * 4)
    let rotW = rotation % 180 == 0 ? srcWidth : srcHeight
    let rotH = rotation % 180 == 0 ? srcHeight : srcWidth
    out.withUnsafeMutableBufferPointer { dst in
      var o = 0
      for dy in 0..<dstHeight {
        let ry = dy * rotH / dstHeight
        for dx in 0..<dstWidth {
          let rx = dx * rotW / dstWidth
          // Undo the clockwise rotation to find the source pixel.
          let sx: Int
          let sy: Int
          switch rotation {
          case 90: sx = ry; sy = srcHeight - 1 - rx
          case 180: sx = srcWidth - 1 - rx; sy = srcHeight - 1 - ry
          case 270: sx = srcWidth - 1 - ry; sy = rx
          default: sx = rx; sy = ry
          }
          let i = sy * bytesPerRow + sx * 4
          dst[o] = src[i + 2]
          dst[o + 1] = src[i + 1]
          dst[o + 2] = src[i]
          dst[o + 3] = 255
          o += 4
        }
      }
    }
    return out
  }

  /// Tightly packed RGBA to BGRA rows of `bytesPerRow` (e.g. a pixel
  /// buffer), with opaque alpha.
  static func rgbaToBgra(
    _ rgba: UnsafePointer<UInt8>,
    width: Int,
    height: Int,
    into dst: UnsafeMutablePointer<UInt8>,
    bytesPerRow: Int
  ) {
    for y in 0..<height {
      var i = y * width * 4
      var o = y * bytesPerRow
      for _ in 0..<width {
        dst[o] = rgba[i + 2]
        dst[o + 1] = rgba[i + 1]
        dst[o + 2] = rgba[i]
        dst[o + 3] = 255
        i += 4
        o += 4
      }
    }
  }
}
