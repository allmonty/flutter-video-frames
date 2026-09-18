package com.allmonty.video_frames

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat

/**
 * Decodes the video track of a file to RGBA frames, upright (rotation
 * metadata applied) and optionally scaled down. Uses the decoder's
 * `getOutputImage` (YUV_420_888), so no Surface or GL is needed.
 */
class FrameReader(private val path: String, private val maxDimension: Int?) {
    private val sequential = Decoder()
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
        val format = sequential.format
        srcWidth = format.getInteger(MediaFormat.KEY_WIDTH)
        srcHeight = format.getInteger(MediaFormat.KEY_HEIGHT)
        rotation = if (format.containsKey(KEY_ROTATION)) ((format.getInteger(KEY_ROTATION) % 360) + 360) % 360 else 0
        durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
        frameRate = if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
            format.getNumber(MediaFormat.KEY_FRAME_RATE)?.toDouble() ?: 30.0
        } else {
            30.0
        }
        hasAudio = sequential.audioFormat != null
        audioCompatible = sequential.audioFormat?.let { AudioSupport.canMuxIntoMp4(it) } ?: false
        val (w, h) = ColorConversion.outputSize(srcWidth, srcHeight, rotation, maxDimension)
        width = w
        height = h
    }

    /** The next frame in presentation order, or null at the end. */
    fun next(): Pair<Long, ByteArray>? = sequential.next()

    /** The first frame at or after `timeUs` (the last frame if past the end). */
    fun frameAt(timeUs: Long): Pair<Long, ByteArray> {
        val decoder = seeker ?: Decoder().also { seeker = it }
        decoder.seek(timeUs)
        var last: Pair<Long, ByteArray>? = null
        while (true) {
            val frame = decoder.next() ?: break
            last = frame
            if (frame.first >= timeUs) break
        }
        return last ?: throw IllegalStateException("no frame at $timeUs us")
    }

    fun close() {
        sequential.release()
        seeker?.release()
    }

    /** One extractor + decoder pair over the video track. */
    private inner class Decoder {
        val extractor = MediaExtractor()
        val format: MediaFormat
        val audioFormat: MediaFormat?
        private val codec: MediaCodec
        private val info = MediaCodec.BufferInfo()
        private var inputDone = false
        private var outputDone = false

        init {
            extractor.setDataSource(path)
            var track = -1
            var audio: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val trackFormat = extractor.getTrackFormat(i)
                val mime = trackFormat.getString(MediaFormat.KEY_MIME) ?: continue
                if (track < 0 && mime.startsWith("video/")) track = i
                if (audio == null && mime.startsWith("audio/")) audio = trackFormat
            }
            if (track < 0) {
                extractor.release()
                throw IllegalArgumentException("no video track in $path")
            }
            audioFormat = audio
            extractor.selectTrack(track)
            format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            codec = MediaCodec.createDecoderByType(mime)
            val config = MediaFormat.createVideoFormat(mime, format.getInteger(MediaFormat.KEY_WIDTH), format.getInteger(MediaFormat.KEY_HEIGHT))
            for (key in listOf("csd-0", "csd-1", "csd-2")) {
                if (format.containsKey(key)) config.setByteBuffer(key, format.getByteBuffer(key))
            }
            config.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            codec.configure(config, null, null, 0)
            codec.start()
        }

        fun seek(timeUs: Long) {
            extractor.seekTo(timeUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            codec.flush()
            inputDone = false
            outputDone = false
        }

        fun next(): Pair<Long, ByteArray>? {
            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
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
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    if (info.size > 0) {
                        val frame = convert(outIndex)
                        codec.releaseOutputBuffer(outIndex, false)
                        return Pair(info.presentationTimeUs, frame)
                    }
                    codec.releaseOutputBuffer(outIndex, false)
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
        // MediaFormat.KEY_ROTATION exists from API 23.
        private const val KEY_ROTATION = "rotation-degrees"
    }
}
