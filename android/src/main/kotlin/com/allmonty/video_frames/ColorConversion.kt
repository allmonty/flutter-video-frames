package com.allmonty.video_frames

import java.nio.ByteBuffer

/**
 * Pure pixel conversions between YUV 4:2:0 (BT.601, limited range, as video
 * decoders and encoders use) and RGBA. Planes are described by their buffer,
 * row stride and pixel stride, which covers both planar (I420, pixel stride
 * 1) and semi-planar (NV12/NV21, pixel stride 2) layouts of
 * `ImageFormat.YUV_420_888`.
 */
object ColorConversion {
    class Plane(val buffer: ByteBuffer, val rowStride: Int, val pixelStride: Int)

    private fun clamp(v: Int): Int = if (v < 0) 0 else if (v > 255) 255 else v

    /**
     * Size of a `srcWidth x srcHeight` frame after rotating by `rotation`
     * degrees (0/90/180/270) and scaling down so neither edge exceeds
     * `maxDimension` (when positive).
     */
    fun outputSize(srcWidth: Int, srcHeight: Int, rotation: Int, maxDimension: Int?): Pair<Int, Int> {
        var w = if (rotation % 180 == 0) srcWidth else srcHeight
        var h = if (rotation % 180 == 0) srcHeight else srcWidth
        if (maxDimension != null && maxDimension > 0) {
            val longest = maxOf(w, h)
            if (longest > maxDimension) {
                val scale = maxDimension.toDouble() / longest
                w = maxOf(1, Math.round(w * scale).toInt())
                h = maxOf(1, Math.round(h * scale).toInt())
            }
        }
        return Pair(w, h)
    }

    /**
     * Convert the `cropLeft/cropTop/srcWidth/srcHeight` region of a YUV
     * 4:2:0 image to an RGBA frame of `dstWidth x dstHeight`, rotated
     * clockwise by `rotation` degrees. Scaling uses nearest-neighbour
     * sampling.
     */
    fun yuvToRgba(
        y: Plane,
        u: Plane,
        v: Plane,
        cropLeft: Int,
        cropTop: Int,
        srcWidth: Int,
        srcHeight: Int,
        rotation: Int,
        dstWidth: Int,
        dstHeight: Int,
    ): ByteArray {
        val out = ByteArray(dstWidth * dstHeight * 4)
        // Size of the rotated (but unscaled) frame.
        val rotW = if (rotation % 180 == 0) srcWidth else srcHeight
        val rotH = if (rotation % 180 == 0) srcHeight else srcWidth
        var o = 0
        for (dy in 0 until dstHeight) {
            val ry = (dy.toLong() * rotH / dstHeight).toInt()
            for (dx in 0 until dstWidth) {
                val rx = (dx.toLong() * rotW / dstWidth).toInt()
                // Undo the clockwise rotation to find the source pixel.
                val sx: Int
                val sy: Int
                when (rotation) {
                    90 -> { sx = ry; sy = srcHeight - 1 - rx }
                    180 -> { sx = srcWidth - 1 - rx; sy = srcHeight - 1 - ry }
                    270 -> { sx = srcWidth - 1 - ry; sy = rx }
                    else -> { sx = rx; sy = ry }
                }
                val px = sx + cropLeft
                val py = sy + cropTop
                val yy = y.buffer.get(py * y.rowStride + px * y.pixelStride).toInt() and 0xFF
                val cx = px / 2
                val cy = py / 2
                val uu = u.buffer.get(cy * u.rowStride + cx * u.pixelStride).toInt() and 0xFF
                val vv = v.buffer.get(cy * v.rowStride + cx * v.pixelStride).toInt() and 0xFF
                val c = yy - 16
                val d = uu - 128
                val e = vv - 128
                out[o] = clamp((298 * c + 409 * e + 128) shr 8).toByte()
                out[o + 1] = clamp((298 * c - 100 * d - 208 * e + 128) shr 8).toByte()
                out[o + 2] = clamp((298 * c + 516 * d + 128) shr 8).toByte()
                out[o + 3] = 0xFF.toByte()
                o += 4
            }
        }
        return out
    }

    /**
     * Write an RGBA frame (`width x height`, both even) into YUV 4:2:0
     * planes. Chroma is the average of each 2x2 block.
     */
    fun rgbaToYuv(rgba: ByteArray, width: Int, height: Int, y: Plane, u: Plane, v: Plane) {
        for (row in 0 until height) {
            for (col in 0 until width) {
                val i = (row * width + col) * 4
                val r = rgba[i].toInt() and 0xFF
                val g = rgba[i + 1].toInt() and 0xFF
                val b = rgba[i + 2].toInt() and 0xFF
                val yy = ((66 * r + 129 * g + 25 * b + 128) shr 8) + 16
                y.buffer.put(row * y.rowStride + col * y.pixelStride, clamp(yy).toByte())
            }
        }
        for (cy in 0 until height / 2) {
            for (cx in 0 until width / 2) {
                var r = 0
                var g = 0
                var b = 0
                for (dy in 0..1) {
                    for (dx in 0..1) {
                        val i = ((cy * 2 + dy) * width + cx * 2 + dx) * 4
                        r += rgba[i].toInt() and 0xFF
                        g += rgba[i + 1].toInt() and 0xFF
                        b += rgba[i + 2].toInt() and 0xFF
                    }
                }
                r = (r + 2) / 4
                g = (g + 2) / 4
                b = (b + 2) / 4
                val uu = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                val vv = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                u.buffer.put(cy * u.rowStride + cx * u.pixelStride, clamp(uu).toByte())
                v.buffer.put(cy * v.rowStride + cx * v.pixelStride, clamp(vv).toByte())
            }
        }
    }
}
