# #10 Android encoder stall

**Problem.** `FrameWriter.drain(true)` loops forever if the encoder never emits end-of-stream; the
`addFrame`/`finish` input loops (`do { dequeueInputBuffer } while (index < 0)`) can spin the same way.

**Change (`android/.../FrameWriter.kt`).** Reuse `FrameReader`'s pattern: track `idleSince`, reset it
whenever a buffer is produced or dequeued, and throw `IllegalStateException("video encoder stalled")`
after `STALL_MS = 5_000`. Move `STALL_MS` to a shared spot or duplicate the constant (one line).
After #1 the input loops disappear (surface input); the `drain` guard stays.

**Test.** No unit test (needs a misbehaving codec); covered by review + existing round trips.
