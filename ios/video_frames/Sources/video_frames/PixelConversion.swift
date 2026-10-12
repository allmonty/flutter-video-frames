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
    if rotW == dstWidth && rotH == dstHeight {
      out.withUnsafeMutableBytes { dst in
        rotateAndSwap(
          src, srcWidth: srcWidth, srcHeight: srcHeight, bytesPerRow: bytesPerRow,
          rotation: rotation, into: dst.baseAddress!, width: dstWidth, height: dstHeight)
      }
      return out
    }
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
