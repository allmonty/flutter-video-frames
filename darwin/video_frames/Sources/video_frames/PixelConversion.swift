import Accelerate
import Foundation

/// Pure pixel conversions between the BGRA buffers AVFoundation uses and the
/// RGBA frames of the Dart API. No Flutter or UIKit (Accelerate only), so it
/// is unit-testable on macOS.
enum PixelConversion {
  /// Size of a `srcWidth x srcHeight` frame after rotating by `rotation`
  /// degrees (0/90/180/270) and scaling down so neither edge exceeds
  /// `maxDimension` (when given).
  static func outputSize(srcWidth: Int, srcHeight: Int, rotation: Int, maxDimension: Int?, upscale: Bool = false) -> (Int, Int) {
    var w = rotation % 180 == 0 ? srcWidth : srcHeight
    var h = rotation % 180 == 0 ? srcHeight : srcWidth
    if let maxDimension = maxDimension, maxDimension > 0 {
      let longest = max(w, h)
      if longest > maxDimension || (upscale && longest < maxDimension) {
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

  /// Scaling filters, in the order of the Dart `ScaleFilter` enum (the
  /// plugin maps them by raw value; this file can't see the Pigeon types).
  enum Filter: Int {
    case nearest, bilinear, area, bicubic, lanczos
  }

  /// BGRA (`bytesPerRow` may include padding) to a tightly packed RGBA frame
  /// of `dstWidth x dstHeight`, rotated clockwise by `rotation` degrees and
  /// scaled with `filter`.
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

  /// Scale 4-byte pixels (any channel order) to a tightly packed
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
    // Enlarging, an area average would copy single pixels; blend like Android's area shader does then.
    let filter = filter == .area && max(width, height) > max(srcWidth, srcHeight) ? .bilinear : filter
    let kernels: [Filter: Kernel] = [.bilinear: .tent, .bicubic: .catmullRom, .lanczos: .lanczos3]
    if width >= srcWidth && height >= srcHeight, let kernel = kernels[filter] {
      enlarge(
        src, srcWidth: srcWidth, srcHeight: srcHeight, bytesPerRow: bytesPerRow,
        into: dst, width: width, height: height, kernel: kernel)
      return
    }
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
    case .bicubic:
      resample(
        src, srcWidth: srcWidth, srcHeight: srcHeight, bytesPerRow: bytesPerRow,
        into: dst, width: width, height: height, support: 2, kernel: catmullRom)
    case .lanczos:
      resample(
        src, srcWidth: srcWidth, srcHeight: srcHeight, bytesPerRow: bytesPerRow,
        into: dst, width: width, height: height, support: 3, kernel: lanczos3)
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

  /// The kernels `enlarge` hands to vImage.
  enum Kernel {
    case tent, catmullRom, lanczos3

    /// Half-width in source pixels: vImage reads x from -halfWidth to halfWidth.
    var halfWidth: Float {
      switch self {
      case .tent: return 1
      case .catmullRom: return 2
      case .lanczos3: return 3
      }
    }

    /// vImage samples the kernel itself; each window is normalized to 1, like `kernelTaps`.
    var function: @convention(c) (UnsafePointer<Float>?, UnsafeMutablePointer<Float>?, UInt, UnsafeMutableRawPointer?) -> Void {
      switch self {
      case .tent: return { xs, ys, n, _ in PixelConversion.fill(xs, ys, n) { max(0, 1 - abs($0)) } }
      case .catmullRom: return { xs, ys, n, _ in PixelConversion.fill(xs, ys, n, PixelConversion.catmullRom) }
      case .lanczos3: return { xs, ys, n, _ in PixelConversion.fill(xs, ys, n, PixelConversion.lanczos3) }
      }
    }
  }

  fileprivate static func fill(
    _ xs: UnsafePointer<Float>?, _ ys: UnsafeMutablePointer<Float>?, _ n: UInt, _ k: (Double) -> Double
  ) {
    guard let xs = xs, let ys = ys, n > 0 else { return }
    var sum: Float = 0
    for i in 0..<Int(n) {
      ys[i] = Float(k(Double(xs[i])))
      sum += ys[i]
    }
    if sum != 0 { for i in 0..<Int(n) { ys[i] /= sum } }
  }

  /// Enlarge with vImage's shears (one axis at a time, any kernel): about 3x faster than the Swift loops of
  /// `resample`. Pixel centers line up as in `kernelTaps`, and edges extend.
  static func enlarge(
    _ src: UnsafePointer<UInt8>,
    srcWidth: Int,
    srcHeight: Int,
    bytesPerRow: Int,
    into dst: UnsafeMutablePointer<UInt8>,
    width: Int,
    height: Int,
    kernel: Kernel
  ) {
    let sx = Float(width) / Float(srcWidth), sy = Float(height) / Float(srcHeight)
    func makeFilter(_ scale: Float) -> ResamplingFilter {
      let size = vImageGetResamplingFilterSize(scale, kernel.function, kernel.halfWidth, vImage_Flags(kvImageNoFlags))
      let filter = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
      vImageNewResamplingFilterForFunctionUsingBuffer(
        filter, scale, kernel.function, kernel.halfWidth, nil, vImage_Flags(kvImageNoFlags))
      return filter
    }
    let xFilter = makeFilter(sx), yFilter = makeFilter(sy)
    defer {
      xFilter.deallocate()
      yFilter.deallocate()
    }
    // In floats from end to end, as `resample` does: the kernels overshoot, and clipping to 0...255 between the two
    // passes would change the result (by up to ~35 levels on noise, measured). An interleaved 4-channel row is also a
    // planar row 4 times as wide, which is how the 8-bit <-> float conversions read it. vImage writes every element, so
    // the buffers aren't zeroed first (that took about a quarter of the time).
    func floats(_ count: Int) -> [Float] { [Float](unsafeUninitializedCapacity: count) { _, n in n = count } }
    var input = floats(srcWidth * 4 * srcHeight)
    var rows = floats(width * 4 * srcHeight)
    var output = floats(width * 4 * height)
    var black: [Float] = [0, 0, 0, 0]
    input.withUnsafeMutableBytes { i in
      rows.withUnsafeMutableBytes { r in
        output.withUnsafeMutableBytes { o in
          var source = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: src), height: vImagePixelCount(srcHeight),
            width: vImagePixelCount(srcWidth * 4), rowBytes: bytesPerRow)
          var sourceF = vImage_Buffer(
            data: i.baseAddress!, height: vImagePixelCount(srcHeight), width: vImagePixelCount(srcWidth),
            rowBytes: srcWidth * 16)
          var rowsF = vImage_Buffer(
            data: r.baseAddress!, height: vImagePixelCount(srcHeight), width: vImagePixelCount(width), rowBytes: width * 16)
          var outputF = vImage_Buffer(
            data: o.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 16)
          var target = vImage_Buffer(
            data: dst, height: vImagePixelCount(height), width: vImagePixelCount(width * 4), rowBytes: width * 4)
          var sourcePlanar = sourceF
          sourcePlanar.width = vImagePixelCount(srcWidth * 4)
          vImageConvert_Planar8toPlanarF(&source, &sourcePlanar, 255, 0, vImage_Flags(kvImageNoFlags))
          // Pixel centers map to centers as in kernelTaps. The horizontal shear does that with no translation; the
          // vertical one scales about the bottom edge, so it is moved back up by what the enlarging added (measured
          // against `resample` at scales 1.04 to 4, which apple_check compares it with).
          vImageHorizontalShear_ARGBFFFF(
            &sourceF, &rowsF, 0, 0, 0, 0, xFilter, &black, vImage_Flags(kvImageEdgeExtend))
          vImageVerticalShear_ARGBFFFF(
            &rowsF, &outputF, 0, 0, -(sy - 1) * Float(height), 0, yFilter, &black, vImage_Flags(kvImageEdgeExtend))
          var outputPlanar = outputF
          outputPlanar.width = vImagePixelCount(width * 4)
          vImageConvert_PlanarFtoPlanar8(&outputPlanar, &target, 255, 0, vImage_Flags(kvImageNoFlags))
        }
      }
    }
  }

  /// Catmull-Rom cubic (a = -0.5): passes through the source pixels, a slight overshoot at edges.
  static func catmullRom(_ x: Double) -> Double {
    let x = abs(x)
    if x < 1 { return (1.5 * x - 2.5) * x * x + 1 }
    if x < 2 { return ((-0.5 * x + 2.5) * x - 4) * x + 2 }
    return 0
  }

  /// Lanczos-3: sinc windowed by sinc(x / 3); the sharpest, it rings at hard edges.
  static func lanczos3(_ x: Double) -> Double {
    if abs(x) < 1e-9 { return 1 }
    if abs(x) >= 3 { return 0 }
    let px = Double.pi * x
    return 3 * sin(px) * sin(px / 3) / (px * px)
  }

  /// Per output pixel, the `2 * support` source indices (clamped to the edge)
  /// and their weights, normalized to 1, sampling at each output pixel's center.
  static func kernelTaps(_ dstLen: Int, _ srcLen: Int, support: Int, _ kernel: (Double) -> Double)
    -> (indices: [Int], weights: [Float])
  {
    let n = 2 * support
    var indices = [Int](repeating: 0, count: dstLen * n)
    var weights = [Float](repeating: 0, count: dstLen * n)
    for i in 0..<dstLen {
      let f = (Double(i) + 0.5) * Double(srcLen) / Double(dstLen) - 0.5
      let first = Int(f.rounded(.down)) - support + 1
      let w = (0..<n).map { kernel(f - Double(first + $0)) }
      let sum = w.reduce(0, +)
      for k in 0..<n {
        indices[i * n + k] = min(max(first + k, 0), srcLen - 1)
        weights[i * n + k] = Float(w[k] / sum)
      }
    }
    return (indices, weights)
  }

  /// Separable resampling with a fixed-size kernel: rows first, into floats
  /// (they may overshoot 0...255 until the end), then columns. Made for
  /// enlarging and small shrinks: the kernel isn't widened when shrinking, so
  /// large shrinks alias (use `area` for those).
  static func resample(
    _ src: UnsafePointer<UInt8>,
    srcWidth: Int,
    srcHeight: Int,
    bytesPerRow: Int,
    into dst: UnsafeMutablePointer<UInt8>,
    width: Int,
    height: Int,
    support: Int,
    kernel: (Double) -> Double
  ) {
    let n = 2 * support
    let (xIndices, xWeights) = kernelTaps(width, srcWidth, support: support, kernel)
    let (yIndices, yWeights) = kernelTaps(height, srcHeight, support: support, kernel)
    let stride = width * 4
    var mid = [Float](repeating: 0, count: stride * srcHeight)
    var acc = [Float](repeating: 0, count: stride)
    xIndices.withUnsafeBufferPointer { xi in
      xWeights.withUnsafeBufferPointer { xw in
        yIndices.withUnsafeBufferPointer { yi in
          yWeights.withUnsafeBufferPointer { yw in
            mid.withUnsafeMutableBufferPointer { m in
              acc.withUnsafeMutableBufferPointer { a in
                for y in 0..<srcHeight {
                  let row = src + y * bytesPerRow
                  let out = m.baseAddress! + y * stride
                  for x in 0..<width {
                    var c0: Float = 0, c1: Float = 0, c2: Float = 0, c3: Float = 0
                    for k in 0..<n {
                      let s = xi[x * n + k] * 4
                      let w = xw[x * n + k]
                      c0 += Float(row[s]) * w; c1 += Float(row[s + 1]) * w
                      c2 += Float(row[s + 2]) * w; c3 += Float(row[s + 3]) * w
                    }
                    out[x * 4] = c0; out[x * 4 + 1] = c1; out[x * 4 + 2] = c2; out[x * 4 + 3] = c3
                  }
                }
                for y in 0..<height {
                  for j in 0..<stride { a[j] = 0 }
                  for k in 0..<n {
                    let source = m.baseAddress! + yi[y * n + k] * stride
                    let w = yw[y * n + k]
                    for j in 0..<stride { a[j] += source[j] * w }
                  }
                  let o = dst + y * stride
                  for j in 0..<stride { o[j] = UInt8(min(max(a[j].rounded(), 0), 255)) }
                }
              }
            }
          }
        }
      }
    }
  }

  /// Unsharp mask on tightly packed RGBA, in place: each color channel moves
  /// `amount` times away from its 5x5 Gaussian blur ([1 4 6 4 1] / 16 per
  /// axis, edges clamped). Alpha is left as it is.
  static func sharpen(_ rgba: inout Data, width: Int, height: Int, amount: Double) {
    guard amount > 0, width > 0, height > 0 else { return }
    // One 5x5 kernel: (1 + amount) x the pixel minus amount x its blur, in 1/8192ths. Integer:
    // the float convolve needs iOS 17 / macOS 14. It sums to exactly 8192, so flat colors and
    // alpha (also convolved: vImage's alpha flag would skip red here) stay as they are.
    let g: [Int] = [1, 4, 6, 4, 1]
    let divisor = 8192
    var kernel = (0..<25).map {
      Int16((-amount * Double(g[$0 / 5] * g[$0 % 5] * divisor) / 256).rounded())
    }
    kernel[12] = 0
    kernel[12] = Int16(divisor - kernel.reduce(0) { $0 + Int($1) })
    let source = rgba  // vImage can't convolve in place; writing to rgba below copies it
    source.withUnsafeBytes { s in
      rgba.withUnsafeMutableBytes { d in
        var src = vImage_Buffer(
          data: UnsafeMutableRawPointer(mutating: s.baseAddress!), height: vImagePixelCount(height),
          width: vImagePixelCount(width), rowBytes: width * 4)
        var dst = vImage_Buffer(
          data: d.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width),
          rowBytes: width * 4)
        // Bias half the divisor: round to nearest.
        vImageConvolveWithBias_ARGB8888(
          &src, &dst, nil, 0, 0, kernel, 5, 5, Int32(divisor), Int32(divisor / 2), nil,
          vImage_Flags(kvImageEdgeExtend))
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
