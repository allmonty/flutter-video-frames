package com.allmonty.video_frames

object FrameSize {
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
}
