# #8 Memory at 4K

**Problem.** A 4K frame is 33 MB and is copied several times; mid-range Android phones can run out of memory.

**Change (cheap part).**
- Android: after #1, reuse one direct `ByteBuffer` for `glReadPixels` and one `ByteArray` per reader
  instead of allocating per frame. Safe only if Pigeon encodes the reply synchronously on the queue
  thread — confirm in `Messages.g.kt` (`reply.reply(...)` inside the handler) before relying on it.
- iOS: have the conversion write straight into a `Data` and pass that to `FlutterStandardTypedData`,
  removing the `[UInt8]` → `Data` copy in `VideoFramesPlugin.swift`.
- README: a per-resolution memory table (720p 3.7 MB, 1080p 8.3 MB, 4K 33 MB per frame) and the advice to
  use `maxDimension: 1920` for editing unless the device is high-end.

**Real fix.** #2 (zero-copy).

**Check.** Android Studio memory profiler on a 4K clip: GC churn and peak heap before/after.
