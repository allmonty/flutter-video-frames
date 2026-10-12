# #11 Unclosed readers and writers

**Problem.** A `VideoReader`/`VideoWriter` the app never closes keeps a hardware decoder/encoder until the
app dies; iOS doesn't clean up on engine detach.

**Change.**
- `lib/video_frames.dart`: a `static final Finalizer<int>` on each class — reader → `closeReader(id)`,
  writer → `cancelWriter(id)` (an abandoned writer is unfinished, so delete the partial file). Attach
  in the private constructor, `detach` in `close`/`finish`/`cancel`. Ignore the returned future's errors.
  Doc: finalizers aren't guaranteed to run; always close in `try/finally`.
- `VideoFramesPlugin.swift`: `registrar.publish(instance)` so the engine calls
  `detachFromEngine(for:)`; implement it to close all readers and cancel all writers (Android already does).
- README usage: wrap the loop in `try { … } finally { await reader.close(); }` and cancel the writer on error.

**Test.** `flutter test`: after `close`/`finish`/`cancel`, a second call makes no platform call
(already covered for `close`; add `finish`). The finalizer itself can't be forced to run in tests.
