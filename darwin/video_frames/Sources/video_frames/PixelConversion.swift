import Accelerate
import Foundation

/// Pure pixel conversions between the BGRA buffers AVFoundation uses and the
/// RGBA frames of the Dart API. No Flutter or UIKit (Accelerate only), so it
/// is unit-testable on macOS.
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

  /// Downscaling filters, in the order of the Dart `ScaleFilter` enum (the
  /// plugin maps them by raw value; this file can't see the Pigeon types).
  enum Filter: Int {
    case nearest, bilinear, area
  }

  /// BGRA (`bytesPerRow` may include padding) to a tightly packed RGBA frame
  /// of `dstWidth x dstHeight`, rotated clockwise by `rotation` degrees and
  /// scaled down with `filter`.
  static func bgraToRgba(
    _ src: UnsafePointer<UInt8>,
    srcWidth: Int,
    srcHeight: Int,
    bytesPerRow: Int,
    rotation: Int,
    dstWidth: Int,
    dstHeight: Int,
    filter: Filter = .nearest
  ) -> Data {
    // Data, not [UInt8]: the plugin hands it to Flutter without another copy.
    var out = Data(count: dstWidth * dstHeight * 4)
    let rotW = rotation % 180 == 0 ? srcWidth : srcHeight
    let rotH = rotation % 180 == 0 ? srcHeight : srcWidth
    out.withUnsafeMutableBytes { dst in
      if rotW == dstWidth && rotH == dstHeight {
        rotateAndSwap(
          src, srcWidth: srcWidth, srcHeight: srcHeight, bytesPerRow: bytesPerRow,
          rotation: rotation, into: dst.baseAddress!, width: dstWidth, height: dstHeight)
        return
      }
      // Scale first (at the unrotated size, so fewer pixels get rotated), then rotate.
      let scaledW = rotation % 180 == 0 ? dstWidth : dstHeight
      let scaledH = rotation % 180 == 0 ? dstHeight : dstWidth
      var scaled = [UInt8](repeating: 0, count: scaledW * scaledH * 4)
      scaled.withUnsafeMutableBufferPointer { buffer in
        scale(
          src, srcWidth: srcWidth, srcHeight: srcHeight, bytesPerRow: bytesPerRow, filter: filter,
          into: buffer.baseAddress!, width: scaledW, height: scaledH)
        rotateAndSwap(
          buffer.baseAddress!, srcWidth: scaledW, srcHeight: scaledH, bytesPerRow: scaledW * 4,
          rotation: rotation, into: dst.baseAddress!, width: dstWidth, height: dstHeight)
      }
    }
    return out
  }

  /// Scale 4-byte pixels (any channel order) down to a tightly packed
  /// `width x height` buffer.
  static func scale(
    _ src: UnsafePointer<UInt8>,
    srcWidth: Int,
    srcHeight: Int,
    bytesPerRow: Int,
    filter: Filter,
    into dst: UnsafeMutablePointer<UInt8>,
    width: Int,
    height: Int
  ) {
    switch filter {
    case .nearest:
      // Sample each output pixel's center, like GL_NEAREST on Android.
      let xs = (0..<width).map { min(srcWidth - 1, (2 * $0 + 1) * srcWidth / (2 * width)) * 4 }
      for y in 0..<height {
        let row = src + min(srcHeight - 1, (2 * y + 1) * srcHeight / (2 * height)) * bytesPerRow
        var o = y * width * 4
        for x in xs {
          for c in 0..<4 { dst[o + c] = row[x + c] }
          o += 4
        }
      }
    case .bilinear:
      // Fixed-point weights out of 256, sampling at each output pixel's center.
      func taps(_ dstLen: Int, _ srcLen: Int) -> [(Int, Int, Int)] {
        (0..<dstLen).map { i in
          let f = max(0, (Double(i) + 0.5) * Double(srcLen) / Double(dstLen) - 0.5)
          let i0 = min(Int(f), srcLen - 1)
          return (i0, min(i0 + 1, srcLen - 1), Int((f - Double(i0)) * 256))
        }
      }
      let xs = taps(width, srcWidth)
      for (y, (y0, y1, wy)) in taps(height, srcHeight).enumerated() {
        let r0 = src + y0 * bytesPerRow
        let r1 = src + y1 * bytesPerRow
        var o = y * width * 4
        for (x0, x1, wx) in xs {
          for c in 0..<4 {
            let top = Int(r0[x0 * 4 + c]) * (256 - wx) + Int(r0[x1 * 4 + c]) * wx
            let bottom = Int(r1[x0 * 4 + c]) * (256 - wx) + Int(r1[x1 * 4 + c]) * wx
            dst[o + c] = UInt8((top * (256 - wy) + bottom * wy + 32768) >> 16)
          }
          o += 4
        }
      }
    case .area:
      // Exact box average of the source pixels each output pixel covers.
      func spans(_ dstLen: Int, _ srcLen: Int) -> [Range<Int>] {
        (0..<dstLen).map { i in
          let lo = i * srcLen / dstLen
          return lo..<max(lo + 1, (i + 1) * srcLen / dstLen)
        }
      }
      let xs = spans(width, srcWidth)
      for (y, rows) in spans(height, srcHeight).enumerated() {
        var o = y * width * 4
        for cols in xs {
          var sum = (0, 0, 0, 0)
          for sy in rows {
            let row = src + sy * bytesPerRow
            for sx in cols {
              sum.0 += Int(row[sx * 4]); sum.1 += Int(row[sx * 4 + 1])
              sum.2 += Int(row[sx * 4 + 2]); sum.3 += Int(row[sx * 4 + 3])
            }
          }
          let n = rows.count * cols.count
          dst[o] = UInt8((sum.0 + n / 2) / n); dst[o + 1] = UInt8((sum.1 + n / 2) / n)
          dst[o + 2] = UInt8((sum.2 + n / 2) / n); dst[o + 3] = UInt8((sum.3 + n / 2) / n)
          o += 4
        }
      }
    }
  }

  /// Full-size path with Accelerate: rotate clockwise by `rotation`, then
  /// swap BGRA to RGBA (or back; the swap is its own inverse) in place, with
  /// opaque alpha. `dst` is `width x height`, tightly packed.
  private static func rotateAndSwap(
    _ src: UnsafePointer<UInt8>,
    srcWidth: Int,
    srcHeight: Int,
    bytesPerRow: Int,
    rotation: Int,
    into dst: UnsafeMutableRawPointer,
    width: Int,
    height: Int
  ) {
    var source = vImage_Buffer(
      data: UnsafeMutableRawPointer(mutating: src), height: vImagePixelCount(srcHeight),
      width: vImagePixelCount(srcWidth), rowBytes: bytesPerRow)
    var target = vImage_Buffer(
      data: dst, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
    if rotation == 0 {
      swapRedBlue(source, target)
    } else {
      // vImage counts quarter turns counterclockwise.
      let turns: UInt8 = rotation == 90 ? 3 : rotation == 180 ? 2 : 1
      var black: [UInt8] = [0, 0, 0, 255]
      vImageRotate90_ARGB8888(&source, &target, turns, &black, vImage_Flags(kvImageNoFlags))
      swapRedBlue(target, target)
    }
  }

  /// BGRA <-> RGBA with alpha forced opaque.
  private static func swapRedBlue(_ source: vImage_Buffer, _ target: vImage_Buffer) {
    // Separate copies of the descriptors: vImage works in place, Swift forbids aliased inouts.
    var (source, target, result) = (source, target, target)
    let map: [UInt8] = [2, 1, 0, 3]
    vImagePermuteChannels_ARGB8888(&source, &target, map, vImage_Flags(kvImageNoFlags))
    // The 4th byte is alpha; vImage's channel mask names it 0x1.
    vImageOverwriteChannelsWithScalar_ARGB8888(255, &target, &result, 0x1, vImage_Flags(kvImageNoFlags))
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
    let source = vImage_Buffer(
      data: UnsafeMutableRawPointer(mutating: rgba), height: vImagePixelCount(height),
      width: vImagePixelCount(width), rowBytes: width * 4)
    let target = vImage_Buffer(
      data: dst, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
    swapRedBlue(source, target)
  }
}
