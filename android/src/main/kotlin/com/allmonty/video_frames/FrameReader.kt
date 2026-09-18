package com.allmonty.video_frames

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat

/**
 * Decodes the video track of a file to RGBA frames, upright (rotation
 * metadata applied) and optionally scaled down. Uses the decoder's
 * `getOutputImage` (YUV_420_888), so no Surface or GL is needed.
 *
 * Decoders are created lazily: one for sequential reading ([next]) and one
 * for seeking ([frameAt]), so scrubbing alone holds a single hardware
 * decoder.
 */
class FrameReader(private val path: String, private val maxDimension: Int?) {
    private var sequential: Decoder? = null
    private var seeker: Decoder? = null

    val srcWidth: Int
    val srcHeight: Int
    val rotation: Int
    val durationUs: Long
    val frameRate: Double
    val hasAudio: Boolean

    /** The audio track can be copied into an MP4 unchanged. */
    val audioCompatible: Boolean
    val width: Int
    val height: Int

    init {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            var video: MediaFormat? = null
            var audio: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (video == null && mime.startsWith("video/")) video = format
                if (audio == null && mime.startsWith("audio/")) audio = format
            }
            val format = video ?: throw IllegalArgumentException("no video track in $path")
            srcWidth = format.getInteger(MediaFormat.KEY_WIDTH)
            srcHeight = format.getInteger(MediaFormat.KEY_HEIGHT)
            rotation = if (format.containsKey(KEY_ROTATION)) ((format.getInteger(KEY_ROTATION) % 360) + 360) % 360 else 0
            durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
            frameRate = if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                format.getNumber(MediaFormat.KEY_FRAME_RATE)?.toDouble() ?: 30.0
            } else {
                30.0
            }
            hasAudio = audio != null
            audioCompatible = audio?.let { AudioSupport.canMuxIntoMp4(it) } ?: false
        } finally {
            extractor.release()
        }
        val (w, h) = ColorConversion.outputSize(srcWidth, srcHeight, rotation, maxDimension)
        width = w
        height = h
    }

    /** The next frame in presentation order, or null at the end. */
    fun next(): Pair<Long, ByteArray>? {
        val decoder = sequential ?: Decoder().also { sequential = it }
        return decoder.nextAtOrAfter(Long.MIN_VALUE)
    }

    /**
     * The first frame at or after `timeUs` (the last frame when `timeUs` is
     * past the end). Only that frame is converted to RGBA; the frames decoded
     * on the way from the previous sync frame are skipped.
     */
    fun frameAt(timeUs: Long): Pair<Long, ByteArray> {
        val decoder = seeker ?: Decoder().also { seeker = it }
        try {
            decoder.seek(timeUs)
            decoder.nextAtOrAfter(timeUs)?.let { return it }
            // Past the end: decode the last frame that was seen.
            val last = decoder.lastPtsUs
            if (last < 0) throw IllegalStateException("no frame at $timeUs us")
            decoder.seek(last)
            return decoder.nextAtOrAfter(last) ?: throw IllegalStateException("no frame at $last us")
        } catch (e: Exception) {
            // A codec error leaves the decoder unusable; rebuild it next time.
            seeker = null
            decoder.release()
            throw e
        }
    }

    fun close() {
        sequential?.release()
        seeker?.release()
        sequential = null
        seeker = null
    }

    /** One extractor + decoder pair over the video track. */
    private inner class Decoder {
        private val extractor = MediaExtractor()
        private val codec: MediaCodec
        private val info = MediaCodec.BufferInfo()
        private var inputDone = false
        private var outputDone = false

        /** Presentation time of the last frame decoded (converted or not). */
        var lastPtsUs = -1L
            private set

        init {
            extractor.setDataSource(path)
            var track = -1
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) { track = i; break }
            }
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            codec = MediaCodec.createDecoderByType(mime)
            try {
                val config = MediaFormat.createVideoFormat(mime, format.getInteger(MediaFormat.KEY_WIDTH), format.getInteger(MediaFormat.KEY_HEIGHT))
                for (key in listOf("csd-0", "csd-1", "csd-2")) {
                    if (format.containsKey(key)) config.setByteBuffer(key, format.getByteBuffer(key))
                }
                config.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
                codec.configure(config, null, null, 0)
                codec.start()
            } catch (e: Exception) {
                codec.release()
                extractor.release()
                throw e
            }
        }

        fun seek(timeUs: Long) {
            extractor.seekTo(timeUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            codec.flush()
            inputDone = false
            outputDone = false
        }

        /**
         * Decode until a frame with presentation time >= `minPtsUs` and
         * return it converted; earlier frames are released unconverted.
         * Returns null at the end of the stream.
         */
        fun nextAtOrAfter(minPtsUs: Long): Pair<Long, ByteArray>? {
            var idleSince = System.nanoTime()
            while (!outputDone) {
                var progressed = false
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        progressed = true
                        val buffer = codec.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                if (outIndex >= 0) {
                    progressed = true
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    if (info.size > 0) {
                        val pts = info.presentationTimeUs
                        lastPtsUs = pts
                        if (pts >= minPtsUs) {
                            try {
                                return Pair(pts, convert(outIndex))
                            } finally {
                                codec.releaseOutputBuffer(outIndex, false)
                            }
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    progressed = true
                }

                if (progressed) {
                    idleSince = System.nanoTime()
                } else {
                    val idleMs = (System.nanoTime() - idleSince) / 1_000_000
                    // Some decoders never emit an end-of-stream buffer: once all
                    // input is queued, a quiet decoder has nothing left to give.
                    if (inputDone && idleMs > END_OF_STREAM_GRACE_MS) {
                        outputDone = true
                    } else if (idleMs > STALL_MS) {
                        throw IllegalStateException("video decoder stalled")
                    }
                }
            }
            return null
        }

        private fun convert(index: Int): ByteArray {
            val image = codec.getOutputImage(index)
                ?: throw IllegalStateException("decoder gave no YUV image")
            try {
                val planes = image.planes
                val crop = image.cropRect
                return ColorConversion.yuvToRgba(
                    ColorConversion.Plane(planes[0].buffer, planes[0].rowStride, planes[0].pixelStride),
                    ColorConversion.Plane(planes[1].buffer, planes[1].rowStride, planes[1].pixelStride),
                    ColorConversion.Plane(planes[2].buffer, planes[2].rowStride, planes[2].pixelStride),
                    crop.left, crop.top, crop.width(), crop.height(),
                    rotation, width, height,
                )
            } finally {
                image.close()
            }
        }

        fun release() {
            try { codec.stop() } catch (_: IllegalStateException) {}
            codec.release()
            extractor.release()
        }
    }

    companion object {
        private const val TIMEOUT_US = 10_000L
        private const val END_OF_STREAM_GRACE_MS = 1_000L
        private const val STALL_MS = 5_000L

        // MediaFormat.KEY_ROTATION exists from API 23.
        private const val KEY_ROTATION = "rotation-degrees"
    }
}
