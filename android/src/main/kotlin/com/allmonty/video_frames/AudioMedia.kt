package com.allmonty.video_frames

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer

/** Raw sound: 16-bit signed little-endian PCM, channels interleaved. */
class Pcm(val data: ByteArray, val sampleRate: Int, val channels: Int)

/** Encoded AAC, ready for a muxer: its format and its samples in order. */
class EncodedAudio(val format: MediaFormat, val samples: List<Pair<ByteArray, MediaCodec.BufferInfo>>)

/** Whole-file work on sound and joining. Needs a device (MediaCodec), so it's covered by the example's integration tests. */
object AudioMedia {
    private const val TIMEOUT_US = 10_000L
    private const val STALL_MS = 5_000L

    /** The first audio track of `path` decoded to 16-bit PCM at its own rate and channels; null when it has none. */
    fun decode(path: String): Pcm? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return null
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            try {
                codec.configure(format, null, null, 0)
                codec.start()
                val out = ByteArrayOutputStream()
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var idleSince = System.nanoTime()
                while (true) {
                    if (!inputDone) {
                        val i = codec.dequeueInputBuffer(TIMEOUT_US)
                        if (i >= 0) {
                            val size = extractor.readSampleData(codec.getInputBuffer(i)!!, 0)
                            if (size < 0) {
                                codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(i, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val o = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                    when {
                        o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val f = codec.outputFormat
                            rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            if (f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                                f.getInteger(MediaFormat.KEY_PCM_ENCODING) != AudioFormat.ENCODING_PCM_16BIT
                            ) throw UnsupportedOperationException("the decoder doesn't give 16-bit sound")
                        }
                        o >= 0 -> {
                            idleSince = System.nanoTime()
                            val buffer = codec.getOutputBuffer(o)!!
                            val bytes = ByteArray(info.size)
                            buffer.position(info.offset)
                            buffer.get(bytes)
                            out.write(bytes)
                            codec.releaseOutputBuffer(o, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                        }
                        (System.nanoTime() - idleSince) / 1_000_000 > STALL_MS -> throw IllegalStateException("audio decoder stalled")
                    }
                }
                return Pcm(out.toByteArray(), rate, channels)
            } finally {
                try { codec.stop() } catch (_: IllegalStateException) {}
                codec.release()
            }
        } finally {
            extractor.release()
        }
    }

    /** `pcm` encoded to AAC-LC, all at once (it's known before the video starts, so its track can be added in time). */
    fun encodeAac(pcm: Pcm): EncodedAudio {
        val bytesPerFrame = pcm.channels * 2
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, pcm.sampleRate, pcm.channels).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 64_000 * pcm.channels)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4096 * bytesPerFrame)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            val samples = mutableListOf<Pair<ByteArray, MediaCodec.BufferInfo>>()
            var outFormat: MediaFormat? = null
            val info = MediaCodec.BufferInfo()
            var offset = 0
            var inputDone = false
            var idleSince = System.nanoTime()
            while (true) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (i >= 0) {
                        val buffer = codec.getInputBuffer(i)!!
                        val size = minOf(buffer.capacity() / bytesPerFrame * bytesPerFrame, pcm.data.size - offset)
                        val ptsUs = offset.toLong() / bytesPerFrame * 1_000_000 / pcm.sampleRate
                        if (size <= 0) {
                            codec.queueInputBuffer(i, 0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            buffer.clear()
                            buffer.put(pcm.data, offset, size)
                            codec.queueInputBuffer(i, 0, size, ptsUs, 0)
                            offset += size
                        }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> outFormat = codec.outputFormat
                    o >= 0 -> {
                        idleSince = System.nanoTime()
                        if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            val buffer = codec.getOutputBuffer(o)!!
                            val bytes = ByteArray(info.size)
                            buffer.position(info.offset)
                            buffer.get(bytes)
                            val copy = MediaCodec.BufferInfo().apply { set(0, info.size, info.presentationTimeUs, info.flags) }
                            samples.add(bytes to copy)
                        }
                        codec.releaseOutputBuffer(o, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                    }
                    (System.nanoTime() - idleSince) / 1_000_000 > STALL_MS -> throw EncoderStalledException()
                }
            }
            return EncodedAudio(outFormat ?: codec.outputFormat, samples)
        } finally {
            try { codec.stop() } catch (_: IllegalStateException) {}
            codec.release()
        }
    }

    /** Join MP4s of the same format one after another into `output`, without re-encoding. */
    fun concat(inputs: List<String>, output: String) {
        require(inputs.isNotEmpty()) { "nothing to join" }
        val muxer = MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var started = false
        try {
            val tracks = linkedMapOf<String, Int>() // "video" / "audio" → the output's track, from the first input
            val shapes = hashMapOf<String, List<Any?>>()
            val first = MediaExtractor()
            try {
                first.setDataSource(inputs[0])
                for (i in 0 until first.trackCount) {
                    val format = first.getTrackFormat(i)
                    val kind = format.getString(MediaFormat.KEY_MIME)?.substringBefore('/') ?: continue
                    if ((kind == "video" || kind == "audio") && kind !in tracks) {
                        tracks[kind] = muxer.addTrack(format)
                        shapes[kind] = shape(format)
                    }
                }
            } finally {
                first.release()
            }
            muxer.start()
            started = true
            val buffer = ByteBuffer.allocate(8 shl 20)
            val info = MediaCodec.BufferInfo()
            var offsetUs = 0L
            for (path in inputs) {
                var lengthUs = 0L
                for ((kind, track) in tracks) {
                    val extractor = MediaExtractor()
                    try {
                        extractor.setDataSource(path)
                        val i = (0 until extractor.trackCount).firstOrNull {
                            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("$kind/") == true
                        } ?: continue
                        extractor.selectTrack(i)
                        val format = extractor.getTrackFormat(i)
                        // MediaMuxer takes any samples, so a clip of another size or rate would play back broken.
                        require(shape(format) == shapes[kind]) { "$path has a different $kind format than ${inputs[0]}" }
                        var lastUs = 0L
                        while (true) {
                            val size = extractor.readSampleData(buffer, 0)
                            if (size < 0) break
                            lastUs = extractor.sampleTime
                            info.set(0, size, lastUs + offsetUs, extractor.sampleFlags)
                            muxer.writeSampleData(track, buffer, info)
                            extractor.advance()
                        }
                        val duration = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else lastUs
                        lengthUs = maxOf(lengthUs, duration)
                    } finally {
                        extractor.release()
                    }
                }
                offsetUs += lengthUs
            }
            muxer.stop()
            started = false
        } catch (e: Exception) {
            File(output).delete()
            throw e
        } finally {
            try { if (started) muxer.stop() } catch (_: IllegalStateException) {}
            muxer.release()
        }
    }

    /** What two tracks must share for one's samples to play in the other. */
    private fun shape(f: MediaFormat): List<Any?> =
        listOf(MediaFormat.KEY_WIDTH, MediaFormat.KEY_HEIGHT, MediaFormat.KEY_SAMPLE_RATE, MediaFormat.KEY_CHANNEL_COUNT)
            .map { if (f.containsKey(it)) f.getInteger(it) else null } + f.getString(MediaFormat.KEY_MIME)
}
