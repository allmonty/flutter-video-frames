# #9 Android finish() leak

**Problem.** `VideoFramesPlugin.finishWriter` removes the writer from the map, then calls `finish()`.
If `finish()` throws, `release()` never runs: the hardware encoder and muxer leak and nothing can cancel
them. Also, if `MediaMuxer(...)` or `codec.configure` throws in `FrameWriter`'s constructor, the
already-created codec leaks.

**Change (`android/.../FrameWriter.kt`).**
- `finish()`: wrap the body in `try { … } catch (e) { release(); File(path).delete(); throw e }`
  and `release()` on success, so a failed finish frees the codec and removes the corrupt file
  (same as `cancel()`).
- Constructor: create codec and muxer inside a `try`, releasing whatever exists if a later step throws.
- iOS parity: in `FrameWriter.finish`, if status isn't `.completed`, remove the file before throwing.

**Test.** None needed for the try/finally itself (trivial); existing tests must pass.
