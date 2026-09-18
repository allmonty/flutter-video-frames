package com.allmonty.video_frames

import android.media.MediaMuxer
import android.media.MediaFormat
import java.io.File

/** Whether an audio track can be copied into an MP4 unchanged. */
object AudioSupport {
    /**
     * Asks the device: `MediaMuxer` (MPEG-4) either accepts the track format
     * or throws. Tried on a throwaway muxer, since the accepted codecs vary
     * by Android version (AAC always works; PCM from .mov files never does).
     */
    fun canMuxIntoMp4(format: MediaFormat): Boolean {
        val probe = File.createTempFile("video_frames_probe", ".mp4")
        var muxer: MediaMuxer? = null
        return try {
            muxer = MediaMuxer(probe.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer.addTrack(format)
            true
        } catch (e: Exception) {
            false
        } finally {
            try { muxer?.release() } catch (_: Exception) {}
            probe.delete()
        }
    }
}
