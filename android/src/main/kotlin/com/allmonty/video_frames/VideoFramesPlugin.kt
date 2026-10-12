package com.allmonty.video_frames

import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.io.File

/**
 * Routes the Pigeon host APIs to [FrameReader]s and [FrameWriter]s by id.
 * Readers and writers run on two separate background queues.
 */
class VideoFramesPlugin : FlutterPlugin, VideoReaderHostApi, VideoWriterHostApi {
    private val readers = HashMap<Long, FrameReader>()
    private val writers = HashMap<Long, FrameWriter>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        VideoReaderHostApi.setUp(binding.binaryMessenger, this)
        VideoWriterHostApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        VideoReaderHostApi.setUp(binding.binaryMessenger, null)
        VideoWriterHostApi.setUp(binding.binaryMessenger, null)
        synchronized(this) {
            readers.values.forEach { it.close() }
            writers.values.forEach { it.cancel() }
            readers.clear()
            writers.clear()
        }
    }

    private fun reader(id: Long) = synchronized(this) { readers[id] } ?: throw IllegalArgumentException("unknown reader $id")
    private fun writer(id: Long) = synchronized(this) { writers[id] } ?: throw IllegalArgumentException("unknown writer $id")

    override fun openReader(readerId: Long, path: String, maxDimension: Long?, filter: ScaleFilter): VideoInfoMessage {
        if (!File(path).isFile) throw FlutterError("fileNotFound", "no file at $path")
        // Opening only reads the container (decoders start on the first frame), so failures here are the file's.
        val reader = coded("unsupportedFormat") { FrameReader(path, maxDimension?.toInt(), filter) }
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
        val (pts, rgba) = coded("readFailed") { reader.next() } ?: return null
        return VideoFrameMessage(pts, reader.width.toLong(), reader.height.toLong(), rgba)
    }

    override fun frameAt(readerId: Long, timeUs: Long): VideoFrameMessage {
        val reader = reader(readerId)
        val (pts, rgba) = coded("readFailed") { reader.frameAt(timeUs) }
        return VideoFrameMessage(pts, reader.width.toLong(), reader.height.toLong(), rgba)
    }

    override fun seek(readerId: Long, timeUs: Long) {
        val reader = reader(readerId)
        coded("readFailed") { reader.seek(timeUs) }
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
        codec: VideoCodec,
    ): Boolean {
        val writer = coded("writeFailed") {
            FrameWriter(path, width.toInt(), height.toInt(), frameRate, bitRate?.toInt(), audioSourcePath, codec)
        }
        synchronized(this) { writers[writerId] = writer }
        return writer.audioIncluded
    }

    override fun addFrame(writerId: Long, rgba: ByteArray, ptsUs: Long) {
        coded("writeFailed") { writer(writerId).addFrame(rgba, ptsUs) }
    }

    override fun finishWriter(writerId: Long) {
        val writer = synchronized(this) { writers.remove(writerId) } ?: throw IllegalArgumentException("unknown writer $writerId")
        coded("writeFailed") { writer.finish() }
    }

    override fun cancelWriter(writerId: Long) {
        synchronized(this) { writers.remove(writerId) }?.cancel()
    }

    /**
     * Run `body`, rethrowing failures as a [FlutterError] whose code is a Dart
     * `VideoFramesErrorCode` name, so apps can tell them apart; `fallback` is
     * the code for anything not more specific.
     */
    private inline fun <T> coded(fallback: String, body: () -> T): T = try {
        body()
    } catch (e: FlutterError) {
        throw e
    } catch (e: Exception) {
        val code = when (e) {
            is UnsupportedOperationException -> "codecUnsupported"
            is EncoderStalledException -> "encoderStalled"
            else -> fallback
        }
        throw FlutterError(code, e.message ?: e.toString())
    }
}
