package com.allmonty.video_frames

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer

/**
 * Encodes RGBA frames to H.264 in an MP4, optionally copying the audio track
 * of another file. Frames are drawn into the encoder's input surface by
 * [GlRenderer], with explicit timestamps.
 */
class FrameWriter(
    private val path: String,
    private val width: Int,
    private val height: Int,
    frameRate: Double,
    bitRate: Int?,
    audioSourcePath: String?,
) {
    init {
        require(width % 2 == 0 && height % 2 == 0) { "size must be even, got ${width}x$height" }
    }

    private val codec: MediaCodec = MediaCodec.createEncoderByType(MIME)
    private val muxer = try {
        MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    } catch (e: Exception) {
        codec.release()
        throw e
    }
    private val info = MediaCodec.BufferInfo()
    private var videoTrack = -1
    private var muxerStarted = false

    private var audioExtractor: MediaExtractor? = null
    private var audioTrack = -1
    private var inputSurface: Surface? = null
    private var renderer: GlRenderer? = null

    /** Whether the audio source's track will be copied (see [AudioSupport]). */
    val audioIncluded: Boolean
        get() = audioExtractor != null

    init {
        try {
            val format = MediaFormat.createVideoFormat(MIME, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitRate ?: defaultBitRate(width, height, frameRate))
                setFloat(MediaFormat.KEY_FRAME_RATE, frameRate.toFloat())
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val input = codec.createInputSurface().also { inputSurface = it }
            codec.start()
            renderer = GlRenderer.forEncoding(input, width, height)

            if (audioSourcePath != null) openAudio(audioSourcePath)
        } catch (e: Exception) {
            cancel()
            throw e
        }
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
        // Free output space first, so drawing into the input surface can't block on a full encoder.
        drain(false)
        renderer!!.use { writeFrame(rgba, ptsUs) }
    }

    fun finish() {
        try {
            codec.signalEndOfInputStream()
            drain(true)
            copyAudio()
        } catch (e: Exception) {
            // The plugin has already forgotten this writer: free the codec and drop the broken file.
            cancel()
            throw e
        }
        release()
    }

    fun cancel() {
        release()
        File(path).delete()
    }

    private fun drain(endOfStream: Boolean) {
        var idleSince = System.nanoTime()
        while (true) {
            // Don't wait between frames; only the final drain waits for output.
            val index = codec.dequeueOutputBuffer(info, if (endOfStream) TIMEOUT_US else 0)
            if (index != MediaCodec.INFO_TRY_AGAIN_LATER) idleSince = System.nanoTime()
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> if (endOfStream) checkStall(idleSince) else return
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

    private fun checkStall(since: Long) {
        if ((System.nanoTime() - since) / 1_000_000 > STALL_MS) throw IllegalStateException("video encoder stalled")
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
        renderer?.release()
        inputSurface?.release()
        try { if (muxerStarted) muxer.stop() } catch (_: IllegalStateException) {}
        muxer.release()
        audioExtractor?.release()
    }

    companion object {
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        private const val TIMEOUT_US = 10_000L
        private const val STALL_MS = 5_000L

        /** ~0.2 bits per pixel per frame: good quality for flat pixel art. */
        fun defaultBitRate(width: Int, height: Int, frameRate: Double): Int =
            maxOf(1_000_000, (width.toLong() * height * frameRate * 0.2).toInt())
    }
}
