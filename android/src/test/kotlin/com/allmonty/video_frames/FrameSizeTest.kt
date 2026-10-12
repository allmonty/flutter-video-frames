package com.allmonty.video_frames

import kotlin.test.Test
import kotlin.test.assertEquals

class FrameSizeTest {
    @Test
    fun outputSizeRotatesAndCaps() {
        assertEquals(Pair(1920, 1080), FrameSize.outputSize(1920, 1080, 0, null))
        assertEquals(Pair(1080, 1920), FrameSize.outputSize(1920, 1080, 90, null))
        assertEquals(Pair(640, 360), FrameSize.outputSize(1920, 1080, 0, 640))
        assertEquals(Pair(360, 640), FrameSize.outputSize(1920, 1080, 270, 640))
        assertEquals(Pair(100, 50), FrameSize.outputSize(100, 50, 0, 640))
    }

    /** The texture coordinate (u, v up) drawn at each output corner, for one rotation. */
    private fun corners(rotation: Int): Map<String, Pair<Float, Float>> {
        val q = GlRenderer.decodeQuad(rotation)
        // Vertices are (x, y, u, v); y = -1 is read back first, so it's the top row.
        return (0 until 4).associate { i ->
            val name = (if (q[i * 4 + 1] < 0) "top" else "bottom") + (if (q[i * 4] < 0) "Left" else "Right")
            name to Pair(q[i * 4 + 2], q[i * 4 + 3])
        }
    }

    @Test
    fun decodeQuadRotatesClockwise() {
        // Source corners in texture space: top-left is (0, 1), bottom-left is (0, 0).
        assertEquals(Pair(0f, 1f), corners(0)["topLeft"])
        // 90° clockwise: the source's bottom-left ends up top-left.
        assertEquals(Pair(0f, 0f), corners(90)["topLeft"])
        assertEquals(Pair(0f, 1f), corners(90)["topRight"])
        // 180°: the source's bottom-right ends up top-left.
        assertEquals(Pair(1f, 0f), corners(180)["topLeft"])
        // 270°: the source's top-right ends up top-left.
        assertEquals(Pair(1f, 1f), corners(270)["topLeft"])
    }

    @Test
    fun defaultBitRateHasAFloor() {
        assertEquals(1_000_000, FrameWriter.defaultBitRate(16, 16, 30.0))
        assertEquals((1920L * 1080 * 30 * 0.2).toInt(), FrameWriter.defaultBitRate(1920, 1080, 30.0))
    }
}
