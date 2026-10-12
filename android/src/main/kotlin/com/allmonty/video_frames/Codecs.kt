package com.allmonty.video_frames

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList

/**
 * Codec choice that works across devices: vendor codecs can claim a format
 * and still fail to configure or start (a Qualcomm encoder at 64x64, for
 * example), so callers try every candidate in the device's preference order
 * (hardware first) and end with Android's own software codecs.
 */
object Codecs {
    /** Names of the encoders or decoders for `mime` whose capabilities `accept`. */
    fun names(mime: String, encoder: Boolean, accept: (MediaCodecInfo.CodecCapabilities) -> Boolean): List<String> =
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { it.isEncoder == encoder && it.supportedTypes.any { type -> type.equals(mime, ignoreCase = true) } }
            .filter { runCatching { accept(it.getCapabilitiesForType(mime)) }.getOrDefault(false) }
            .map { it.name }

    /**
     * Create each codec in `names` and run `start` on it (configure + start)
     * until one works; failed ones are released. Throws naming `what` when
     * none works.
     */
    fun <T> startFirst(names: List<String>, what: String, start: (MediaCodec) -> T): Pair<MediaCodec, T> {
        var failure: Exception? = null
        for (name in names) {
            val codec = try {
                MediaCodec.createByCodecName(name)
            } catch (e: Exception) {
                failure = e
                continue
            }
            try {
                return codec to start(codec)
            } catch (e: Exception) {
                failure = e
                codec.release()
            }
        }
        throw UnsupportedOperationException("no $what works on this device (tried ${names.ifEmpty { listOf("none") }.joinToString()})", failure)
    }
}
