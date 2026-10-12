package com.allmonty.video_frames

import android.media.MediaCodec
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import java.nio.ByteBuffer

/**
 * Decodes the video track of a file to RGBA frames, upright (rotation
 * metadata applied) and optionally scaled down. The decoder renders to a
 * GPU surface, and [GlRenderer] converts, rotates and scales each frame.
 *
 * Decoders are created lazily: one for sequential reading ([next]) and one
 * for seeking ([frameAt]), so scrubbing alone holds a single hardware
 * decoder.
 */
class FrameReader(private val path: String, private val maxDimension: Int?, private val filter: ScaleFilter) {
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
        val (w, h) = FrameSize.outputSize(srcWidth, srcHeight, rotation, maxDimension)
        width = w
        height = h
    }

    /** Area taps per axis: each bilinear tap covers 2 source pixels. */
    private val areaTaps = minOf(
        GlRenderer.MAX_AREA_TAPS,
        Math.ceil(maxOf(srcWidth, srcHeight).toDouble() / maxOf(width, height) / 2).toInt(),
    ).coerceAtLeast(1)

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

    /** One extractor + decoder + GL renderer over the video track. */
    private inner class Decoder {
        // One frame buffer per decoder, reused: Pigeon encodes (copies) the reply
        // before the reader's serial queue runs the next call.
        private val frame = ByteArray(width * height * 4)
        private val pixels = ByteBuffer.wrap(frame)
        private val renderer = GlRenderer.forDecoding(width, height, filter, areaTaps, srcWidth, srcHeight)
        private val extractor = MediaExtractor()
        /** e.g. "c2.goldfish.hevc.decoder (video/hevc 640x360)", for error messages; set by openCodec. */
        private var description = "video decoder"
        private val codec: MediaCodec = try {
            openCodec()
        } catch (e: Exception) {
            renderer.release()
            extractor.release()
            throw e
        }
        private val info = MediaCodec.BufferInfo()
        private var inputDone = false
        private var outputDone = false
        private var fed = false

        /** Presentation time of the last frame decoded (converted or not). */
        var lastPtsUs = -1L
            private set

        private fun openCodec(): MediaCodec {
            extractor.setDataSource(path)
            var track = -1
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) { track = i; break }
            }
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val trackMime = format.getString(MediaFormat.KEY_MIME)!!
            val mime = decodableMime(format)
            val codec = createDecoder(format, mime)
            description = "${codec.name} ($mime ${format.getInteger(MediaFormat.KEY_WIDTH)}x${format.getInteger(MediaFormat.KEY_HEIGHT)})"
            try {
                // Rotation isn't passed on: the renderer applies it.
                val config = MediaFormat.createVideoFormat(mime, format.getInteger(MediaFormat.KEY_WIDTH), format.getInteger(MediaFormat.KEY_HEIGHT))
                // A Dolby Vision base layer only needs the HEVC/AVC parameter sets (csd-0).
                val csd = if (mime == trackMime) listOf("csd-0", "csd-1", "csd-2") else listOf("csd-0")
                for (key in csd) {
                    if (format.containsKey(key)) config.setByteBuffer(key, format.getByteBuffer(key))
                }
                if (Build.VERSION.SDK_INT >= 33) {
                    // Ask for HDR (HLG/PQ) to be tone-mapped to SDR; decoders that can't ignore it.
                    config.setInteger(MediaFormat.KEY_COLOR_TRANSFER_REQUEST, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
                }
                // shortcut: below API 33 HDR input isn't tone-mapped (looks washed out); tone-map in the shader if users hit it.
                codec.configure(config, renderer.surface, null, 0)
                codec.start()
            } catch (e: Exception) {
                codec.release()
                throw e
            }
            return codec
        }

        fun seek(timeUs: Long) {
            extractor.seekTo(timeUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            // Flushing a surface decoder that has had no input can leave it never rendering.
            if (fed) codec.flush()
            fed = false
            inputDone = false
            outputDone = false
        }

        /**
         * Decode until a frame with presentation time >= `minPtsUs` and
         * return it converted; earlier frames are released unconverted.
         * Returns null at the end of the stream.
         */
        fun nextAtOrAfter(minPtsUs: Long): Pair<Long, ByteArray>? = try {
            decodeUntil(minPtsUs)
        } catch (e: IllegalStateException) {
            // A codec that fails mid-stream (e.g. unsupported 10-bit video) only says
            // "Invalid to call at Released state"; name the codec and the video.
            throw IllegalStateException("$description can't decode this video: ${e.message}", e)
        }

        private fun decodeUntil(minPtsUs: Long): Pair<Long, ByteArray>? {
            var idleSince = System.nanoTime()
            while (!outputDone) {
                var progressed = false
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        progressed = true
                        fed = true
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
                            codec.releaseOutputBuffer(outIndex, true)
                            return Pair(pts, readRendered())
                        }
                    }
                    // Frames before the target are dropped without rendering.
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

        private fun readRendered(): ByteArray {
            renderer.use { readFrame(rotation, pixels) }
            return frame
        }

        fun release() {
            try { codec.stop() } catch (_: IllegalStateException) {}
            codec.release()
            renderer.release()
            extractor.release()
        }
    }

    companion object {
        /**
         * Dolby Vision profiles 8 and 9 (iPhones record 8.4) carry an HEVC or
         * AVC base layer that ordinary decoders play; use it when the device
         * has no Dolby Vision decoder, which is common.
         */
        fun decodableMime(format: MediaFormat): String {
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            if (mime != MediaFormat.MIMETYPE_VIDEO_DOLBY_VISION) return mime
            if (MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format) != null) return mime
            val profile = if (format.containsKey(MediaFormat.KEY_PROFILE)) format.getInteger(MediaFormat.KEY_PROFILE) else -1
            return when (profile) {
                CodecProfileLevel.DolbyVisionProfileDvheSt -> MediaFormat.MIMETYPE_VIDEO_HEVC
                CodecProfileLevel.DolbyVisionProfileDvavSe -> MediaFormat.MIMETYPE_VIDEO_AVC
                // Other profiles have no compatible base layer; creating the decoder fails with a clear error.
                else -> mime
            }
        }

        /**
         * A decoder that supports the track's profile (e.g. 10-bit HEVC):
         * the default decoder for a type may not, as on the emulator.
         */
        private fun createDecoder(track: MediaFormat, mime: String): MediaCodec {
            val wanted = MediaFormat.createVideoFormat(mime, track.getInteger(MediaFormat.KEY_WIDTH), track.getInteger(MediaFormat.KEY_HEIGHT))
            val profile = when {
                // Dolby Vision profile 8's base layer is always 10-bit HEVC.
                mime != track.getString(MediaFormat.KEY_MIME) && mime == MediaFormat.MIMETYPE_VIDEO_HEVC ->
                    CodecProfileLevel.HEVCProfileMain10
                mime != track.getString(MediaFormat.KEY_MIME) -> null
                track.containsKey(MediaFormat.KEY_PROFILE) -> track.getInteger(MediaFormat.KEY_PROFILE)
                else -> null
            }
            if (profile != null) wanted.setInteger(MediaFormat.KEY_PROFILE, profile)
            val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(wanted)
            return if (name != null) MediaCodec.createByCodecName(name) else MediaCodec.createDecoderByType(mime)
        }

        private const val TIMEOUT_US = 10_000L
        private const val END_OF_STREAM_GRACE_MS = 1_000L
        private const val STALL_MS = 5_000L

        // MediaFormat.KEY_ROTATION exists from API 23.
        private const val KEY_ROTATION = "rotation-degrees"
    }
}
