package com.allmonty.video_frames

import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ColorConversionTest {
    /** Planes for a `w x h` frame: planar I420, or semi-planar NV12. */
    private fun planes(w: Int, h: Int, semiPlanar: Boolean): Triple<ColorConversion.Plane, ColorConversion.Plane, ColorConversion.Plane> {
        val y = ColorConversion.Plane(ByteBuffer.allocate(w * h), w, 1)
        return if (semiPlanar) {
            val uv = ByteBuffer.allocate(w * h / 2)
            // U and V share one interleaved buffer, offset by one byte.
            val u = ColorConversion.Plane(uv, w, 2)
            val vBuf = ByteBuffer.wrap(uv.array(), 1, uv.capacity() - 1).slice()
            Triple(y, u, ColorConversion.Plane(vBuf, w, 2))
        } else {
            Triple(
                y,
                ColorConversion.Plane(ByteBuffer.allocate(w * h / 4), w / 2, 1),
                ColorConversion.Plane(ByteBuffer.allocate(w * h / 4), w / 2, 1),
            )
        }
    }

    /** A frame made of flat 2x2 blocks, so chroma subsampling is lossless. */
    private fun blocks(w: Int, h: Int): ByteArray {
        val colors = listOf(
            intArrayOf(255, 0, 0), intArrayOf(0, 255, 0), intArrayOf(0, 0, 255),
            intArrayOf(255, 255, 255), intArrayOf(0, 0, 0), intArrayOf(200, 120, 40),
        )
        val out = ByteArray(w * h * 4)
        for (y in 0 until h) for (x in 0 until w) {
            val c = colors[((y / 2) * (w / 2) + x / 2) % colors.size]
            val i = (y * w + x) * 4
            out[i] = c[0].toByte(); out[i + 1] = c[1].toByte(); out[i + 2] = c[2].toByte(); out[i + 3] = 0xFF.toByte()
        }
        return out
    }

    private fun assertClose(expected: ByteArray, actual: ByteArray, tolerance: Int) {
        assertEquals(expected.size, actual.size)
        for (i in expected.indices) {
            val d = abs((expected[i].toInt() and 0xFF) - (actual[i].toInt() and 0xFF))
            assertTrue(d <= tolerance, "byte $i differs by $d")
        }
    }

    @Test
    fun roundTripsThroughI420AndNv12() {
        for (semiPlanar in listOf(false, true)) {
            val (w, h) = Pair(8, 6)
            val rgba = blocks(w, h)
            val (y, u, v) = planes(w, h, semiPlanar)
            ColorConversion.rgbaToYuv(rgba, w, h, y, u, v)
            val back = ColorConversion.yuvToRgba(y, u, v, 0, 0, w, h, 0, w, h)
            assertClose(rgba, back, 3)
        }
    }

    @Test
    fun rotatesClockwise() {
        // 2x2 blocks of a 4x2 frame: left block red, right block blue.
        val (w, h) = Pair(4, 2)
        val rgba = ByteArray(w * h * 4)
        for (yy in 0 until h) for (x in 0 until w) {
            val i = (yy * w + x) * 4
            if (x < 2) rgba[i] = 0xFF.toByte() else rgba[i + 2] = 0xFF.toByte()
            rgba[i + 3] = 0xFF.toByte()
        }
        val (y, u, v) = planes(w, h, false)
        ColorConversion.rgbaToYuv(rgba, w, h, y, u, v)
        // Rotated 90° clockwise: 2 wide, 4 tall; red ends up on top.
        val out = ColorConversion.yuvToRgba(y, u, v, 0, 0, w, h, 90, 2, 4)
        assertTrue((out[0].toInt() and 0xFF) > 200, "top is red")
        assertTrue((out[(3 * 2) * 4 + 2].toInt() and 0xFF) > 200, "bottom is blue")
        // 180°: blue on the left.
        val flipped = ColorConversion.yuvToRgba(y, u, v, 0, 0, w, h, 180, 4, 2)
        assertTrue((flipped[2].toInt() and 0xFF) > 200, "left is blue")
    }

    @Test
    fun outputSizeRotatesAndCaps() {
        assertEquals(Pair(1920, 1080), ColorConversion.outputSize(1920, 1080, 0, null))
        assertEquals(Pair(1080, 1920), ColorConversion.outputSize(1920, 1080, 90, null))
        assertEquals(Pair(640, 360), ColorConversion.outputSize(1920, 1080, 0, 640))
        assertEquals(Pair(360, 640), ColorConversion.outputSize(1920, 1080, 270, 640))
        assertEquals(Pair(100, 50), ColorConversion.outputSize(100, 50, 0, 640))
    }

    @Test
    fun scalesDownWithNearestSampling() {
        val (w, h) = Pair(8, 8)
        val rgba = blocks(w, h)
        val (y, u, v) = planes(w, h, false)
        ColorConversion.rgbaToYuv(rgba, w, h, y, u, v)
        val half = ColorConversion.yuvToRgba(y, u, v, 0, 0, w, h, 0, 4, 4)
        assertEquals(4 * 4 * 4, half.size)
        // Pixel (1,0) of the half-size frame samples source (2,0): the 2nd block (green).
        assertTrue((half[4 + 1].toInt() and 0xFF) > 200)
    }

    @Test
    fun defaultBitRateHasAFloor() {
        assertEquals(1_000_000, FrameWriter.defaultBitRate(16, 16, 30.0))
        assertEquals((1920L * 1080 * 30 * 0.2).toInt(), FrameWriter.defaultBitRate(1920, 1080, 30.0))
    }
}
