package com.allmonty.video_frames

import io.flutter.embedding.engine.plugins.FlutterPlugin

/** Routes the Pigeon host API to [FrameReader]s and [FrameWriter]s by id. */
class VideoFramesPlugin : FlutterPlugin, VideoFramesHostApi {
    private val readers = HashMap<Long, FrameReader>()
    private val writers = HashMap<Long, FrameWriter>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        VideoFramesHostApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        VideoFramesHostApi.setUp(binding.binaryMessenger, null)
        synchronized(this) {
            readers.values.forEach { it.close() }
            writers.values.forEach { it.cancel() }
            readers.clear()
            writers.clear()
        }
    }

    private fun reader(id: Long) = synchronized(this) { readers[id] } ?: throw IllegalArgumentException("unknown reader $id")
    private fun writer(id: Long) = synchronized(this) { writers[id] } ?: throw IllegalArgumentException("unknown writer $id")

    override fun openReader(readerId: Long, path: String, maxDimension: Long?): VideoInfoMessage {
        val reader = FrameReader(path, maxDimension?.toInt())
        synchronized(this) { readers[readerId] = reader }
        return VideoInfoMessage(
            width = reader.width.toLong(),
            height = reader.height.toLong(),
            durationUs = reader.durationUs,
            frameRate = reader.frameRate,
            rotationDegrees = reader.rotation.toLong(),
            hasAudio = reader.hasAudio,
            audioCompatible = reader.audioCompatible,
        )
    }

    override fun nextFrame(readerId: Long): VideoFrameMessage? {
        val reader = reader(readerId)
        val (pts, rgba) = reader.next() ?: return null
        return VideoFrameMessage(pts, reader.width.toLong(), reader.height.toLong(), rgba)
    }

    override fun frameAt(readerId: Long, timeUs: Long): VideoFrameMessage {
        val reader = reader(readerId)
        val (pts, rgba) = reader.frameAt(timeUs)
        return VideoFrameMessage(pts, reader.width.toLong(), reader.height.toLong(), rgba)
    }

    override fun closeReader(readerId: Long) {
        synchronized(this) { readers.remove(readerId) }?.close()
    }

    override fun openWriter(
        writerId: Long,
        path: String,
        width: Long,
        height: Long,
        frameRate: Double,
        bitRate: Long?,
        audioSourcePath: String?,
    ): Boolean {
        val writer = FrameWriter(path, width.toInt(), height.toInt(), frameRate, bitRate?.toInt(), audioSourcePath)
        synchronized(this) { writers[writerId] = writer }
        return writer.audioIncluded
    }

    override fun addFrame(writerId: Long, rgba: ByteArray, ptsUs: Long) {
        writer(writerId).addFrame(rgba, ptsUs)
    }

    override fun finishWriter(writerId: Long) {
        val writer = synchronized(this) { writers.remove(writerId) } ?: throw IllegalArgumentException("unknown writer $writerId")
        writer.finish()
    }

    override fun cancelWriter(writerId: Long) {
        synchronized(this) { writers.remove(writerId) }?.cancel()
    }
}
