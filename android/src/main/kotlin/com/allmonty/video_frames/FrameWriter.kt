package com.allmonty.video_frames

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

/**
 * Encodes RGBA frames to H.264 in an MP4, optionally copying the audio track
 * of another file. Frames go in through the encoder's YUV input images with
 * explicit timestamps.
 */
class FrameWriter(
    private val path: String,
    private val width: Int,
    private val height: Int,
    frameRate: Double,
    bitRate: Int?,
    audioSourcePath: String?,
) {
    private val codec: MediaCodec = MediaCodec.createEncoderByType(MIME)
    private val muxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private val info = MediaCodec.BufferInfo()
    private var videoTrack = -1
    private var muxerStarted = false

    private var audioExtractor: MediaExtractor? = null
    private var audioTrack = -1

    /** Whether the audio source's track will be copied (see [AudioSupport]). */
    val audioIncluded: Boolean
        get() = audioExtractor != null

    init {
        require(width % 2 == 0 && height % 2 == 0) { "size must be even, got ${width}x$height" }
        val format = MediaFormat.createVideoFormat(MIME, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate ?: defaultBitRate(width, height, frameRate))
            setFloat(MediaFormat.KEY_FRAME_RATE, frameRate.toFloat())
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()

        if (audioSourcePath != null) openAudio(audioSourcePath)
    }

    /**
     * Add the source's audio track to the muxer (its samples are copied in
     * finish(), since the muxer only starts once the video format is known).
     * A format the MP4 muxer rejects is dropped: the video is still written.
     */
    private fun openAudio(source: String) {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(source)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("audio/")) continue
                audioTrack = muxer.addTrack(format)
                extractor.selectTrack(i)
                audioExtractor = extractor
                return
            }
        } catch (e: Exception) {
            // Unsupported audio format: continue without sound.
        }
        audioTrack = -1
        extractor.release()
    }

    fun addFrame(rgba: ByteArray, ptsUs: Long) {
        require(rgba.size == width * height * 4) { "expected ${width * height * 4} bytes, got ${rgba.size}" }
        var index: Int
        do {
            index = codec.dequeueInputBuffer(TIMEOUT_US)
            if (index < 0) drain(false)
        } while (index < 0)
        val image = codec.getInputImage(index) ?: throw IllegalStateException("encoder gave no YUV image")
        val planes = image.planes
        ColorConversion.rgbaToYuv(
            rgba, width, height,
            ColorConversion.Plane(planes[0].buffer, planes[0].rowStride, planes[0].pixelStride),
            ColorConversion.Plane(planes[1].buffer, planes[1].rowStride, planes[1].pixelStride),
            ColorConversion.Plane(planes[2].buffer, planes[2].rowStride, planes[2].pixelStride),
        )
        codec.queueInputBuffer(index, 0, width * height * 3 / 2, ptsUs, 0)
        drain(false)
    }

    fun finish() {
        var index: Int
        do {
            index = codec.dequeueInputBuffer(TIMEOUT_US)
            if (index < 0) drain(false)
        } while (index < 0)
        codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        drain(true)
        copyAudio()
        release()
    }

    fun cancel() {
        release()
        File(path).delete()
    }

    private fun drain(endOfStream: Boolean) {
        while (true) {
            val index = codec.dequeueOutputBuffer(info, TIMEOUT_US)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) return
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    videoTrack = muxer.addTrack(codec.outputFormat)
                    muxer.start()
                    muxerStarted = true
                }
                index >= 0 -> {
                    val buffer = codec.getOutputBuffer(index)!!
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                    if (info.size > 0 && muxerStarted) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        muxer.writeSampleData(videoTrack, buffer, info)
                    }
                    codec.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    private fun copyAudio() {
        val extractor = audioExtractor ?: return
        if (!muxerStarted) return
        val buffer = ByteBuffer.allocate(1 shl 20)
        val sample = MediaCodec.BufferInfo()
        while (true) {
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) break
            sample.set(0, size, extractor.sampleTime, extractor.sampleFlags)
            muxer.writeSampleData(audioTrack, buffer, sample)
            extractor.advance()
        }
    }

    private fun release() {
        try { codec.stop() } catch (_: IllegalStateException) {}
        codec.release()
        try { if (muxerStarted) muxer.stop() } catch (_: IllegalStateException) {}
        muxer.release()
        audioExtractor?.release()
    }

    companion object {
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val TIMEOUT_US = 10_000L

        /** ~0.2 bits per pixel per frame: good quality for flat pixel art. */
        fun defaultBitRate(width: Int, height: Int, frameRate: Double): Int =
            maxOf(1_000_000, (width.toLong() * height * frameRate * 0.2).toInt())
    }
}
